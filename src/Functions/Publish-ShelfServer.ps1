<#
.SYNOPSIS
Compila en WSL, sube release a /opt/apps/<app>_server/releases/vX.Y.Z/bin/server,
actualiza symlink 'current', reinicia con PM2 (sin ecosystem) y verifica con curl.

.DESCRIPTION
Ejecutar DESDE la carpeta del proyecto Shelf (donde están pubspec.yaml y .env):
Publish-ShelfServer <server-name>

- Obtiene name/version de pubspec.yaml.
- Obtiene PORT de .env (si no, 8080).
- Usa SSHConfig.ps1 para credenciales/hosts.
- Compila en WSL (distro configurable adentro).
- Sube binario, promueve 'current', pm2 start/restart, hace healthcheck.

.PARAMETER server
El nombre del servidor al que se desea desplegar el servidor Shelf. Este parámetro es obligatorio.

.EXAMPLE
Publish-ShelfServer app-server
Compila y despliega el servidor Shelf al servidor "app-server".

.NOTES
Versión: 1.0.0
Autor: @ccisnedev
#>
function Publish-ShelfServer {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Server
    )

    # ====== CONFIGURABLES (internos, sin parámetros) ======
    $WSLDistro     = "Ubuntu-22.04"       # Nombre de la distro WSL a usar
    $RemoteRoot    = "/opt/apps"          # Raíz para apps en el servidor
    $HealthPath    = "/healthz"           # Ruta de healthcheck
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
    [System.IO.File]::WriteAllText($tmpFile, $buildScriptUnix)

    try {
        # Ejecutar el script en WSL pasando el contenido como stdin mediante pipeline
        Get-Content -Raw -LiteralPath $tmpFile | & wsl.exe -d $WSLDistro bash -s
    } finally {
        Remove-Item -LiteralPath $tmpFile -ErrorAction SilentlyContinue
    }

    $localExe = Join-Path $cwd $BuildOutRel
    if (!(Test-Path $localExe)) { throw "No se generó el ejecutable: $localExe" }

    # 6) Variables remotas
    $AppServerRoot = Join-Path $RemoteRoot ("{0}_server" -f $AppName)    # /opt/apps/<app>_server
    $RemoteRelease = "$AppServerRoot/releases/$Release"
    $RemoteTmp     = "/tmp/${AppName}_server-${Release}"

    $sshCmd = "ssh -i `"$privateKeyPath`" -p $sshPort $user@$ip"

    # 7) Upload binario
    Write-Host "Subiendo release $Release a $ip..." -ForegroundColor Cyan
    $scpCmd = "scp -i `"$privateKeyPath`" -P $sshPort `"$localExe`" `"${user}@${ip}:$RemoteTmp`""
    Write-Host $scpCmd -ForegroundColor DarkGray
    Invoke-Expression $scpCmd

    # 8) Instalar release y promover 'current'
    $remoteInstall = @"
set -e
mkdir -p '$RemoteRelease/bin'
mv '$RemoteTmp' '$RemoteRelease/bin/server'
chmod +x '$RemoteRelease/bin/server'
ln -sfn '$RemoteRelease' '$AppServerRoot/current'
"@
    Invoke-Expression "$sshCmd '$remoteInstall'"

    # 9) PM2 sin ecosystem (start si no existe; si existe, restart)
    Write-Host "Aplicando PM2 (sin ecosystem)..." -ForegroundColor Yellow
    $AppPM2 = "${AppName}_server"
    $pm2Cmd = @"
if ! pm2 describe $AppPM2 >/dev/null; then
  pm2 start '$AppServerRoot/current/bin/server' --name $AppPM2 --interpreter none
  pm2 save
else
  pm2 restart $AppPM2
fi
"@
    Invoke-Expression "$sshCmd '$pm2Cmd'"

    # 10) Healthcheck
    $healthUrl = "http://127.0.0.1:$Port$HealthPath"
    Write-Host "Verificando: $healthUrl" -ForegroundColor Cyan
    $curl = "curl -fsS '$healthUrl' || (sleep 2 && curl -fsS '$healthUrl') || true"
    Invoke-Expression "$sshCmd '$curl'"

    Write-Host "OK → Deploy $Release de ${AppName}_server" -ForegroundColor Green
}
