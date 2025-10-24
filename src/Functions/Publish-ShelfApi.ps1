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
    
    # Detener ejecución al primer error
    $ErrorActionPreference = 'Stop'

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

    # 1) Cargar configuraciones privadas y helpers
    . "$PSScriptRoot/../Private/SSHConfig.ps1"
    . "$PSScriptRoot/../Private/ConvertTo-WSLPath.ps1"
    . "$PSScriptRoot/../Private/PublishHelpers.ps1"
    
    if (-not $servers.ContainsKey($Server)) { throw "Servidor desconocido: $Server" }
    $s = $servers[$Server]
    $user = $s.username; $ip = $s.ip; $sshPort = $s.port

    # 2) Leer pubspec.yaml (name / version)
    $pubspecContent = Get-Content $pubspec -Raw
    if (-not $pubspecContent) { 
        throw "No se pudo leer pubspec.yaml en '$pubspec'. Verifica que el archivo existe y no está vacío." 
    }
    
    # Convertir a array de líneas para Get-YamlValue
    $pubspecLines = $pubspecContent -split "`r?`n" | Where-Object { $_ }
    if (-not $pubspecLines -or $pubspecLines.Count -eq 0) {
        throw "pubspec.yaml está vacío o solo contiene líneas en blanco en '$pubspec'"
    }
    
    $AppName = Get-YamlValue -Content $pubspecLines -Key 'name'
    $versionRaw = Get-YamlValue -Content $pubspecLines -Key 'version'
    
    if (-not $AppName) { throw "No se encontró 'name:' en pubspec.yaml" }
    if (-not $versionRaw) { throw "No se encontró 'version:' en pubspec.yaml" }
    
    $Version = $versionRaw.Split('+')[0]  # sin build metadata
    $Release = "v$Version"

    # 3) Leer todas las variables desde .env y extraer PORT
    $envConfig = Read-DotEnv -Path $dotenvPath -DefaultPort 8080
    $EnvVars = $envConfig.Env
    $Port = $envConfig.Port
    
    if ($EnvVars.Count -gt 0) {
        Write-Host "Variables de entorno detectadas en .env: $($EnvVars.Keys -join ', ')" -ForegroundColor Cyan
    }

    # 4) Validar WSL y obtener distro disponible
    $WSLDistro = Get-ValidWSLDistro -Preferred "Ubuntu"

    # Convertir ruta para WSL usando la distro validada
    $wslProject = ConvertTo-WSLPath -winPath $cwd -WSLDistro $WSLDistro
    # sanitizar posible CR que provenga de wslpath/cmd
    $wslProject = $wslProject -replace "\r", ''

    # 5) Build en WSL (binario Linux)
    Write-Host "Compilando en WSL ($WSLDistro)..." -ForegroundColor Cyan

    # Preparar rutas de salida
    $outWin = [IO.Path]::Combine($env:TEMP, "psdevops_publish_binary_{0}.server" -f ([guid]::NewGuid().ToString()))
    $wslOut = ConvertTo-WSLPath -winPath $outWin -WSLDistro $WSLDistro
    $wslOut = $wslOut -replace "\r", ''

    # Cargar script de build externo y reemplazar placeholders
    $buildScript = Get-BashScript -ScriptName "Build-DartBinary.sh" -Placeholders @{
        '__WSLPROJECT__' = $wslProject
        '__WSLWINOUT__'  = $wslOut
    }
    
    # Crear archivo temporal con codificación correcta
    $tmpFile = New-UnixTempFile -Content $buildScript -Prefix "psdevops_publish_build_"

    try {
        # Ejecutar build en WSL
        $wslTmpFile = ConvertTo-WSLPath -winPath $tmpFile -WSLDistro $WSLDistro
        $wslTmpFile = $wslTmpFile -replace "\r", ''
        Write-Host "Ejecutando build en WSL..." -ForegroundColor DarkGray
        
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
    Write-Host "Instalando release en servidor remoto..." -ForegroundColor Cyan
    
    # Cargar script de instalación externo y reemplazar placeholders
    $installScript = Get-BashScript -ScriptName "Install-RemoteBinary.sh" -Placeholders @{
        '__REMOTE_RELEASE__'  = $RemoteRelease
        '__APP_SERVER_ROOT__' = $AppServerRoot
        '__REMOTE_TMP__'      = $RemoteTmp
        '__USER__'            = $user
    }
    
    # Ejecutar script remoto usando helper
    $exitCode = Invoke-RemoteScript -ScriptContent $installScript `
                                    -User $user -IP $ip -Port $sshPort `
                                    -KeyPath $privateKeyPath `
                                    -ScriptPrefix "psdevops_remote_install_"
    
    if ($exitCode -ne 0) {
        throw "La instalación en el servidor falló con código $exitCode"
    }

    # 9) PM2 sin ecosystem (start si no existe; si existe, restart)
    Write-Host "Aplicando PM2 (sin ecosystem)..." -ForegroundColor Yellow
    $AppPM2 = "${AppName}_api"
    
    # Construir string de variables de entorno para PM2
    $envVarString = New-PM2EnvString -EnvVars $EnvVars
    $appBinPosix = "$AppServerRoot/current/bin/server"
    
    # Cargar script de PM2 externo y reemplazar placeholders
    $pm2Script = Get-BashScript -ScriptName "Manage-PM2.sh" -Placeholders @{
        '__APP_BIN__'   = $appBinPosix
        '__APP_NAME__'  = $AppPM2
        '__ENV_VARS__'  = $envVarString
    }
    
    # Ejecutar script remoto usando helper
    $exitCode = Invoke-RemoteScript -ScriptContent $pm2Script `
                                    -User $user -IP $ip -Port $sshPort `
                                    -KeyPath $privateKeyPath `
                                    -ScriptPrefix "psdevops_remote_pm2_"
    
    if ($exitCode -ne 0) {
        throw "La configuración de PM2 falló con código $exitCode"
    }

    # 10) Healthcheck con reintentos
    $healthUrl = "http://127.0.0.1:$Port$HealthPath"
    Write-Host "Verificando: $healthUrl" -ForegroundColor Cyan
    
    # Cargar script de healthcheck externo y reemplazar placeholders
    $healthScript = Get-BashScript -ScriptName "Healthcheck.sh" -Placeholders @{
        '__HEALTHURL__' = $healthUrl
    }
    
    # Ejecutar script remoto usando helper
    $exitCode = Invoke-RemoteScript -ScriptContent $healthScript `
                                    -User $user -IP $ip -Port $sshPort `
                                    -KeyPath $privateKeyPath `
                                    -ScriptPrefix "psdevops_remote_health_"
    
    if ($exitCode -ne 0) {
        throw "Healthcheck falló: el servidor no responde en $healthUrl después de múltiples intentos. Revisa los logs de PM2 con: ssh $user@$ip 'pm2 logs ${AppName}_api --lines 50'"
    }

    Write-Host "OK → Deploy $Release de ${AppName}_api" -ForegroundColor Green
}
