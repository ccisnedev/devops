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
                throw "Deploy aún no implementado. Ver RUNBOOK step 6."
            }
        }
    }
}
