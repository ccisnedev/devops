<#
.SYNOPSIS
Despliega una API Node.js/TypeScript a un servidor Linux remoto vía SSH.

.DESCRIPTION
El cmdlet `Publish-NodeApi` gestiona el ciclo completo de despliegue de APIs TypeScript:
- Lee `name` y `version` de `package.json` (single source of truth).
- Lee la configuración de despliegue de `deploy.yaml`.
- Ejecuta build local (npm ci + tsc) y empaqueta los artefactos compilados.
- Sube dist/ + node_modules/ + package.json al servidor (no requiere internet en el servidor).
- Usa releases versionados con symlink `current` para rollback fácil.
- Soporta systemd (default) y PM2 como process managers.

Se debe ejecutar desde la raíz del proyecto donde existen:
  - package.json   (name, version)
  - tsconfig.json  (proyecto TypeScript)
  - deploy.yaml    (servidor, runtime, health — generar con -Init)
  - .env.production (variables de entorno — se copia al servidor como .env)

.PARAMETER Init
Genera los archivos de configuración (deploy.yaml y .env.production) en el directorio actual.
Requiere que existan package.json y tsconfig.json.

.PARAMETER Publish
Ejecuta el despliegue completo al servidor remoto.
Lee deploy.yaml para el servidor destino y la configuración de runtime.
Siempre sube .env.production como .env dentro del release.

.PARAMETER DeployReport
Muestra las acciones que realizará -Publish sin ejecutarlas.
Consulta el servidor para mostrar: versión actual, si la release existe, estado del servicio.

.EXAMPLE
Publish-NodeApi -Init

Genera deploy.yaml y .env.production en el directorio actual del proyecto TypeScript.

.EXAMPLE
Publish-NodeApi -DeployReport

Muestra un reporte de lo que hará -Publish sin realizar cambios.

.EXAMPLE
Publish-NodeApi -Publish

Empaqueta, sube y despliega la API al servidor configurado en deploy.yaml.

.NOTES
Versión: 2.0.0
Autor: @ccisnedev
Requiere:
  - Configuración del host en ~/.ssh/config (Host, HostName, User, Port, IdentityFile)
  - Node.js y npm instalados localmente para el build
  - Node.js en el servidor remoto (solo runtime, no necesita internet)
  - PM2 o systemd según la configuración de deploy.yaml
  - Módulo powershell-yaml para parseo de deploy.yaml
#>
function Publish-NodeApi {

    [CmdletBinding(DefaultParameterSetName = 'Publish')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Init',
            HelpMessage = "Genera archivos de configuración (deploy.yaml y .env.production)")]
        [switch]$Init,

        [Parameter(Mandatory, ParameterSetName = 'Publish',
            HelpMessage = "Ejecuta el despliegue completo al servidor remoto")]
        [switch]$Publish,

        [Parameter(Mandatory, ParameterSetName = 'DeployReport',
            HelpMessage = "Muestra las acciones que realizará -Publish sin ejecutarlas")]
        [switch]$DeployReport
    )

    begin {
        $ErrorActionPreference = 'Stop'
    }

    process {
        # Banner
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║         Publish-NodeApi — PSDevOps               ║" -ForegroundColor Cyan
        Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""

        switch ($PSCmdlet.ParameterSetName) {

            # ═══════════════════════════════════════════════════
            # INIT — Generar deploy.yaml y .env.production
            # ═══════════════════════════════════════════════════
            'Init' {
                $cwd = (Get-Location).Path

                # Validar package.json
                $packageJsonPath = Join-Path $cwd "package.json"
                if (-not (Test-Path $packageJsonPath)) {
                    throw "No se encontró package.json en $cwd. Ejecute este cmdlet dentro de un proyecto Node.js."
                }

                # Validar tsconfig.json (solo TypeScript)
                $tsconfigPath = Join-Path $cwd "tsconfig.json"
                if (-not (Test-Path $tsconfigPath)) {
                    throw "No se encontró tsconfig.json en $cwd. Este cmdlet solo soporta proyectos TypeScript."
                }

                # Validar que deploy.yaml no exista
                $deployYamlPath = Join-Path $cwd "deploy.yaml"
                if (Test-Path $deployYamlPath) {
                    throw "Ya existe deploy.yaml en $cwd. Elimínelo primero si desea regenerar la configuración."
                }

                # Leer package.json para mostrar información
                $pkg = Get-Content $packageJsonPath -Raw | ConvertFrom-Json
                $appName = $pkg.name
                $appVersion = $pkg.version

                Write-Host "  Proyecto:  $appName" -ForegroundColor Cyan
                Write-Host "  Versión:   $appVersion" -ForegroundColor Cyan
                Write-Host ""

                # Copiar template deploy.yaml
                $templatePath = Join-Path $PSScriptRoot "..\Resources\Publish-NodeApi\templates\deploy.yaml"
                if (-not (Test-Path $templatePath)) {
                    throw "Template no encontrado: $templatePath"
                }
                Copy-Item -Path $templatePath -Destination $deployYamlPath
                Write-Host "  Creado: deploy.yaml" -ForegroundColor Green

                # Crear .env.production si no existe
                $envProdPath = Join-Path $cwd ".env.production"
                if (-not (Test-Path $envProdPath)) {
                    $envContent = @"
# .env.production — Variables de entorno para producción
# Este archivo se copia al servidor como .env en cada despliegue.
# NO versionar este archivo (está en .gitignore).

PORT=8080
NODE_ENV=production
"@
                    Set-Content -Path $envProdPath -Value $envContent -Encoding UTF8
                    Write-Host "  Creado: .env.production" -ForegroundColor Green
                } else {
                    Write-Host "  Existe: .env.production (no se modificó)" -ForegroundColor Yellow
                }

                # Agregar .env.production a .gitignore
                $gitignorePath = Join-Path $cwd ".gitignore"
                if (Test-Path $gitignorePath) {
                    $gitignoreContent = Get-Content $gitignorePath -Raw
                    if ($gitignoreContent -notmatch '\.env\.production') {
                        Add-Content -Path $gitignorePath -Value "`n.env.production"
                        Write-Host "  Actualizado: .gitignore (+.env.production)" -ForegroundColor Green
                    }
                } else {
                    Set-Content -Path $gitignorePath -Value ".env.production`n" -Encoding UTF8
                    Write-Host "  Creado: .gitignore" -ForegroundColor Green
                }

                # Instrucciones
                Write-Host ""
                Write-Host "  Configuración creada. Próximos pasos:" -ForegroundColor Green
                Write-Host "    1. Edite deploy.yaml → cambie 'server' por su alias SSH" -ForegroundColor DarkGray
                Write-Host "    2. Edite .env.production → configure variables de entorno" -ForegroundColor DarkGray
                Write-Host "    3. Ejecute: Publish-NodeApi -Publish" -ForegroundColor DarkGray
                Write-Host ""
            }

            # ═══════════════════════════════════════════════════
            # PUBLISH — Despliegue completo
            # ═══════════════════════════════════════════════════
            'Publish' {
                $cwd = (Get-Location).Path
                Ensure-YamlModule

                # ─── 0. Validaciones ─────────────────────────
                $deployYamlPath = Join-Path $cwd "deploy.yaml"
                $packageJsonPath = Join-Path $cwd "package.json"
                $tsconfigPath = Join-Path $cwd "tsconfig.json"
                $envProdPath = Join-Path $cwd ".env.production"

                if (-not (Test-Path $deployYamlPath)) {
                    throw "No se encontró deploy.yaml. Ejecute 'Publish-NodeApi -Init' primero."
                }
                if (-not (Test-Path $packageJsonPath)) {
                    throw "No se encontró package.json en $cwd."
                }
                if (-not (Test-Path $tsconfigPath)) {
                    throw "No se encontró tsconfig.json en $cwd."
                }
                if (-not (Test-Path $envProdPath)) {
                    throw "No se encontró .env.production. Cree el archivo con las variables de entorno de producción."
                }

                # ─── 1. Cargar helpers ───────────────────────
                . "$PSScriptRoot/../Private/PublishHelpers.ps1"
                . "$PSScriptRoot/../Private/Read-SSHConfig.ps1"

                # ─── 2. Leer configuración ───────────────────
                # deploy.yaml (server, runtime, health)
                $deployConfig = (Get-Content $deployYamlPath -Raw) | ConvertFrom-Yaml

                # package.json (name, version)
                $pkg = Get-Content $packageJsonPath -Raw | ConvertFrom-Json
                $appName = $pkg.name
                $appVersion = ($pkg.version -split '\+')[0]  # sin build metadata
                $release = "v$appVersion"

                # .env.production (PORT)
                $envConfig = Read-DotEnv -Path $envProdPath -DefaultPort 8080
                $port = $envConfig.Port

                # Extraer config de deploy.yaml con defaults
                $server = $deployConfig.server
                $processManager = if ($deployConfig.runtime -and $deployConfig.runtime.processManager) { 
                    $deployConfig.runtime.processManager 
                } else { 'systemd' }
                $nodeVersion = if ($deployConfig.runtime -and $deployConfig.runtime.nodeVersion) { 
                    $deployConfig.runtime.nodeVersion 
                } else { '>=18' }
                $healthRetries = if ($deployConfig.health -and $deployConfig.health.retries) { 
                    $deployConfig.health.retries 
                } else { 6 }
                $healthInterval = if ($deployConfig.health -and $deployConfig.health.interval) { 
                    $deployConfig.health.interval 
                } else { 3 }

                # ─── 3. Validaciones de config ───────────────
                if (-not $server) {
                    throw "No se encontró 'server:' en deploy.yaml."
                }
                if ($server -eq 'your-ssh-alias') {
                    throw "deploy.yaml contiene el valor de ejemplo 'your-ssh-alias'. Cambie 'server' por el alias SSH real de su servidor."
                }
                if ($processManager -notin @('systemd', 'pm2')) {
                    throw "Process manager '$processManager' no soportado. Use 'systemd' o 'pm2'."
                }

                Write-Host "  Proyecto:   $appName" -ForegroundColor Cyan
                Write-Host "  Versión:    $release" -ForegroundColor Cyan
                Write-Host "  Servidor:   $server" -ForegroundColor Cyan
                Write-Host "  Proceso:    $processManager" -ForegroundColor Cyan
                Write-Host "  Puerto:     $port" -ForegroundColor Cyan
                Write-Host ""

                # ─── 4. SSH Config ───────────────────────────
                $sshConfig = Read-SSHConfig -HostAlias $server
                $user = $sshConfig.User
                $ip = $sshConfig.HostName
                $sshPort = $sshConfig.Port
                $privateKeyPath = $sshConfig.IdentityFile

                # ─── Constantes remotas ──────────────────────
                $remoteRoot = "/opt/app"
                $releaseDir = "$remoteRoot/$appName/releases/$release"
                $currentLink = "$remoteRoot/$appName/current"
                $entryPath = "$currentLink/dist/main.js"
                $workingDir = "$currentLink"
                $envFile = "$currentLink/.env"
                $tarballName = "${appName}-${release}.tar.gz"
                $remoteTarball = "/tmp/$tarballName"
                $remoteEnvFile = "/tmp/${appName}.env.production"

                # ─── 5. Build local ──────────────────────────
                Write-Host "  Compilando localmente..." -ForegroundColor Cyan

                # 5a. Instalar TODAS las dependencias (incluye devDeps para tsc)
                Write-Host "    npm ci..." -ForegroundColor DarkGray
                $npmCiResult = & npm ci 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $npmCiResult | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
                    throw "npm ci falló con código $LASTEXITCODE"
                }
                Write-Host "    Dependencias instaladas" -ForegroundColor Green

                # 5b. Build TypeScript
                Write-Host "    npm run build..." -ForegroundColor DarkGray
                $buildResult = & npm run build 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $buildResult | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
                    throw "npm run build falló con código $LASTEXITCODE"
                }

                # Verificar que dist/main.js se generó
                $distMain = Join-Path $cwd "dist\main.js"
                if (-not (Test-Path $distMain)) {
                    throw "Build completó pero dist/main.js no existe. Verifique tsconfig.json."
                }
                Write-Host "    Build completado (dist/main.js OK)" -ForegroundColor Green

                # 5c. Reinstalar solo dependencias de producción (para tarball liviano)
                Write-Host "    npm ci --omit=dev (producción)..." -ForegroundColor DarkGray
                $npmProdResult = & npm ci --omit=dev 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $npmProdResult | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
                    throw "npm ci --omit=dev falló con código $LASTEXITCODE"
                }
                Write-Host "    node_modules optimizado para producción" -ForegroundColor Green

                # ─── 6. Empaquetar artefactos ────────────────
                Write-Host "  Empaquetando artefactos..." -ForegroundColor Cyan

                $localTarball = Join-Path $env:TEMP $tarballName

                # Empaquetar solo: dist/ + node_modules/ + package.json
                # (los artefactos ya compilados, listos para ejecutar con node)
                $tarCmd = "tar.exe -czf `"$localTarball`" -C `"$cwd`" dist node_modules package.json"
                $tarResult = Invoke-Expression $tarCmd 2>&1

                if (-not (Test-Path $localTarball)) {
                    throw "Error al crear tarball: $tarResult"
                }

                $tarSize = [math]::Round((Get-Item $localTarball).Length / 1MB, 1)
                Write-Host "  Tarball: $tarballName ($($tarSize) MB)" -ForegroundColor Green

                try {
                    # ─── 7. SCP: subir tarball + .env ────────
                    Write-Host "  Subiendo archivos a $ip..." -ForegroundColor Cyan

                    # Subir tarball
                    $scpArgs = @('-i', $privateKeyPath, '-P', $sshPort, $localTarball, "$($user)@$($ip):$remoteTarball")
                    & scp @scpArgs 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Error al subir tarball (scp exit: $LASTEXITCODE)" }
                    Write-Host "    Tarball subido" -ForegroundColor Green

                    # Subir .env.production (normalizado a LF para compatibilidad con bash en Linux)
                    $envContent = Get-Content $envProdPath -Raw
                    $tmpEnvPath = New-UnixTempFile -Content $envContent -Prefix "psdevops_env_"
                    $scpEnvArgs = @('-i', $privateKeyPath, '-P', $sshPort, $tmpEnvPath, "$($user)@$($ip):$remoteEnvFile")
                    & scp @scpEnvArgs 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Error al subir .env.production (scp exit: $LASTEXITCODE)" }
                    Write-Host "    .env.production subido (LF)" -ForegroundColor Green

                    # ─── 8. Instalar release ─────────────────
                    Write-Host "  Instalando release $release..." -ForegroundColor Cyan

                    $installScript = Get-BashScript -ScriptName "Install-NodeApi.sh" -Placeholders @{
                        '__NAME__'          = $appName
                        '__VERSION__'       = $appVersion
                        '__REMOTE_ROOT__'   = $remoteRoot
                        '__NODE_VERSION__'  = $nodeVersion
                        '__USER__'          = $user
                    }

                    $exitCode = Invoke-RemoteScript -ScriptContent $installScript `
                                                    -User $user -IP $ip -Port $sshPort `
                                                    -KeyPath $privateKeyPath `
                                                    -ScriptPrefix "psdevops_install_nodeapi_"

                    if ($exitCode -ne 0) {
                        throw "Instalación falló con código $exitCode. Revise la salida anterior."
                    }

                    # ─── 9. Gestionar proceso ────────────────
                    Write-Host "  Configurando $processManager..." -ForegroundColor Cyan

                    $manageScript = Get-BashScript -ScriptName "Manage-NodeProcess.sh" -Placeholders @{
                        '__NAME__'             = $appName
                        '__PROCESS_MANAGER__'  = $processManager
                        '__ENTRY_PATH__'       = $entryPath
                        '__WORKING_DIR__'      = $workingDir
                        '__ENV_FILE__'         = $envFile
                        '__PORT__'             = $port.ToString()
                        '__USER__'             = $user
                    }

                    $exitCode = Invoke-RemoteScript -ScriptContent $manageScript `
                                                    -User $user -IP $ip -Port $sshPort `
                                                    -KeyPath $privateKeyPath `
                                                    -ScriptPrefix "psdevops_manage_nodeapi_"

                    if ($exitCode -ne 0) {
                        throw "Configuración de $processManager falló con código $exitCode"
                    }

                    # ─── 10. Healthcheck ─────────────────────
                    $healthUrl = "http://127.0.0.1:$port/health"
                    Write-Host "  Verificando: $healthUrl" -ForegroundColor Cyan

                    $healthScript = Get-BashScript -ScriptName "Healthcheck.sh" -Placeholders @{
                        '__HEALTHURL__' = $healthUrl
                    }

                    $exitCode = Invoke-RemoteScript -ScriptContent $healthScript `
                                                    -User $user -IP $ip -Port $sshPort `
                                                    -KeyPath $privateKeyPath `
                                                    -ScriptPrefix "psdevops_health_nodeapi_"

                    if ($exitCode -ne 0) {
                        $logCmd = if ($processManager -eq 'pm2') { 
                            "pm2 logs $appName --lines 50" 
                        } else { 
                            "journalctl -u $appName --no-pager -n 50" 
                        }
                        throw "Healthcheck falló en $healthUrl. Revise logs con: ssh $user@$ip '$logCmd'"
                    }

                    # ─── Éxito ───────────────────────────────
                    Write-Host ""
                    Write-Host "══════════════════════════════════════════════════" -ForegroundColor Green
                    Write-Host "  Deploy completado: $appName $release" -ForegroundColor Green
                    Write-Host "══════════════════════════════════════════════════" -ForegroundColor Green
                    Write-Host "  Servidor:  $ip" -ForegroundColor White
                    Write-Host "  Release:   $releaseDir" -ForegroundColor White
                    Write-Host "  Proceso:   $processManager" -ForegroundColor White
                    Write-Host "  Health:    $healthUrl" -ForegroundColor White
                    Write-Host "══════════════════════════════════════════════════" -ForegroundColor Green
                    Write-Host ""

                } finally {
                    # Limpiar archivos temporales locales
                    Remove-Item -LiteralPath $localTarball -ErrorAction SilentlyContinue
                    if ($tmpEnvPath) { Remove-Item -LiteralPath $tmpEnvPath -ErrorAction SilentlyContinue }
                }
            }

            # ═══════════════════════════════════════════════════
            # DEPLOY REPORT — Reporte pre-deploy (dry-run)
            # ═══════════════════════════════════════════════════
            'DeployReport' {
                $cwd = (Get-Location).Path
                Ensure-YamlModule

                # ─── 0. Validaciones ─────────────────────────
                $packageJsonPath = Join-Path $cwd "package.json"
                $deployYamlPath = Join-Path $cwd "deploy.yaml"
                $envProdPath = Join-Path $cwd ".env.production"

                if (-not (Test-Path $packageJsonPath)) {
                    throw "No se encontró package.json en $cwd."
                }
                if (-not (Test-Path $deployYamlPath)) {
                    throw "No se encontró deploy.yaml. Ejecute 'Publish-NodeApi -Init' primero."
                }
                if (-not (Test-Path $envProdPath)) {
                    throw "No se encontró .env.production. Ejecute 'Publish-NodeApi -Init' primero."
                }

                # ─── 1. Cargar helpers ───────────────────────
                . "$PSScriptRoot/../Private/PublishHelpers.ps1"
                . "$PSScriptRoot/../Private/Read-SSHConfig.ps1"

                # ─── 2. Leer configuración ───────────────────
                $packageJson = Get-Content $packageJsonPath -Raw | ConvertFrom-Json
                $appName = $packageJson.name
                $appVersion = $packageJson.version
                $release = "v$appVersion"

                $deployConfig = Get-Content $deployYamlPath -Raw | ConvertFrom-Yaml
                $server = $deployConfig.server
                $processManager = if ($deployConfig.runtime -and $deployConfig.runtime.processManager) {
                    $deployConfig.runtime.processManager
                } else { 'systemd' }

                $envConfig = Read-DotEnv -Path $envProdPath -DefaultPort 8080
                $port = $envConfig.Port

                # ─── 3. Validaciones de config ───────────────
                if (-not $server) {
                    throw "No se encontró 'server:' en deploy.yaml."
                }
                if ($server -eq 'your-ssh-alias') {
                    throw "deploy.yaml contiene el valor de ejemplo 'your-ssh-alias'. Cambie 'server' por el alias SSH real de su servidor."
                }

                # ─── 4. SSH Config ───────────────────────────
                $sshConfig = Read-SSHConfig -HostAlias $server
                $user = $sshConfig.User
                $ip = $sshConfig.HostName
                $sshPort = $sshConfig.Port
                $privateKeyPath = $sshConfig.IdentityFile

                $remoteRoot = "/opt/app"

                Write-Host "  Modo: SOLO REPORTE (no se realizarán cambios)" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  ─── Configuración local ───" -ForegroundColor Cyan
                Write-Host "  Proyecto:   $appName" -ForegroundColor White
                Write-Host "  Versión:    $release" -ForegroundColor White
                Write-Host "  Servidor:   $server ($ip)" -ForegroundColor White
                Write-Host "  Proceso:    $processManager" -ForegroundColor White
                Write-Host "  Puerto:     $port" -ForegroundColor White
                Write-Host ""

                # ─── 5. Consultar estado del servidor ────────
                Write-Host "  ─── Estado del servidor ───" -ForegroundColor Cyan

                $reportScript = @"
#!/bin/bash
# Versión actual (symlink current)
if [ -L "$remoteRoot/$appName/current" ]; then
    CURRENT=`$(readlink "$remoteRoot/$appName/current" | xargs basename)
    echo "CURRENT:`$CURRENT"
else
    echo "CURRENT:none"
fi

# Release destino ya existe?
if [ -d "$remoteRoot/$appName/releases/$release" ]; then
    echo "RELEASE:exists"
else
    echo "RELEASE:new"
fi

# Estado del servicio
if [ "$processManager" = "systemd" ]; then
    if systemctl is-active --quiet $appName 2>/dev/null; then
        echo "SERVICE:running"
    elif systemctl is-enabled --quiet $appName 2>/dev/null; then
        echo "SERVICE:stopped"
    else
        echo "SERVICE:not-configured"
    fi
else
    if pm2 describe $appName >/dev/null 2>&1; then
        STATUS=`$(pm2 describe $appName 2>/dev/null | grep status | head -1 | awk '{print `$4}')
        echo "SERVICE:`$STATUS"
    else
        echo "SERVICE:not-configured"
    fi
fi
"@

                $tmpLocal = New-UnixTempFile -Content $reportScript -Prefix "psdevops_report_nodeapi_"
                try {
                    $remoteName = [IO.Path]::GetFileName($tmpLocal)
                    $remotePath = "/tmp/$remoteName"

                    & scp -i $privateKeyPath -P $sshPort $tmpLocal "$($user)@$($ip):$remotePath" 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Error al conectar con el servidor (scp exit: $LASTEXITCODE)" }

                    $remoteCmd = "bash $remotePath ; rc=`$?; rm -f $remotePath; exit `$rc"
                    $output = & ssh -i $privateKeyPath -p $sshPort "$($user)@$($ip)" $remoteCmd 2>&1
                } finally {
                    Remove-Item -LiteralPath $tmpLocal -ErrorAction SilentlyContinue
                }

                # Parsear salida
                $currentVersion = 'desconocido'
                $releaseStatus = 'desconocido'
                $serviceStatus = 'desconocido'

                foreach ($line in $output) {
                    if ($line -match '^CURRENT:(.+)$') { $currentVersion = $Matches[1] }
                    if ($line -match '^RELEASE:(.+)$') { $releaseStatus = $Matches[1] }
                    if ($line -match '^SERVICE:(.+)$') { $serviceStatus = $Matches[1] }
                }

                if ($currentVersion -eq 'none') {
                    Write-Host "  Current:    (primer deploy)" -ForegroundColor Yellow
                } else {
                    Write-Host "  Current:    $currentVersion" -ForegroundColor White
                }

                if ($releaseStatus -eq 'exists') {
                    Write-Host "  Release:    $release ya existe (se sobreescribirá)" -ForegroundColor Yellow
                } else {
                    Write-Host "  Release:    $release (nueva)" -ForegroundColor Green
                }

                if ($serviceStatus -eq 'running') {
                    Write-Host "  Servicio:   $processManager activo (se reiniciará)" -ForegroundColor White
                } elseif ($serviceStatus -eq 'not-configured') {
                    Write-Host "  Servicio:   se creará ($processManager)" -ForegroundColor Green
                } else {
                    Write-Host "  Servicio:   $serviceStatus" -ForegroundColor Yellow
                }

                # ─── 6. Acciones que realizará -Publish ──────
                Write-Host ""
                Write-Host "  ─── Acciones que realizará -Publish ───" -ForegroundColor Cyan
                Write-Host "  1. Compilar TypeScript (npm ci + tsc)" -ForegroundColor White
                Write-Host "  2. Empaquetar artefactos en tar.gz" -ForegroundColor White
                Write-Host "  3. Subir tar.gz + .env.production a ${ip}:/tmp/" -ForegroundColor White
                Write-Host "  4. Instalar en ${remoteRoot}/${appName}/releases/${release}/" -ForegroundColor White
                Write-Host "  5. Actualizar symlink current → $release" -ForegroundColor White
                Write-Host "  6. Configurar/reiniciar servicio ($processManager)" -ForegroundColor White
                Write-Host "  7. Healthcheck en puerto $port" -ForegroundColor White
                Write-Host ""
            }
        }
    }
}
