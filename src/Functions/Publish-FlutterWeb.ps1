<#
.SYNOPSIS
Compila y despliega una aplicación Flutter Web a un servidor Linux remoto vía SSH.

.DESCRIPTION
El cmdlet `Publish-FlutterWeb` gestiona el ciclo completo de despliegue de apps Flutter Web:
- Lee `name` y `version` de `pubspec.yaml` (single source of truth).
- Lee la configuración de despliegue de `deploy.yaml` (server, port).
- Compila con `Invoke-FlutterBuild -Web` y empaqueta los artefactos.
- Sube al servidor con releases versionados en /var/www/<name>/releases/ y symlink `current`.
- Configura nginx con un site dedicado en sites-available/ si no existe.

Se debe ejecutar desde la raíz del proyecto Flutter donde existen:
  - pubspec.yaml  (name, version)
  - deploy.yaml   (servidor, puerto — generar con -Init)

.PARAMETER Init
Genera el archivo deploy.yaml en el directorio actual.
Requiere que exista pubspec.yaml.

.PARAMETER Deploy
Ejecuta el despliegue completo al servidor remoto.
Lee deploy.yaml para el servidor destino y el puerto nginx.

.EXAMPLE
Publish-FlutterWeb -Init

Genera deploy.yaml en el directorio actual del proyecto Flutter.

.EXAMPLE
Publish-FlutterWeb -Deploy

Compila, empaqueta, sube y despliega la app Flutter Web al servidor configurado en deploy.yaml.

.NOTES
Versión: 1.0.0
Autor: @ccisnedev
Requiere:
  - Flutter SDK instalado y en PATH
  - Configuración del host en ~/.ssh/config (Host, HostName, User, Port, IdentityFile)
  - nginx en el servidor remoto con sites-available/ y sites-enabled/
  - Módulo powershell-yaml para parseo de deploy.yaml
#>
function Publish-FlutterWeb {

    [CmdletBinding(DefaultParameterSetName = 'Deploy')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Init',
            HelpMessage = "Genera archivo de configuración (deploy.yaml)")]
        [switch]$Init,

        [Parameter(Mandatory, ParameterSetName = 'Deploy',
            HelpMessage = "Ejecuta el despliegue completo al servidor remoto")]
        [switch]$Deploy
    )

    begin {
        $ErrorActionPreference = 'Stop'
    }

    process {
        # Banner
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║       Publish-FlutterWeb — PSDevOps              ║" -ForegroundColor Cyan
        Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""

        switch ($PSCmdlet.ParameterSetName) {

            # ═══════════════════════════════════════════════════
            # INIT — Generar deploy.yaml
            # ═══════════════════════════════════════════════════
            'Init' {
                $cwd = (Get-Location).Path

                # Validar pubspec.yaml (es un proyecto Flutter)
                $pubspecPath = Join-Path $cwd "pubspec.yaml"
                if (-not (Test-Path $pubspecPath)) {
                    throw "No se encontró pubspec.yaml en $cwd. Ejecute este cmdlet dentro de un proyecto Flutter."
                }

                # Validar que deploy.yaml no exista
                $deployYamlPath = Join-Path $cwd "deploy.yaml"
                if (Test-Path $deployYamlPath) {
                    throw "Ya existe deploy.yaml en $cwd. Elimínelo primero si desea regenerar la configuración."
                }

                # Leer pubspec.yaml para mostrar información
                $pubspec = Get-Content $pubspecPath -Raw | ConvertFrom-Yaml
                $appName = $pubspec.name
                $appVersion = ($pubspec.version -split '\+')[0]

                Write-Host "  Proyecto:  $appName" -ForegroundColor Cyan
                Write-Host "  Versión:   $appVersion" -ForegroundColor Cyan
                Write-Host ""

                # Copiar template deploy.yaml
                $templatePath = Join-Path $PSScriptRoot "..\Resources\Publish-FlutterWeb\templates\deploy.yaml"
                if (-not (Test-Path $templatePath)) {
                    throw "Template no encontrado: $templatePath"
                }
                Copy-Item -Path $templatePath -Destination $deployYamlPath
                Write-Host "  Creado: deploy.yaml" -ForegroundColor Green

                # Instrucciones
                Write-Host ""
                Write-Host "  Configuración creada. Próximos pasos:" -ForegroundColor Green
                Write-Host "    1. Edite deploy.yaml → cambie 'server' por su alias SSH" -ForegroundColor DarkGray
                Write-Host "    2. Edite deploy.yaml → cambie 'port' por el puerto nginx deseado" -ForegroundColor DarkGray
                Write-Host "    3. Ejecute: Publish-FlutterWeb -Deploy" -ForegroundColor DarkGray
                Write-Host ""
            }

            # ═══════════════════════════════════════════════════
            # DEPLOY — Despliegue completo
            # ═══════════════════════════════════════════════════
            'Deploy' {
                $cwd = (Get-Location).Path

                # ─── 0. Validaciones ─────────────────────────
                $pubspecPath = Join-Path $cwd "pubspec.yaml"
                $deployYamlPath = Join-Path $cwd "deploy.yaml"

                if (-not (Test-Path $pubspecPath)) {
                    throw "No se encontró pubspec.yaml en $cwd. Ejecute este cmdlet dentro de un proyecto Flutter."
                }
                if (-not (Test-Path $deployYamlPath)) {
                    throw "No se encontró deploy.yaml. Ejecute 'Publish-FlutterWeb -Init' primero."
                }

                # ─── 1. Cargar helpers ───────────────────────
                . "$PSScriptRoot/../Private/PublishHelpers.ps1"
                . "$PSScriptRoot/../Private/Read-SSHConfig.ps1"

                # ─── 2. Leer configuración ───────────────────
                # pubspec.yaml (name, version)
                $pubspec = Get-Content $pubspecPath -Raw | ConvertFrom-Yaml
                $appName = $pubspec.name
                $appVersion = ($pubspec.version -split '\+')[0]  # sin build metadata
                $release = "v$appVersion"

                # deploy.yaml (server, port)
                $deployConfig = Get-Content $deployYamlPath -Raw | ConvertFrom-Yaml
                $server = $deployConfig.server
                $port = $deployConfig.port

                # ─── 3. Validaciones de config ───────────────
                if (-not $server) {
                    throw "No se encontró 'server:' en deploy.yaml."
                }
                if ($server -eq 'your-ssh-alias') {
                    throw "deploy.yaml contiene el valor de ejemplo 'your-ssh-alias'. Cambie 'server' por el alias SSH real de su servidor."
                }
                if (-not $port) {
                    throw "No se encontró 'port:' en deploy.yaml."
                }

                Write-Host "  Proyecto:   $appName" -ForegroundColor Cyan
                Write-Host "  Versión:    $release" -ForegroundColor Cyan
                Write-Host "  Servidor:   $server" -ForegroundColor Cyan
                Write-Host "  Puerto:     $port" -ForegroundColor Cyan
                Write-Host ""

                # ─── 4. SSH Config ───────────────────────────
                $sshConfig = Read-SSHConfig -HostAlias $server
                $user = $sshConfig.User
                $ip = $sshConfig.HostName
                $sshPort = $sshConfig.Port
                $privateKeyPath = $sshConfig.IdentityFile

                # ─── Constantes remotas ──────────────────────
                $remoteWebRoot = "/var/www"
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
                $localZipPath = Join-Path $env:TEMP $zipFileName

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
        }
    }
}
