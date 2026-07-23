<#
.SYNOPSIS
Compila y despliega una aplicación Flutter Web a un servidor Linux remoto vía SSH.

.DESCRIPTION
El cmdlet `Publish-FlutterWeb` gestiona el ciclo completo de despliegue de apps Flutter Web:
- Lee `name` y `version` de `pubspec.yaml` (single source of truth).
- Lee la configuración de despliegue de `publish.yaml` (server, port).
- Compila con `Invoke-FlutterBuild -Web` y empaqueta los artefactos.
- Sube al servidor con releases versionados en /var/www/<name>/releases/ y symlink `current`.
- Configura nginx con un site dedicado en sites-available/ si no existe.

Se debe ejecutar desde la raíz del proyecto Flutter donde existen:
  - pubspec.yaml  (name, version)
  - publish.yaml  (servidor, puerto — generar con -Init)

.PARAMETER Init
Genera el archivo publish.yaml en el directorio actual.
Requiere que exista pubspec.yaml.

.PARAMETER Publish
Ejecuta el despliegue completo al servidor remoto.
Lee publish.yaml para el servidor destino y el puerto nginx.

.PARAMETER DeployReport
Muestra las acciones que realizará -Publish sin ejecutarlas.
Consulta el servidor para mostrar: versión actual, si la release existe, estado de nginx.

.EXAMPLE
Publish-FlutterWeb -Init

Genera publish.yaml en el directorio actual del proyecto Flutter.

.EXAMPLE
Publish-FlutterWeb -DeployReport

Muestra un reporte de lo que hará -Publish sin realizar cambios.

.EXAMPLE
Publish-FlutterWeb -Publish

Compila, empaqueta, sube y despliega la app Flutter Web al servidor configurado en publish.yaml. Acepta el nombre anterior deploy.yaml con aviso de deprecación.

.NOTES
Versión: 2.0.0
Autor: @ccisnedev
Requiere:
  - Flutter SDK instalado y en PATH
  - Configuración del host en ~/.ssh/config (Host, HostName, User, Port, IdentityFile)
  - nginx en el servidor remoto con sites-available/ y sites-enabled/
  - Módulo powershell-yaml para parseo de publish.yaml
#>
function Publish-FlutterWeb {

    [CmdletBinding(DefaultParameterSetName = 'Apply')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Init',
            HelpMessage = "Generate the configuration file (publish.yaml)")]
        [switch]$Init,

        [Parameter(Mandatory, ParameterSetName = 'Plan',
            HelpMessage = "Dry-run: show what -Apply would do, without making changes")]
        [Alias('DeployReport')]
        [switch]$Plan,

        [Parameter(Mandatory, ParameterSetName = 'Apply',
            HelpMessage = "Execute the deployment to the remote server")]
        [Alias('Publish')]
        [switch]$Apply,

        [Parameter(ParameterSetName = 'Apply',
            HelpMessage = "Skip the confirmation prompt for unattended/CI use (ADR 0002)")]
        [switch]$AutoApprove
    )

    begin {
        $ErrorActionPreference = 'Stop'
        Ensure-YamlModule
    }

    process {
        # Banner
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║     Publish-FlutterWeb — macss-devops           ║" -ForegroundColor Cyan
        Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""

        # Deprecation notice for the pre-ADR-0002 vocabulary.
        if ($MyInvocation.Line -match '-(Publish|DeployReport)\b') {
            Write-Warning "-Publish/-DeployReport are deprecated; use -Apply/-Plan (ADR 0002). They will be removed in a future major."
        }

        switch ($PSCmdlet.ParameterSetName) {

            # ═══════════════════════════════════════════════════
            # INIT — Generar publish.yaml
            # ═══════════════════════════════════════════════════
            'Init' {
                $cwd = (Get-Location).Path

                # Validar pubspec.yaml (es un proyecto Flutter)
                $pubspecPath = Join-Path $cwd "pubspec.yaml"
                if (-not (Test-Path $pubspecPath)) {
                    throw "No se encontró pubspec.yaml en $cwd. Ejecute este cmdlet dentro de un proyecto Flutter."
                }

                # Validar que publish.yaml no exista (ni el legacy deploy.yaml)
                $publishYamlPath = Join-Path $cwd "publish.yaml"
                if (Test-Path $publishYamlPath) {
                    throw "Ya existe publish.yaml en $cwd. Elimínelo primero si desea regenerar la configuración."
                }
                if (Test-Path (Join-Path $cwd "deploy.yaml")) {
                    throw "Existe deploy.yaml (nombre anterior) en $cwd. Renómbrelo a publish.yaml o elimínelo antes de regenerar."
                }

                # Leer pubspec.yaml para mostrar información
                $pubspec = Get-Content $pubspecPath -Raw | ConvertFrom-Yaml
                $appName = $pubspec.name
                $appVersion = ($pubspec.version -split '\+')[0]

                Write-Host "  Proyecto:  $appName" -ForegroundColor Cyan
                Write-Host "  Versión:   $appVersion" -ForegroundColor Cyan
                Write-Host ""

                # Copiar template publish.yaml
                $templatePath = Join-Path $PSScriptRoot "..\Resources\Publish-FlutterWeb\templates\publish.yaml"
                if (-not (Test-Path $templatePath)) {
                    throw "Template no encontrado: $templatePath"
                }
                Copy-Item -Path $templatePath -Destination $publishYamlPath
                Write-Host "  Creado: publish.yaml" -ForegroundColor Green

                # Instrucciones
                Write-Host ""
                Write-Host "  Configuración creada. Próximos pasos:" -ForegroundColor Green
                Write-Host "    1. Edite publish.yaml → cambie 'server' por su alias SSH" -ForegroundColor DarkGray
                Write-Host "    2. Edite publish.yaml → cambie 'port' por el puerto nginx deseado" -ForegroundColor DarkGray
                Write-Host "    3. Ejecute: Publish-FlutterWeb -Publish" -ForegroundColor DarkGray
                Write-Host ""
            }

            # ═══════════════════════════════════════════════════
            # PUBLISH — Despliegue completo
            # ═══════════════════════════════════════════════════
            'Apply' {
                $cwd = (Get-Location).Path

                # ─── 1. Cargar helpers ───────────────────────
                . "$PSScriptRoot/../Private/PublishHelpers.ps1"
                . "$PSScriptRoot/../Private/Read-SSHConfig.ps1"
                . "$PSScriptRoot/../Private/DeployPlan.ps1"
                . "$PSScriptRoot/../Private/FlutterWebPlan.ps1"

                # ─── 0. Validaciones ─────────────────────────
                $pubspecPath = Join-Path $cwd "pubspec.yaml"
                $configResolution = Resolve-PublishConfigPath -ProjectRoot $cwd
                $publishYamlPath = $configResolution.Path

                if (-not (Test-Path $pubspecPath)) {
                    throw "No se encontró pubspec.yaml en $cwd. Ejecute este cmdlet dentro de un proyecto Flutter."
                }
                if (-not $publishYamlPath) {
                    throw "No se encontró publish.yaml. Ejecute 'Publish-FlutterWeb -Init' primero."
                }
                if ($configResolution.IsLegacy) {
                    Write-Host "  Aviso: 'deploy.yaml' está deprecado; renómbrelo a 'publish.yaml'." -ForegroundColor Yellow
                }

                # ─── 2. Leer configuración ───────────────────
                # pubspec.yaml (name, version)
                $pubspec = Get-Content $pubspecPath -Raw | ConvertFrom-Yaml
                $appName = $pubspec.name
                $appVersion = ($pubspec.version -split '\+')[0]  # sin build metadata
                $release = "v$appVersion"

                # publish.yaml (server, port)
                $deployConfig = Get-Content $publishYamlPath -Raw | ConvertFrom-Yaml
                $server = $deployConfig.server
                $port = $deployConfig.port

                # ─── 3. Validaciones de config ───────────────
                if (-not $server) {
                    throw "No se encontró 'server:' en publish.yaml."
                }
                if ($server -eq 'your-ssh-alias') {
                    throw "publish.yaml contiene el valor de ejemplo 'your-ssh-alias'. Cambie 'server' por el alias SSH real de su servidor."
                }
                if (-not $port) {
                    throw "No se encontró 'port:' en publish.yaml."
                }

                # ─── 4. SSH Config ───────────────────────────
                $sshConfig = Read-SSHConfig -HostAlias $server
                $user = $sshConfig.User
                $ip = $sshConfig.HostName
                $sshPort = $sshConfig.Port
                $privateKeyPath = $sshConfig.IdentityFile

                # ─── Constantes remotas ──────────────────────
                $remoteWebRoot = "/var/www"

                # ─── Plan (ADR 0009): -Apply renders the SAME plan as -Plan before confirming
                #     (ADR 0002 §"Confirmation flow" step 1). No report file is written on -Apply. ───
                $plan = Get-FlutterWebPlan -AppName $appName -Release $release `
                    -Server $server -User $user -IP $ip -SshPort $sshPort `
                    -PrivateKeyPath $privateKeyPath -Port $port -RemoteWebRoot $remoteWebRoot
                Show-DeployPlan -Plan $plan

                # ─── Confirmation (ADR 0002) ─────────────────
                if (-not (Confirm-MacssChange -Action "Deploy $appName $release to '$server' (port $port)" -AutoApprove:$AutoApprove)) {
                    Write-Host "  Apply cancelled." -ForegroundColor Yellow
                    return
                }
                $zipFileName = "${appName}_web_${release}.zip"
                $remoteZipPath = "/tmp/$zipFileName"

                # ─── 5. Build Flutter Web ────────────────────
                $webBuildFolder = "release/app_${appName}_v${appVersion}_web"
                if (Test-Path $webBuildFolder) {
                    Write-Host "  Limpiando build anterior: $webBuildFolder" -ForegroundColor Yellow
                    Remove-Item -Recurse -Force $webBuildFolder
                }

                Write-Host "  Compilando Flutter Web..." -ForegroundColor Cyan
                Invoke-FlutterBuild -Web
                $webBuildPath = Join-Path $cwd $webBuildFolder

                if (-not (Test-Path (Join-Path $webBuildPath "index.html"))) {
                    throw "Build Flutter Web no generó index.html. Verifique que 'flutter build web' funciona correctamente."
                }
                Write-Host "  Build completado: $webBuildFolder" -ForegroundColor Green

                # ─── 6. Comprimir artefactos ─────────────────
                Write-Host "  Comprimiendo artefactos..." -ForegroundColor Cyan
                $localZipPath = Join-Path ([System.IO.Path]::GetTempPath()) $zipFileName

                if (Test-Path $localZipPath) {
                    Remove-Item $localZipPath -Force
                }
                Compress-Archive -Path "$webBuildPath\*" -DestinationPath $localZipPath -CompressionLevel Optimal -Force

                $zipSize = [math]::Round((Get-Item $localZipPath).Length / 1MB, 1)
                Write-Host "  Zip: $zipFileName ($($zipSize) MB)" -ForegroundColor Green

                try {
                    # ─── 7. SCP: subir zip ───────────────────
                    Write-Host "  Subiendo archivos a $ip..." -ForegroundColor Cyan
                    $scpArgs = @('-i', $privateKeyPath, '-P', $sshPort, $localZipPath, "$($user)@$($ip):$remoteZipPath")
                    & scp @scpArgs 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Error al subir zip (scp exit: $LASTEXITCODE)" }
                    Write-Host "    Zip subido" -ForegroundColor Green

                    # ─── 8. Instalar release ─────────────────
                    Write-Host "  Instalando release $release..." -ForegroundColor Cyan

                    $installScript = Get-BashScript -ScriptName "Install-FlutterWeb.sh" -Placeholders @{
                        '__NAME__'     = $appName
                        '__VERSION__'  = $appVersion
                        '__WEB_ROOT__' = $remoteWebRoot
                    }

                    $exitCode = Invoke-RemoteScript -ScriptContent $installScript `
                                                    -User $user -IP $ip -Port $sshPort `
                                                    -KeyPath $privateKeyPath `
                                                    -ScriptPrefix "psdevops_install_flutterweb_"

                    if ($exitCode -ne 0) {
                        throw "Instalación falló con código $exitCode. Revise la salida anterior."
                    }

                    # ─── 9. Configurar nginx ─────────────────
                    Write-Host "  Verificando configuración nginx..." -ForegroundColor Cyan

                    $nginxScript = Get-BashScript -ScriptName "Configure-NginxSite.sh" -Placeholders @{
                        '__NAME__' = $appName
                        '__PORT__' = $port.ToString()
                    }

                    $exitCode = Invoke-RemoteScript -ScriptContent $nginxScript `
                                                    -User $user -IP $ip -Port $sshPort `
                                                    -KeyPath $privateKeyPath `
                                                    -ScriptPrefix "psdevops_nginx_flutterweb_"

                    if ($exitCode -ne 0) {
                        throw "Configuración de nginx falló con código $exitCode"
                    }

                    # ─── 10. Verificación ────────────────────
                    Write-Host "  Verificando: http://127.0.0.1:$port/" -ForegroundColor Cyan

                    $verifyScript = @"
#!/bin/bash
set -e
sleep 1
HTTP_CODE=`$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$port/ 2>/dev/null || echo '000')
if [ "`$HTTP_CODE" = "200" ]; then
    echo "OK: HTTP $port responde 200"
    exit 0
else
    echo "WARNING: HTTP $port respondió `$HTTP_CODE (puede necesitar tiempo para iniciar)" >&2
    exit 0
fi
"@

                    Invoke-RemoteScript -ScriptContent $verifyScript `
                                        -User $user -IP $ip -Port $sshPort `
                                        -KeyPath $privateKeyPath `
                                        -ScriptPrefix "psdevops_verify_flutterweb_" | Out-Null

                    # ─── Éxito ───────────────────────────────
                    Write-Host ""
                    Write-Host "══════════════════════════════════════════════════" -ForegroundColor Green
                    Write-Host "  Deploy completado: $appName $release" -ForegroundColor Green
                    Write-Host "══════════════════════════════════════════════════" -ForegroundColor Green
                    Write-Host "  Servidor:  $ip" -ForegroundColor White
                    Write-Host "  Release:   $remoteWebRoot/$appName/releases/$release" -ForegroundColor White
                    Write-Host "  Nginx:     puerto $port" -ForegroundColor White
                    Write-Host "══════════════════════════════════════════════════" -ForegroundColor Green
                    Write-Host ""

                } finally {
                    # Limpiar archivos temporales locales
                    Remove-Item -LiteralPath $localZipPath -ErrorAction SilentlyContinue
                }
            }

            # ═══════════════════════════════════════════════════
            # DEPLOY REPORT — Reporte pre-deploy (dry-run)
            # ═══════════════════════════════════════════════════
            'Plan' {
                $cwd = (Get-Location).Path

                # ─── 1. Cargar helpers ───────────────────────
                . "$PSScriptRoot/../Private/PublishHelpers.ps1"
                . "$PSScriptRoot/../Private/Read-SSHConfig.ps1"
                . "$PSScriptRoot/../Private/DeployPlan.ps1"
                . "$PSScriptRoot/../Private/FlutterWebPlan.ps1"

                # ─── 0. Validaciones ─────────────────────────
                $pubspecPath = Join-Path $cwd "pubspec.yaml"
                $configResolution = Resolve-PublishConfigPath -ProjectRoot $cwd
                $publishYamlPath = $configResolution.Path

                if (-not (Test-Path $pubspecPath)) {
                    throw "No se encontró pubspec.yaml en $cwd. Ejecute este cmdlet dentro de un proyecto Flutter."
                }
                if (-not $publishYamlPath) {
                    throw "No se encontró publish.yaml. Ejecute 'Publish-FlutterWeb -Init' primero."
                }
                if ($configResolution.IsLegacy) {
                    Write-Host "  Aviso: 'deploy.yaml' está deprecado; renómbrelo a 'publish.yaml'." -ForegroundColor Yellow
                }

                # ─── 2. Leer configuración ───────────────────
                $pubspec = Get-Content $pubspecPath -Raw | ConvertFrom-Yaml
                $appName = $pubspec.name
                $appVersion = ($pubspec.version -split '\+')[0]
                $release = "v$appVersion"

                $deployConfig = Get-Content $publishYamlPath -Raw | ConvertFrom-Yaml
                $server = $deployConfig.server
                $port = $deployConfig.port

                # ─── 3. Validaciones de config ───────────────
                if (-not $server) {
                    throw "No se encontró 'server:' en publish.yaml."
                }
                if ($server -eq 'your-ssh-alias') {
                    throw "publish.yaml contiene el valor de ejemplo 'your-ssh-alias'. Cambie 'server' por el alias SSH real de su servidor."
                }
                if (-not $port) {
                    throw "No se encontró 'port:' en publish.yaml."
                }

                # ─── 4. SSH Config ───────────────────────────
                $sshConfig = Read-SSHConfig -HostAlias $server
                $user = $sshConfig.User
                $ip = $sshConfig.HostName
                $sshPort = $sshConfig.Port
                $privateKeyPath = $sshConfig.IdentityFile

                $remoteWebRoot = "/var/www"

                Write-Host "  Modo: SOLO REPORTE (no se realizarán cambios)" -ForegroundColor Yellow

                # ─── 5. Construir y mostrar el plan (compartido con -Apply, ADR 0009) ───
                $plan = Get-FlutterWebPlan -AppName $appName -Release $release `
                    -Server $server -User $user -IP $ip -SshPort $sshPort `
                    -PrivateKeyPath $privateKeyPath -Port $port -RemoteWebRoot $remoteWebRoot
                Show-DeployPlan -Plan $plan

                # ─── 6. Persistir el reporte de cambios (ADR 0009) — solo en -Plan ───
                $reportPath = Save-DeployPlan -Plan $plan -ProjectRoot $cwd
                Write-Host "  Reporte del plan: $reportPath" -ForegroundColor DarkGray
                Write-Host ""
            }
        }
    }
}
