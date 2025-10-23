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

    # 3) Leer PORT desde .env (si existe), fallback 8080
    $Port = 8080
    if (Test-Path $dotenvPath) {
        $envLines = Get-Content $dotenvPath | Where-Object { $_ -and ($_ -notmatch '^\s*#') }
        $kv = $envLines | Where-Object { $_ -match '^\s*PORT\s*=' }
        if ($kv) {
            $val = ($kv -split '=',2)[1].Trim()
            if ($val -match '^\d+$') { $Port = [int]$val }
        }
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

    $buildScript = @'
set -e
cd '__WSLPROJECT__'
dart --version
dart pub get
mkdir -p build
# Detectar automáticamente el archivo de entrada dentro de bin/
ENTRY_CANDIDATE=""
if [ -f bin/server.dart ]; then
    ENTRY_CANDIDATE="bin/server.dart"
elif [ -f bin/main.dart ]; then
    ENTRY_CANDIDATE="bin/main.dart"
else
    # buscar coincidencias más flexibles
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
dart compile exe "$ENTRY_CANDIDATE" -o build/server
# optimiza tamaño si existe strip
command -v strip >/dev/null && strip build/server || true
'@

    # Reemplazar placeholder con la ruta WSL (ya sanitizada)
    $buildScript = $buildScript -replace '__WSLPROJECT__', $wslProject

    # Forzar finales de línea LF y escribir a un archivo temporal en Windows
    $buildScriptUnix = $buildScript -replace "\r\n", "`n"
    $buildScriptUnix = $buildScriptUnix -replace "\r", ""

    $tmpFile = [IO.Path]::Combine($env:TEMP, "psdevops_publish_build_{0}.sh" -f ([guid]::NewGuid().ToString()))
    # Escribir el script en UTF8 sin BOM para evitar problemas si el archivo es leído en Linux
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmpFile, $buildScriptUnix, $utf8NoBom)

    try {
        # Convertir la ruta Windows del archivo temporal a ruta WSL y ejecutar directamente en bash
        $wslTmpFile = ConvertTo-WSLPath -winPath $tmpFile -WSLDistro $WSLDistro
        $wslTmpFile = $wslTmpFile -replace "\r", ''
    # Ejecutar en WSL pasando argumentos separados para evitar que PowerShell forme un único token
    Write-Host "Ejecutando build en WSL: bash $wslTmpFile" -ForegroundColor DarkGray
    & wsl.exe -d $WSLDistro -- bash $wslTmpFile
    } finally {
        Remove-Item -LiteralPath $tmpFile -ErrorAction SilentlyContinue
    }

    $localExe = Join-Path $cwd $BuildOutRel
    if (!(Test-Path $localExe)) { throw "No se generó el ejecutable: $localExe" }

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
        $pm2Cmd = @"
if ! pm2 describe $AppPM2 >/dev/null 2>&1; then
    pm2 start '$AppServerRoot/current/bin/server' --name $AppPM2 --interpreter none
    pm2 save
else
    pm2 restart $AppPM2
fi
"@
    # Normalizar y ejecutar script PM2 via archivo temporal (UTF-8 sin BOM) para evitar CRLF/encoding issues
    $pm2Unix = $pm2Cmd -replace "`r`n", "`n" -replace "`r", ""
    $tmpPm2 = [IO.Path]::Combine($env:TEMP, "psdevops_remote_pm2_{0}.sh" -f ([guid]::NewGuid().ToString()))
    # Reusar el encoding UTF8 sin BOM
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
    } finally {
        Remove-Item -LiteralPath $tmpHealth -ErrorAction SilentlyContinue
    }

    Write-Host "OK → Deploy $Release de ${AppName}_api" -ForegroundColor Green
}
