<#
.SYNOPSIS
Compila en WSL, sube release a /opt/apps/<app>_api/releases/vX.Y.Z/bin/server,
actualiza symlink 'current', reinicia con PM2 (sin ecosystem) y verifica con curl.

.DESCRIPTION
Ejecutar DESDE la carpeta del proyecto Shelf (donde están pubspec.yaml y .env):
Publish-ShelfApi <server-name>

- Obtiene name/version de pubspec.yaml.
- Obtiene PORT de .env (si no, 8080).
- Usa SSHConfig.ps1 para credenciales/hosts.
- Compila en WSL (distro configurable adentro).
- Sube binario, promueve 'current', pm2 start/restart, hace healthcheck.

.PARAMETER server
El nombre del servidor al que se desea desplegar el servidor Shelf. Este parámetro es obligatorio.

.EXAMPLE
Publish-ShelfApi app-server
Compila y despliega el servidor Shelf al servidor "app-server".

.NOTES
Versión: 1.0.0
Autor: @ccisnedev
#>
function Publish-ShelfApi {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Server
    )

    # ====== CONFIGURABLES (internos, sin parámetros) ======
    $WSLDistro     = "Ubuntu"       # Nombre de la distro WSL a usar
    # Usar la ruta esperada en el servidor remoto. Nota: usar '/opt/app' (singular) según convención.
    $RemoteRoot    = "/opt/app"          # Raíz para apps en el servidor
    $HealthPath    = "/health"           # Ruta de healthcheck
    $BuildOutRel   = "build/server"       # Ruta de salida local del binario
    # ======================================================

    # 0) Validaciones rápidas
    $cwd = (Get-Location).Path
    $pubspec = Join-Path $cwd "pubspec.yaml"
    if (!(Test-Path $pubspec)) { throw "No se encontró pubspec.yaml en $cwd. Ejecuta este cmdlet dentro del proyecto Shelf." }

    $dotenvPath = Join-Path $cwd ".env"   # opcional

    # 1) Cargar configuraciones privadas
    . "$PSScriptRoot/../Private/SSHConfig.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-WSLPath.ps1"
    if (-not $servers.ContainsKey($Server)) { throw "Servidor desconocido: $Server" }
    $s = $servers[$Server]
    $user = $s.username; $ip = $s.ip; $sshPort = $s.port

    # 2) Leer pubspec.yaml (name / version)
    $content = Get-Content $pubspec
    $nameLine = $content | Where-Object { $_ -match "^\s*name:\s*" }
    $versionLine = $content | Where-Object { $_ -match "^\s*version:\s*" }
    if (-not $nameLine)    { throw "No se encontró 'name:' en pubspec.yaml" }
    if (-not $versionLine) { throw "No se encontró 'version:' en pubspec.yaml" }

    $AppName = ($nameLine -split ":\s*")[1].Trim().Trim('"','''')
    $Version = ($versionLine -split ":\s*")[1].Trim().Trim('"','''')
    $Version = $Version.Split('+')[0]  # sin build metadata
    $Release = "v$Version"

    # 3) Leer todas las variables desde .env y extraer PORT
    $Port = 8080
    $EnvVars = @{}
    if (Test-Path $dotenvPath) {
        $envLines = Get-Content $dotenvPath | Where-Object { $_ -and ($_ -notmatch '^\s*#') }
        foreach ($line in $envLines) {
            if ($line -match '^\s*([^=]+)\s*=\s*(.*)$') {
                $key = $Matches[1].Trim()
                $value = $Matches[2].Trim()
                # Remover comillas si existen
                if ($value -match '^["''](.+)["'']$') {
                    $value = $Matches[1]
                }
                $EnvVars[$key] = $value
                
                # Extraer PORT específicamente
                if ($key -eq 'PORT' -and $value -match '^\d+$') {
                    $Port = [int]$value
                }
            }
        }
    }
    
    if ($EnvVars.Count -gt 0) {
        Write-Host "Variables de entorno detectadas en .env: $($EnvVars.Keys -join ', ')" -ForegroundColor Cyan
    }

    # 4) Verificar que wsl.exe y la distro existen (fallback si es posible)
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw "wsl.exe no está disponible en PATH. Habilita WSL en Windows y vuelve a intentar. Ejecuta `wsl -l -v` para comprobar."
    }

    # Obtener listado de distros instaladas de forma robusta (solo nombres)
    $wslListRaw = & wsl.exe --list --quiet 2>&1
    # wsl --list --quiet devuelve un nombre por línea; filtramos líneas vacías y limpiamos caracteres de control
    $wslDistros = $wslListRaw -split "\r?\n" |
                 ForEach-Object { ($_ -replace '\p{C}', '') } |
                 ForEach-Object { $_.Trim() } |
                 Where-Object { $_ -ne '' }

    if (-not $wslDistros -or $wslDistros.Count -eq 0) {
        throw "No hay distribuciones WSL instaladas. Instala una (por ejemplo 'Ubuntu-22.04') con 'wsl --install -d Ubuntu-22.04'."
    }

    if (-not ($wslDistros -contains $WSLDistro)) {
        # mostrar distros detectadas para diagnóstico
        $available = $wslDistros -join ', '
        Write-Host "Distros WSL detectadas: $available" -ForegroundColor DarkGray

        # intentar fallback a una Ubuntu instalada (más tolerante: 'Ubuntu*')
        $ubuntu = $wslDistros | Where-Object { $_ -like 'Ubuntu*' } | Select-Object -First 1
        if ($ubuntu) {
            Write-Host "Advertencia: distro especificada '$WSLDistro' no encontrada. Usando '$ubuntu' (fallback)." -ForegroundColor Yellow
            $WSLDistro = $ubuntu
        } else {
            # como último recurso, usar la primera distro instalada con advertencia (pero no recomendado)
            $first = $wslDistros[0]
            throw "Distro WSL '$WSLDistro' no encontrada. Distros instaladas: $available. Instala la correcta o actualiza `$WSLDistro` en el script."
        }
    }

    # Convertir ruta para WSL usando la distro validada
    $wslProject = ConvertTo-WSLPath -winPath $cwd -WSLDistro $WSLDistro
    # sanitizar posible CR que provenga de wslpath/cmd
    $wslProject = $wslProject -replace "\r", ''

    # 5) Build en WSL (binario Linux)
    Write-Host "Compilando en WSL ($WSLDistro)..." -ForegroundColor Cyan

    # Compilación en WSL en un directorio nativo (/tmp) para evitar problemas con /mnt (mount flags, locking, permisos)
    # Generamos también una ruta de salida en Windows ($outWin) y la convertimos a WSL ($wslOut) para que el script WSL copie
    # el binario ya generado a la ruta Windows temporal, de forma que el flujo de scp desde Windows siga funcionando.
    $outWin = [IO.Path]::Combine($env:TEMP, "psdevops_publish_binary_{0}.server" -f ([guid]::NewGuid().ToString()))
    $wslOut = ConvertTo-WSLPath -winPath $outWin -WSLDistro $WSLDistro
    $wslOut = $wslOut -replace "\r", ''

    $buildScript = @'
set -e
# Variables pasadas por sustitución: __WSLPROJECT__ y __WSLWINOUT__
SRC='__WSLPROJECT__'
OUT='__WSLWINOUT__'

TMPDIR=$(mktemp -d /tmp/psdevops_build.XXXXXX)
echo "Using TMPDIR=$TMPDIR"
mkdir -p "$TMPDIR/src"
# Copiar proyecto al TMPDIR para compilar sobre FS nativo
cp -a "$SRC/." "$TMPDIR/src/"
cd "$TMPDIR/src"

dart --version
dart pub get
mkdir -p build

# Detectar entrypoint
ENTRY_CANDIDATE=""
if [ -f bin/server.dart ]; then
    ENTRY_CANDIDATE="bin/server.dart"
elif [ -f bin/main.dart ]; then
    ENTRY_CANDIDATE="bin/main.dart"
else
    first=$(ls bin/*server*.dart 2>/dev/null | head -n1 || true)
    if [ -n "$first" ]; then
        ENTRY_CANDIDATE="$first"
    else
        first2=$(ls bin/*.dart 2>/dev/null | head -n1 || true)
        if [ -n "$first2" ]; then
            ENTRY_CANDIDATE="$first2"
        fi
    fi
fi

if [ -z "$ENTRY_CANDIDATE" ]; then
    echo "\"bin/*.dart\" file not found. No se puede compilar sin archivo de entrada." >&2
    exit 2
fi

echo "Usando entrypoint: $ENTRY_CANDIDATE"
# Compilar con verificación explícita de éxito
if ! dart compile exe "$ENTRY_CANDIDATE" -o build/server; then
    echo "ERROR: dart compile exe falló para $ENTRY_CANDIDATE" >&2
    exit 3
fi

# Verificar que el binario se generó y tiene tamaño razonable
if [ ! -f build/server ]; then
    echo "ERROR: build/server no existe después de compilar" >&2
    exit 4
fi

size=$(stat -c%s build/server 2>/dev/null || stat -f%z build/server 2>/dev/null || echo 0)
if [ "$size" -lt 100000 ]; then
    echo "ERROR: build/server parece incompleto (tamaño: $size bytes)" >&2
    exit 5
fi

echo "Binario generado exitosamente (tamaño: $size bytes)"
# NO usar strip: destruye el snapshot AOT embebido en binarios Dart

# Verificar que el binario arranca correctamente ANTES de copiarlo
echo "Verificando que el binario arranca..."
tmp_verify=$(mktemp)
set +e
timeout 3 ./build/server >"$tmp_verify" 2>&1
verify_status=$?
set -e
if [ "$verify_status" -ne 124 ]; then
    echo "ERROR: El binario no arranca correctamente (exit=$verify_status)" >&2
    cat "$tmp_verify" >&2
    rm -f "$tmp_verify"
    exit 7
fi
rm -f "$tmp_verify"
echo "Verificación exitosa: binario arranca correctamente"

# Informar ruta nativa del binario antes de moverlo al path Windows
echo "BUILT_NATIVE:$TMPDIR/src/build/server"

# Copiar el binario al path Windows temporal (convertido a /mnt/..). 
mkdir -p "$(dirname "$OUT")"
cp build/server "$OUT"
chmod +x "$OUT"
echo "BUILT:$OUT"
'@

    # Reemplazar placeholders con valores concretos
    $buildScript = $buildScript -replace '__WSLPROJECT__', $wslProject -replace '__WSLWINOUT__', $wslOut
    # Forzar finales de línea LF y escribir a un archivo temporal en Windows
    $buildScriptUnix = $buildScript -replace "`r`n", "`n" -replace "`r", ""

    $tmpFile = [IO.Path]::Combine($env:TEMP, "psdevops_publish_build_{0}.sh" -f ([guid]::NewGuid().ToString()))
    # Escribir el script en UTF8 sin BOM para evitar problemas si el archivo es leído en Linux
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmpFile, $buildScriptUnix, $utf8NoBom)

    try {
        # Convertir la ruta Windows del archivo temporal a ruta WSL y ejecutar directamente en bash
        $wslTmpFile = ConvertTo-WSLPath -winPath $tmpFile -WSLDistro $WSLDistro
        $wslTmpFile = $wslTmpFile -replace "\r", ''
        Write-Host "Ejecutando build en WSL: bash $wslTmpFile" -ForegroundColor DarkGray
        # Ejecutar en WSL; el script bash ya verifica el binario antes de copiarlo a Windows
        & wsl.exe -d $WSLDistro -- bash $wslTmpFile 2>&1 | Tee-Object -Variable wslOutput
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Build en WSL falló. Salida completa:" -ForegroundColor Red
            $wslOutput | ForEach-Object { Write-Host $_ }
            throw "Build en WSL falló con código $LASTEXITCODE. Revisa la salida anterior."
        }
        
        # Buscar la línea BUILT para confirmar que el binario se copió a Windows temp
        $builtLine = ($wslOutput | Where-Object { $_ -match '^BUILT:' }) -join "`n"
        if (-not $builtLine) {
            Write-Host "Salida completa de WSL:" -ForegroundColor Yellow
            $wslOutput | ForEach-Object { Write-Host $_ }
            throw "No se detectó 'BUILT:' en la salida del build. Abortando." 
        }
        
        # Extraer la ruta del binario en Windows temp
        $localExe = ($builtLine -replace '^BUILT:', '').Trim()
        # Convertir de ruta WSL a ruta Windows si es necesario
        if ($localExe -match '^/mnt/') {
            # Convertir /mnt/c/... a C:\...
            $localExe = $localExe -replace '^/mnt/([a-z])/', '$1:\'
            $localExe = $localExe -replace '/', '\'
        }
        
        Write-Host "Build completado y verificado en WSL. Binario en: $localExe" -ForegroundColor Green
    } finally {
        Remove-Item -LiteralPath $tmpFile -ErrorAction SilentlyContinue
    }

    # Verificar que el binario se copió a Windows
    if (!(Test-Path $localExe)) { 
        throw "No se generó el ejecutable en la ruta esperada: $localExe" 
    }

    # 6) Variables remotas — construir rutas POSIX usando slash para evitar backslashes en Windows
    # Evitar usar Join-Path porque en Windows produce backslashes que luego se interpretan como escapes en el shell remoto
    $AppServerRoot = "$RemoteRoot/$($AppName)_api"    # /opt/app/<app>_api
    $RemoteRelease = "$AppServerRoot/releases/$Release"
    $RemoteTmp     = "/tmp/$($AppName)_api-$Release"

    $sshCmd = "ssh -i `"$privateKeyPath`" -p $sshPort $user@$ip"

    # 7) Upload binario
    Write-Host "Subiendo release $Release a $ip..." -ForegroundColor Cyan
    $scpArgs = @('-i', $privateKeyPath, '-P', $sshPort, $localExe, "$($user)@$($ip):$RemoteTmp")
    Write-Host ('scp {0} {1} {2} {3} {4}' -f '-i', $privateKeyPath, '-P', $sshPort, $localExe) -ForegroundColor DarkGray
    & scp @scpArgs

    # 8) Instalar release y promover 'current'
        # Construir el script remoto con las rutas ya expandidas para evitar variables literales
        # Build remote install script as literal with placeholders, then replace them to avoid PowerShell expanding bash $() or other tokens
        $remoteInstall = @'
set -e
sudo mkdir -p '__REMOTE_RELEASE__'/bin
# Backup del binario actual si existe
if [ -f '__APP_SERVER_ROOT__/current/bin/server' ]; then
    ts=$(date +%Y%m%d%H%M%S)
    sudo cp -v '__APP_SERVER_ROOT__/current/bin/server' '__APP_SERVER_ROOT__/current/bin/server.bak.$ts' || true
fi
sudo mv '__REMOTE_TMP__' '__REMOTE_RELEASE__'/bin/server
sudo chmod +x '__REMOTE_RELEASE__'/bin/server
sudo chown -R __USER__:__USER__ '__REMOTE_RELEASE__'
sudo ln -sfn '__REMOTE_RELEASE__' '__APP_SERVER_ROOT__/current'
'@

    # Replace placeholders with real values
    $remoteInstall = $remoteInstall -replace '__REMOTE_RELEASE__', $RemoteRelease -replace '__APP_SERVER_ROOT__', $AppServerRoot -replace '__REMOTE_TMP__', $RemoteTmp -replace '__USER__', $user
    $remoteInstallUnix = $remoteInstall -replace "`r`n", "`n" -replace "`r", ""
    $tmpRemoteInstall = [IO.Path]::Combine($env:TEMP, "psdevops_remote_install_{0}.sh" -f ([guid]::NewGuid().ToString()))
    [System.IO.File]::WriteAllText($tmpRemoteInstall, $remoteInstallUnix, $utf8NoBom)
    try {
        $remoteScriptName = [IO.Path]::GetFileName($tmpRemoteInstall)
    & scp -i $privateKeyPath -P $sshPort $tmpRemoteInstall "$($user)@$($ip):/tmp/$remoteScriptName"
    & ssh -i $privateKeyPath -p $sshPort "$($user)@$($ip)" "bash /tmp/$remoteScriptName && rm -f /tmp/$remoteScriptName"
    } finally {
        Remove-Item -LiteralPath $tmpRemoteInstall -ErrorAction SilentlyContinue
    }

    # 9) PM2 sin ecosystem (start si no existe; si existe, restart)
    Write-Host "Aplicando PM2 (sin ecosystem)..." -ForegroundColor Yellow
    $AppPM2 = "${AppName}_api"
    # Mejor comportamiento:
    # - Si ya existe un proceso con ese nombre, lo eliminamos para evitar reaplicar un 'interpreter' antiguo.
    # - Verificamos que el archivo desplegado sea un ELF antes de arrancar; si no, salimos con error y mostramos diagnóstico.
    $pm2Cmd = @'
set -e
APP_BIN="__APP_BIN__"
APP_NAME="__APP_NAME__"

# Si existe proceso anterior, borrarlo para forzar un arranque limpio con las opciones correctas
if pm2 describe "$APP_NAME" >/dev/null 2>&1; then
    pm2 delete "$APP_NAME" || true
fi

# Verificar tipo de archivo: debe ser ELF (ejecutable nativo)
if ! command -v file >/dev/null 2>&1; then
    echo "Aviso: 'file' no está disponible en el servidor; no puedo verificar el tipo de binario." >&2
else
    ft=$(file -b "$APP_BIN" || true)
    echo "file: $ft"
    echo "$ft" | grep -q ELF >/dev/null 2>&1 || {
        echo "ERROR: El artefacto desplegado no parece ser un ejecutable ELF: $APP_BIN" >&2
        ls -l "$APP_BIN" || true
        echo "Contenido (head) para diagnóstico:" >&2
        head -c 4096 "$APP_BIN" | sed -n '1,200p' || true
        exit 3
    }
fi

# Arrancar de forma explícita como binario nativo (no intérprete) con variables de entorno
pm2 start "$APP_BIN" --name "$APP_NAME" --interpreter none --update-env __ENV_VARS__
pm2 save
'@

    # Construir string de variables de entorno para PM2
    $envVarString = ""
    if ($EnvVars.Count -gt 0) {
        $envParts = @()
        foreach ($key in $EnvVars.Keys) {
            $value = $EnvVars[$key]
            # Escapar comillas simples en el valor
            $escapedValue = $value -replace "'", "'\\''"
            $envParts += "--env $key='$escapedValue'"
        }
        $envVarString = $envParts -join " "
    }
    
    # Rellenar placeholders con las rutas reales y normalizar LF
    $appBinPosix = "$AppServerRoot/current/bin/server"
    $pm2Cmd = $pm2Cmd -replace '__APP_BIN__', $appBinPosix -replace '__APP_NAME__', $AppPM2 -replace '__ENV_VARS__', $envVarString
    $pm2Unix = $pm2Cmd -replace "`r`n", "`n" -replace "`r", ""
    $tmpPm2 = [IO.Path]::Combine($env:TEMP, "psdevops_remote_pm2_{0}.sh" -f ([guid]::NewGuid().ToString()))
    if (-not $utf8NoBom) { $utf8NoBom = New-Object System.Text.UTF8Encoding($false) }
    [System.IO.File]::WriteAllText($tmpPm2, $pm2Unix, $utf8NoBom)
    try {
        $remotePm2Name = [IO.Path]::GetFileName($tmpPm2)
        & scp -i $privateKeyPath -P $sshPort $tmpPm2 "$($user)@$($ip):/tmp/$remotePm2Name"
        & ssh -i $privateKeyPath -p $sshPort "$($user)@$($ip)" "bash /tmp/$remotePm2Name && rm -f /tmp/$remotePm2Name"
    } finally {
        Remove-Item -LiteralPath $tmpPm2 -ErrorAction SilentlyContinue
    }

        # 10) Healthcheck con reintentos
        $healthUrl = "http://127.0.0.1:$Port$HealthPath"
        Write-Host "Verificando: $healthUrl" -ForegroundColor Cyan
        # Health script: usar here-string literal y reemplazar el placeholder con la URL concreta
        $healthScript = @'
set -e
tries=0
until [ $tries -ge 6 ]
do
    if curl -fsS '__HEALTHURL__' >/dev/null 2>&1; then
        echo OK
        exit 0
    fi
    tries=$((tries+1))
    sleep 2
done
exit 1
'@
        $healthScript = $healthScript -replace '__HEALTHURL__', $healthUrl
        $healthScript = $healthScript -replace "`r`n", "`n" -replace "`r", ""
        $tmpHealth = [IO.Path]::Combine($env:TEMP, "psdevops_remote_health_{0}.sh" -f ([guid]::NewGuid().ToString()))
        [System.IO.File]::WriteAllText($tmpHealth, $healthScript, $utf8NoBom)
    try {
        $remoteHealthName = [IO.Path]::GetFileName($tmpHealth)
                & scp -i $privateKeyPath -P $sshPort $tmpHealth "$($user)@$($ip):/tmp/$remoteHealthName"
                # Build remote command by concatenation so any $... tokens remain literal for the remote shell
                $remoteCmd = 'bash /tmp/' + $remoteHealthName + ' ; rc=$?; rm -f /tmp/' + $remoteHealthName + '; exit $rc'
                & ssh -i $privateKeyPath -p $sshPort "$($user)@$($ip)" $remoteCmd
                if ($LASTEXITCODE -ne 0) {
                    throw "Healthcheck falló: el servidor no responde en $healthUrl después de múltiples intentos. Revisa los logs de PM2 con: ssh $user@$ip 'pm2 logs ${AppName}_api --lines 50'"
                }
    } finally {
        Remove-Item -LiteralPath $tmpHealth -ErrorAction SilentlyContinue
    }

    Write-Host "OK → Deploy $Release de ${AppName}_api" -ForegroundColor Green
}
