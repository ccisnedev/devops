# Publish-FlutterWeb.Tests.ps1
# Tests Pester para el cmdlet Publish-FlutterWeb (#10)
# Ejecutar: Invoke-Pester ./test/Publish-FlutterWeb.Tests.ps1

BeforeAll {
    Remove-Module 'macss-devops' -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot\..\macss-devops.psd1" -Force
}

# ═══════════════════════════════════════════════════════════════
# STEP 1: Legacy retirado y exports correctos
# ═══════════════════════════════════════════════════════════════
Describe 'Step 1: Legacy retirado y exports' {

    Context 'Publish-FlutterWebLegacy — retirado en 6.0.0 (ADR 0012)' {

        # Hasta 5.x emitia un Write-Warning y seguia funcionando. ADR 0012 retiro ese modelo, y la
        # busqueda de uso real en la organizacion no encontro ni un llamador: se borra sin fase
        # intermedia. Conservar la funcion "para poder fallar bien" no tendria a quien explicarle
        # nada, y seria la misma deuda con otro disfraz.
        It 'ya no esta disponible como comando' {
            Get-Command Publish-FlutterWebLegacy -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }

        It 'su archivo fuente fue eliminado' {
            Join-Path $PSScriptRoot '..\Functions\Publish-FlutterWebLegacy.ps1' | Should -Not -Exist
        }
    }

    Context 'Archivo legacy antiguo eliminado' {

        # El renombrado debe ser un rename, no una copia.
        # Ahora Publish-FlutterWeb.ps1 existe como la función nueva (Step 3),
        # pero su contenido debe ser distinto al legacy (debe tener ParameterSets).
        It 'Publish-FlutterWeb.ps1 contiene la función nueva, no la legacy' {
            $newFile = Join-Path $PSScriptRoot '..\Functions\Publish-FlutterWeb.ps1'
            $content = Get-Content $newFile -Raw
            $content | Should -Match 'ParameterSetName'
        }
    }

    Context 'Exports del manifest macss-devops.psd1' {

        # Retirado en 6.0.0: el manifiesto no debe seguir anunciandolo.
        It 'ya no exporta Publish-FlutterWebLegacy' {
            $manifest = Test-ModuleManifest "$PSScriptRoot\..\macss-devops.psd1"
            $manifest.ExportedFunctions.Keys | Should -Not -Contain 'Publish-FlutterWebLegacy'
        }

        # A partir de Step 3, Publish-FlutterWeb existe como función nueva.
        It 'exporta Publish-FlutterWeb (función nueva)' {
            $manifest = Test-ModuleManifest "$PSScriptRoot\..\macss-devops.psd1"
            $manifest.ExportedFunctions.Keys | Should -Contain 'Publish-FlutterWeb'
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# STEP 2: Template publish.yaml para Publish-FlutterWeb
# ═══════════════════════════════════════════════════════════════
Describe 'Step 2: Template publish.yaml' {

    BeforeAll {
        $templateDir = Join-Path $PSScriptRoot '..\Resources\Publish-FlutterWeb\templates'
        $templatePath = Join-Path $templateDir 'publish.yaml'
    }

    Context 'Estructura de archivos' {

        # El directorio de templates debe existir siguiendo la convención de Publish-NodeApi.
        It 'existe el directorio code/powershell/Resources/Publish-FlutterWeb/templates/' {
            $templateDir | Should -Exist
        }

        # El template publish.yaml debe existir dentro del directorio de templates.
        It 'existe el archivo publish.yaml en el directorio de templates' {
            $templatePath | Should -Exist
        }
    }

    Context 'Contenido del template' {

        BeforeAll {
            $content = if (Test-Path $templatePath) {
                Get-Content $templatePath -Raw | ConvertFrom-Yaml
            } else {
                @{}
            }
            $rawContent = if (Test-Path $templatePath) {
                Get-Content $templatePath -Raw
            } else {
                ''
            }
        }

        # El template debe tener la clave 'server' con un valor placeholder.
        # Es la única forma de saber a qué servidor desplegar (alias en ~/.ssh/config).
        It 'ya no declara server: — el destino vive en el env file (ADR 0010)' {
            $content.server | Should -BeNullOrEmpty
        }

        # El template debe tener la clave 'port' con un valor numérico.
        # Es el puerto donde nginx escuchará para esta app.
        It 'contiene la clave port con un valor numérico' {
            $content.port | Should -BeOfType [int]
        }

        # No debe incluir name ni version — se leen de pubspec.yaml (source of truth).
        # Esto evita duplicación y desincronización.
        It 'no contiene la clave name (se lee de pubspec.yaml)' {
            $content.Keys | Should -Not -Contain 'name'
        }

        It 'no contiene la clave version (se lee de pubspec.yaml)' {
            $content.Keys | Should -Not -Contain 'version'
        }

        # El template debe indicar que fue generado por Publish-FlutterWeb -Init.
        It 'incluye comentario indicando el generador (Publish-FlutterWeb -Init)' {
            $rawContent | Should -Match 'Publish-FlutterWeb'
        }

        # El template debe advertir que name/version se leen de pubspec.yaml.
        It 'incluye comentario indicando que name/version vienen de pubspec.yaml' {
            $rawContent | Should -Match 'pubspec\.yaml'
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# STEP 3: Publish-FlutterWeb -Init
# ═══════════════════════════════════════════════════════════════
Describe 'Step 3: Publish-FlutterWeb -Init' {

    BeforeAll {
        # Directorio temporal que simula un proyecto Flutter
        $testDir = Join-Path $env:TEMP "psdevops_test_flutter_$([guid]::NewGuid().ToString().Substring(0,8))"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null

        # pubspec.yaml mínimo de un proyecto Flutter
        $pubspec = @"
name: test_app
description: A test Flutter app
version: 2.1.0+5

environment:
  sdk: ^3.0.0
"@
        Set-Content -Path (Join-Path $testDir 'pubspec.yaml') -Value $pubspec -Encoding UTF8
    }

    AfterAll {
        Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'Función disponible y metadata' {

        # Publish-FlutterWeb debe existir como función exportada con los ParameterSets correctos.
        It 'está disponible como función exportada' {
            $cmd = Get-Command Publish-FlutterWeb -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.CommandType | Should -Be 'Function'
        }

        # Debe tener ParameterSets Init y Apply (ADR 0002), igual que Publish-NodeApi.
        It 'tiene ParameterSets Init y Apply (ADR 0002)' {
            $cmd = Get-Command Publish-FlutterWeb
            $sets = $cmd.ParameterSets | Select-Object -ExpandProperty Name
            $sets | Should -Contain 'Init'
            $sets | Should -Contain 'Apply'
        }
    }

    Context 'Ejecución exitosa en proyecto Flutter' {

        BeforeAll {
            Push-Location $testDir
            try {
                # Ejecutar -Init y capturar resultado sin errores
                $script:initError = $null
                Publish-FlutterWeb -Init -ErrorAction Stop 2>$null
            } catch {
                $script:initError = $_
            }
        }

        AfterAll {
            Pop-Location
        }

        # -Init no debe lanzar excepción cuando pubspec.yaml existe y publish.yaml no existe.
        It 'no lanza excepción cuando pubspec.yaml existe' {
            $script:initError | Should -BeNullOrEmpty
        }

        # Debe crear publish.yaml en el directorio actual del proyecto.
        It 'crea publish.yaml en el directorio del proyecto' {
            Join-Path $testDir 'publish.yaml' | Should -Exist
        }

        # El publish.yaml creado debe tener las claves server y port (copiado del template).
        It 'publish.yaml generado contiene port y ya no server' {
            $content = Get-Content (Join-Path $testDir 'publish.yaml') -Raw | ConvertFrom-Yaml
            $content.server | Should -BeNullOrEmpty
            $content.port | Should -BeOfType [int]
        }
    }

    Context 'Validaciones de error' {

        # Sin pubspec.yaml no es un proyecto Flutter — debe fallar con error claro.
        It 'falla si no existe pubspec.yaml' {
            $emptyDir = Join-Path $env:TEMP "psdevops_test_empty_$([guid]::NewGuid().ToString().Substring(0,8))"
            New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
            try {
                Push-Location $emptyDir
                { Publish-FlutterWeb -Init -ErrorAction Stop } | Should -Throw '*pubspec.yaml*'
            } finally {
                Pop-Location
                Remove-Item -Path $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # Si publish.yaml o el legacy deploy.yaml ya existen, -Init no debe sobreescribir — protege config existente.
        It 'falla si deploy.yaml (legacy) ya existe' {
            $dupDir = Join-Path $env:TEMP "psdevops_test_dup_$([guid]::NewGuid().ToString().Substring(0,8))"
            New-Item -ItemType Directory -Path $dupDir -Force | Out-Null
            Set-Content -Path (Join-Path $dupDir 'pubspec.yaml') -Value "name: dup_app`nversion: 1.0.0" -Encoding UTF8
            Set-Content -Path (Join-Path $dupDir 'deploy.yaml') -Value "server: x" -Encoding UTF8
            try {
                Push-Location $dupDir
                { Publish-FlutterWeb -Init -ErrorAction Stop } | Should -Throw '*publish.yaml*'
            } finally {
                Pop-Location
                Remove-Item -Path $dupDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# STEP 4: Script bash Install-FlutterWeb.sh
# ═══════════════════════════════════════════════════════════════
Describe 'Step 4: Install-FlutterWeb.sh' {

    BeforeAll {
        $scriptPath = Join-Path $PSScriptRoot '..\Private\scripts\Install-FlutterWeb.sh'
    }

    Context 'Archivo existe y estructura básica' {

        # El script debe existir en la ruta convencional de scripts bash.
        It 'existe en code/powershell/Private/scripts/' {
            $scriptPath | Should -Exist
        }

        # Debe iniciar con shebang bash y set -e para fallo inmediato.
        It 'tiene shebang bash y set -e' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '^#!/bin/bash'
            $content | Should -Match 'set -e'
        }
    }

    Context 'Placeholders para Get-BashScript' {

        BeforeAll {
            $content = if (Test-Path $scriptPath) { Get-Content $scriptPath -Raw } else { '' }
        }

        # __NAME__ se reemplaza con el nombre del proyecto (de pubspec.yaml).
        It 'contiene placeholder __NAME__' {
            $content | Should -Match '__NAME__'
        }

        # __VERSION__ se reemplaza con la versión (de pubspec.yaml, sin build metadata).
        It 'contiene placeholder __VERSION__' {
            $content | Should -Match '__VERSION__'
        }

        # __WEB_ROOT__ se reemplaza con la raíz web (ej: /var/www).
        It 'contiene placeholder __WEB_ROOT__' {
            $content | Should -Match '__WEB_ROOT__'
        }
    }

    Context 'Lógica de releases y symlink' {

        BeforeAll {
            $content = if (Test-Path $scriptPath) { Get-Content $scriptPath -Raw } else { '' }
        }

        # Debe crear el directorio de releases versionado.
        It 'crea directorio de release versionado' {
            $content | Should -Match 'releases/v'
        }

        # Debe crear/actualizar el symlink current de forma atómica (ln -sfn).
        It 'actualiza symlink current con ln -sfn' {
            $content | Should -Match 'ln -sfn'
        }

        # Los archivos web deben pertenecer a www-data (usuario nginx).
        It 'ajusta permisos a www-data' {
            $content | Should -Match 'www-data'
        }

        # Debe verificar que index.html existe tras la extracción.
        It 'verifica que index.html existe en el release' {
            $content | Should -Match 'index\.html'
        }
    }

    Context 'Get-BashScript puede procesar el script' {

        BeforeAll {
            # Get-BashScript es función privada — cargarla directamente
            . "$PSScriptRoot\..\Private\PublishHelpers.ps1"
        }

        # Get-BashScript debe poder leer el archivo y reemplazar todos los placeholders
        # sin errores. Esto valida que el script es compatible con el helper.
        It 'Get-BashScript reemplaza todos los placeholders correctamente' {
            $result = Get-BashScript -ScriptName 'Install-FlutterWeb.sh' -Placeholders @{
                '__NAME__'     = 'test_app'
                '__VERSION__'  = '1.0.0'
                '__WEB_ROOT__' = '/var/www'
            }
            $result | Should -Not -BeNullOrEmpty
            $result | Should -Not -Match '__NAME__'
            $result | Should -Not -Match '__VERSION__'
            $result | Should -Not -Match '__WEB_ROOT__'
            $result | Should -Match 'test_app'
            $result | Should -Match '/var/www'
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# STEP 5: Script bash Configure-NginxSite.sh
# ═══════════════════════════════════════════════════════════════
Describe 'Step 5: Configure-NginxSite.sh' {

    BeforeAll {
        $scriptPath = Join-Path $PSScriptRoot '..\Private\scripts\Configure-NginxSite.sh'
    }

    Context 'Archivo existe y estructura básica' {

        It 'existe en code/powershell/Private/scripts/' {
            $scriptPath | Should -Exist
        }

        It 'tiene shebang bash y set -e' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '^#!/bin/bash'
            $content | Should -Match 'set -e'
        }
    }

    Context 'Placeholders para Get-BashScript' {

        BeforeAll {
            $content = if (Test-Path $scriptPath) { Get-Content $scriptPath -Raw } else { '' }
        }

        # __NAME__ determina el nombre del archivo en sites-available y el root.
        It 'contiene placeholder __NAME__' {
            $content | Should -Match '__NAME__'
        }

        # __PORT__ es el puerto donde nginx escuchará para esta app.
        It 'contiene placeholder __PORT__' {
            $content | Should -Match '__PORT__'
        }
    }

    Context 'Lógica de nginx' {

        BeforeAll {
            $content = if (Test-Path $scriptPath) { Get-Content $scriptPath -Raw } else { '' }
        }

        # Debe verificar si ya existe config en sites-available antes de crear.
        It 'verifica si config ya existe en sites-available' {
            $content | Should -Match 'sites-available'
        }

        # La config nginx debe usar listen <port> (no el default 80).
        It 'genera config con listen en el puerto especificado' {
            $content | Should -Match 'listen'
        }

        # El root debe apuntar al symlink current, no directamente a releases.
        It 'apunta root a /current (symlink)' {
            $content | Should -Match 'current'
        }

        # Debe usar try_files con fallback a index.html (SPA Flutter).
        It 'usa try_files con fallback a index.html' {
            $content | Should -Match 'try_files'
            $content | Should -Match 'index\.html'
        }

        # Debe crear symlink en sites-enabled.
        It 'crea symlink en sites-enabled' {
            $content | Should -Match 'sites-enabled'
        }

        # Debe validar con nginx -t antes de recargar.
        It 'valida config con nginx -t' {
            $content | Should -Match 'nginx -t'
        }

        # Debe recargar nginx solo si la validación pasa.
        It 'recarga nginx con systemctl reload' {
            $content | Should -Match 'systemctl reload nginx'
        }

        # Antes de crear la config, debe verificar que el puerto no esté en uso
        # por otro proceso. Si está ocupado, el reload de nginx fallaría con
        # "address already in use". Mejor detectarlo con un mensaje claro.
        It 'verifica que el puerto esté libre antes de crear config (ss)' {
            $content | Should -Match 'ss.*sport.*__PORT__\b|ss.*sport.*\$PORT\b|ss.*sport.*\$\{?PORT\}?'
        }
    }

    Context 'Get-BashScript puede procesar el script' {

        BeforeAll {
            . "$PSScriptRoot\..\Private\PublishHelpers.ps1"
        }

        It 'reemplaza todos los placeholders correctamente' {
            $result = Get-BashScript -ScriptName 'Configure-NginxSite.sh' -Placeholders @{
                '__NAME__' = 'test_app'
                '__PORT__' = '4036'
            }
            $result | Should -Not -BeNullOrEmpty
            $result | Should -Not -Match '__NAME__'
            $result | Should -Not -Match '__PORT__'
            $result | Should -Match 'test_app'
            $result | Should -Match '4036'
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# STEP 6: Publish-FlutterWeb -Apply (flujo completo)
# ═══════════════════════════════════════════════════════════════
Describe 'Step 6: Publish-FlutterWeb -Apply' {

    Context 'Validaciones de entrada' {

        # Sin pubspec.yaml no se puede leer name y version — debe fallar.
        It 'falla si no existe pubspec.yaml' {
            $emptyDir = Join-Path $env:TEMP "psdevops_test_deploy_nopub_$([guid]::NewGuid().ToString().Substring(0,8))"
            New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
            Set-Content -Path (Join-Path $emptyDir 'deploy.yaml') -Value "server: test`nport: 4000" -Encoding UTF8
            try {
                Push-Location $emptyDir
                { Publish-FlutterWeb -Apply -AutoApprove -ErrorAction Stop } | Should -Throw '*pubspec.yaml*'
            } finally {
                Pop-Location
                Remove-Item -Path $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # Sin publish.yaml no se conoce el servidor ni el puerto — debe fallar.
        It 'falla si no existe publish.yaml' {
            $noDeployDir = Join-Path $env:TEMP "psdevops_test_deploy_noyaml_$([guid]::NewGuid().ToString().Substring(0,8))"
            New-Item -ItemType Directory -Path $noDeployDir -Force | Out-Null
            Set-Content -Path (Join-Path $noDeployDir 'pubspec.yaml') -Value "name: x`nversion: 1.0.0" -Encoding UTF8
            try {
                Push-Location $noDeployDir
                { Publish-FlutterWeb -Apply -AutoApprove -ErrorAction Stop } | Should -Throw '*publish.yaml*'
            } finally {
                Pop-Location
                Remove-Item -Path $noDeployDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # deploy.yaml con el valor placeholder por defecto debe rechazarse.
        It 'falla si deploy.yaml tiene valor placeholder (app-server)' {
            $placeholderDir = Join-Path $env:TEMP "psdevops_test_deploy_placeholder_$([guid]::NewGuid().ToString().Substring(0,8))"
            New-Item -ItemType Directory -Path $placeholderDir -Force | Out-Null
            Set-Content -Path (Join-Path $placeholderDir 'pubspec.yaml') -Value "name: x`nversion: 1.0.0" -Encoding UTF8
            Set-Content -Path (Join-Path $placeholderDir 'deploy.yaml') -Value "server: your-ssh-alias`nport: 4000" -Encoding UTF8
            try {
                Push-Location $placeholderDir
                { Publish-FlutterWeb -Apply -AutoApprove -ErrorAction Stop } | Should -Throw '*MACSS_DEPLOY_SSH_ALIAS*'
            } finally {
                Pop-Location
                Remove-Item -Path $placeholderDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Lectura correcta de configuración' {

        BeforeAll {
            $configDir = Join-Path $env:TEMP "psdevops_test_deploy_config_$([guid]::NewGuid().ToString().Substring(0,8))"
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null

            # pubspec.yaml con versión que incluye build metadata
            $pubspec = @"
name: tigre_regalon_2
version: 3.5.1+12
environment:
  sdk: ^3.0.0
"@
            Set-Content -Path (Join-Path $configDir 'pubspec.yaml') -Value $pubspec -Encoding UTF8

            # deploy.yaml con server real y puerto
            $deploy = @"
server: real-server
port: 4036
"@
            Set-Content -Path (Join-Path $configDir 'deploy.yaml') -Value $deploy -Encoding UTF8
        }

        AfterAll {
            Remove-Item -Path $configDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        # El deploy lee name de pubspec.yaml. Verificamos que la función
        # intenta leer SSH config con Read-SSHConfig (que falla porque
        # 'real-server' no existe en ~/.ssh/config) — lo que demuestra
        # que la lectura de pubspec+deploy pasó correctamente.
        It 'lee name de pubspec.yaml y server de deploy.yaml antes de fallar en SSH' {
            Push-Location $configDir
            try {
                $threwSSH = $false
                try {
                    Publish-FlutterWeb -Apply -AutoApprove -ErrorAction Stop *>&1 | Out-Null
                } catch {
                    # Esperamos fallo en Read-SSHConfig o posterior — no en validación de archivos
                    $threwSSH = $_.Exception.Message -notmatch 'pubspec\.yaml|deploy\.yaml|app-server'
                }
                $threwSSH | Should -BeTrue -Because "La lectura de config pasó; debió fallar en SSH o posterior"
            } finally {
                Pop-Location
            }
        }

        # La versión debe limpiarse de build metadata (+12)
        It 'extrae versión sin build metadata (3.5.1, no 3.5.1+12)' {
            # Re-importar helpers para acceder a ConvertFrom-Yaml
            $pubspec = Get-Content (Join-Path $configDir 'pubspec.yaml') -Raw | ConvertFrom-Yaml
            $version = ($pubspec.version -split '\+')[0]
            $version | Should -Be '3.5.1'
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# STEP 7: Eliminar Publish-Web y limpiar exports
# ═══════════════════════════════════════════════════════════════
Describe 'Step 7: Eliminar Publish-Web' {

    Context 'Archivo fuente eliminado' {

        # Publish-Web.ps1 modificaba /etc/nginx/sites-available/default (mala práctica).
        # Fue reemplazado por Publish-FlutterWeb -Apply -AutoApprove con config nginx por puerto.
        It 'Publish-Web.ps1 ya no existe en code/powershell/Functions/' {
            $webFile = Join-Path $PSScriptRoot '..\Functions\Publish-Web.ps1'
            $webFile | Should -Not -Exist
        }
    }

    Context 'Exports del manifest macss-devops.psd1' {

        # El manifest no debe exportar Publish-Web — fue eliminado.
        It 'no exporta Publish-Web' {
            $manifest = Test-ModuleManifest "$PSScriptRoot\..\macss-devops.psd1"
            $manifest.ExportedFunctions.Keys | Should -Not -Contain 'Publish-Web'
        }

        # Publish-FlutterWeb y Publish-FlutterWebLegacy deben seguir presentes.
        It 'sigue exportando Publish-FlutterWeb' {
            $manifest = Test-ModuleManifest "$PSScriptRoot\..\macss-devops.psd1"
            $manifest.ExportedFunctions.Keys | Should -Contain 'Publish-FlutterWeb'
        }

        It 'ya no exporta Publish-FlutterWebLegacy (retirado en 6.0.0)' {
            $manifest = Test-ModuleManifest "$PSScriptRoot\..\macss-devops.psd1"
            $manifest.ExportedFunctions.Keys | Should -Not -Contain 'Publish-FlutterWebLegacy'
        }
    }

    Context 'Función no disponible en runtime' {

        # Después de re-importar el módulo, Publish-Web no debe existir como función.
        It 'Publish-Web no está disponible como función' {
            $cmd = Get-Command Publish-Web -ErrorAction SilentlyContinue
            $cmd | Should -BeNullOrEmpty
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# STEP 9: Publish-FlutterWeb -Plan (reporte pre-deploy)
# ═══════════════════════════════════════════════════════════════
Describe 'Step 9: Publish-FlutterWeb -Plan (reporte pre-deploy)' {

    Context 'ParameterSet existe' {

        # -Plan debe ser un ParameterSet válido junto a Init y Apply (ADR 0002).
        It 'tiene ParameterSet Plan (ADR 0002)' {
            $cmd = Get-Command Publish-FlutterWeb
            $sets = $cmd.ParameterSets | Select-Object -ExpandProperty Name
            $sets | Should -Contain 'Plan'
        }

        # El default es Apply (ADR 0002).
        It 'DefaultParameterSetName es Apply (ADR 0002)' {
            $cmd = Get-Command Publish-FlutterWeb
            $cmd.DefaultParameterSet | Should -Be 'Apply'
        }
    }

    Context 'Validaciones de entrada (mismas que -Publish)' {

        # Sin pubspec.yaml debe fallar igual que -Publish.
        It 'falla si no existe pubspec.yaml' {
            $emptyDir = Join-Path $env:TEMP "psdevops_test_dr_nopub_$([guid]::NewGuid().ToString().Substring(0,8))"
            New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
            Set-Content -Path (Join-Path $emptyDir 'deploy.yaml') -Value "server: test`nport: 4000" -Encoding UTF8
            try {
                Push-Location $emptyDir
                { Publish-FlutterWeb -Plan -ErrorAction Stop } | Should -Throw '*pubspec.yaml*'
            } finally {
                Pop-Location
                Remove-Item -Path $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # Sin deploy.yaml debe fallar.
        It 'falla si no existe publish.yaml' {
            $noDeployDir = Join-Path $env:TEMP "psdevops_test_dr_noyaml_$([guid]::NewGuid().ToString().Substring(0,8))"
            New-Item -ItemType Directory -Path $noDeployDir -Force | Out-Null
            Set-Content -Path (Join-Path $noDeployDir 'pubspec.yaml') -Value "name: x`nversion: 1.0.0" -Encoding UTF8
            try {
                Push-Location $noDeployDir
                { Publish-FlutterWeb -Plan -ErrorAction Stop } | Should -Throw '*publish.yaml*'
            } finally {
                Pop-Location
                Remove-Item -Path $noDeployDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # Placeholder server debe rechazarse.
        It 'falla si deploy.yaml tiene valor placeholder' {
            $placeholderDir = Join-Path $env:TEMP "psdevops_test_dr_ph_$([guid]::NewGuid().ToString().Substring(0,8))"
            New-Item -ItemType Directory -Path $placeholderDir -Force | Out-Null
            Set-Content -Path (Join-Path $placeholderDir 'pubspec.yaml') -Value "name: x`nversion: 1.0.0" -Encoding UTF8
            Set-Content -Path (Join-Path $placeholderDir 'deploy.yaml') -Value "server: your-ssh-alias`nport: 4000" -Encoding UTF8
            try {
                Push-Location $placeholderDir
                { Publish-FlutterWeb -Plan -ErrorAction Stop } | Should -Throw '*MACSS_DEPLOY_SSH_ALIAS*'
            } finally {
                Pop-Location
                Remove-Item -Path $placeholderDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Contenido del reporte (requiere servidor real)' {

        # Este test verifica que -DeployReport NO compila ni despliega,
        # solamente consulta el servidor y muestra información.
        # Usa el alias 'real-server' que no existe en SSH config,
        # así falla en Read-SSHConfig — demostrando que NO intenta compilar antes.
        It 'no invoca Invoke-FlutterBuild (falla en SSH antes de compilar)' {
            $reportDir = Join-Path $env:TEMP "psdevops_test_dr_nobuild_$([guid]::NewGuid().ToString().Substring(0,8))"
            New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
            Set-Content -Path (Join-Path $reportDir 'pubspec.yaml') -Value "name: testapp`nversion: 2.0.0" -Encoding UTF8
            Set-Content -Path (Join-Path $reportDir 'deploy.yaml') -Value "server: real-server`nport: 4050" -Encoding UTF8
            try {
                Push-Location $reportDir
                $threwSSH = $false
                try {
                    Publish-FlutterWeb -Plan -ErrorAction Stop *>&1 | Out-Null
                } catch {
                    # Debe fallar en SSH, NO en "flutter build" o similar
                    $threwSSH = $_.Exception.Message -notmatch 'pubspec\.yaml|deploy\.yaml|your-ssh-alias|flutter|build'
                }
                $threwSSH | Should -BeTrue -Because "Debe fallar en SSH, no en compilación"
            } finally {
                Pop-Location
                Remove-Item -Path $reportDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# STEP 10: Paridad -Plan / -Apply (ADR 0009)
# ═══════════════════════════════════════════════════════════════
# El ADR 0002 §"Confirmation flow" paso 1 ya mandaba reutilizar el render de -Plan en -Apply,
# y se incumplió en silencio durante versiones. Estos guards son estructurales: fallan si
# alguien vuelve a darle a -Apply un render propio, sin necesidad de un servidor.
Describe 'Step 10: paridad -Plan/-Apply (ADR 0009)' {

    BeforeAll {
        $src = Get-Content "$PSScriptRoot/../Functions/Publish-FlutterWeb.ps1" -Raw
        # Trocea el switch en sus ramas para poder afirmar sobre cada una por separado.
        $applyStart = $src.IndexOf("'Apply' {")
        $planStart = $src.IndexOf("'Plan' {")
        $applyStart | Should -BeGreaterThan 0
        $planStart | Should -BeGreaterThan $applyStart
        $script:applyBranch = $src.Substring($applyStart, $planStart - $applyStart)
        $script:planBranch = $src.Substring($planStart)
    }

    Context 'Ambas ramas construyen y muestran el MISMO plan' {

        It '-Apply usa el builder compartido Get-FlutterWebPlan' {
            $script:applyBranch | Should -Match 'Get-FlutterWebPlan'
        }

        It '-Plan usa el builder compartido Get-FlutterWebPlan' {
            $script:planBranch | Should -Match 'Get-FlutterWebPlan'
        }

        It '-Apply renderiza con Show-DeployPlan (no con Write-Host propio)' {
            $script:applyBranch | Should -Match 'Show-DeployPlan'
        }

        It '-Plan renderiza con Show-DeployPlan' {
            $script:planBranch | Should -Match 'Show-DeployPlan'
        }

        # El sondeo del servidor vive en el builder: si una rama volviera a incrustar el
        # script bash de reporte, sería una copia divergente del estado que muestra la otra.
        It 'ninguna rama reimplementa el sondeo remoto (CURRENT:/RELEASE:/NGINX:)' {
            $script:applyBranch | Should -Not -Match 'CURRENT:'
            $script:planBranch | Should -Not -Match 'CURRENT:'
        }
    }

    Context 'Solo -Plan persiste el artefacto' {

        It '-Plan escribe el reporte con Save-DeployPlan' {
            $script:planBranch | Should -Match 'Save-DeployPlan'
        }

        It '-Apply NO escribe reporte (es una acción, no un dry-run archivable)' {
            $script:applyBranch | Should -Not -Match 'Save-DeployPlan'
        }
    }

    Context 'Guard de bloqueantes en -Apply' {

        It '-Apply consulta Get-DeployPlanBlocker' {
            $script:applyBranch | Should -Match 'Get-DeployPlanBlocker'
        }

        # Debe abortar ANTES de confirmar y compilar: con -AutoApprove nadie lee la fila roja.
        It 'evalúa los bloqueantes antes de Confirm-MacssChange' {
            $iBlocker = $script:applyBranch.IndexOf('Get-DeployPlanBlocker')
            $iConfirm = $script:applyBranch.IndexOf('Confirm-MacssChange')
            $iBlocker | Should -BeGreaterThan 0
            $iConfirm | Should -BeGreaterThan $iBlocker
        }

        It '-Force es la única vía para continuar pese a un bloqueante' {
            $script:applyBranch | Should -Match '-not \$Force'
        }

        It '-Plan no aborta por bloqueantes (solo informa)' {
            $script:planBranch | Should -Not -Match 'Get-DeployPlanBlocker'
        }
    }

    Context 'Parámetro -Force' {

        BeforeAll { $script:cmd = Get-Command Publish-FlutterWeb }

        It 'existe y pertenece al set Apply' {
            $script:cmd.Parameters.ContainsKey('Force') | Should -BeTrue
            $script:cmd.Parameters['Force'].ParameterSets.Keys | Should -Contain 'Apply'
        }

        It 'no está disponible en el set Plan (un dry-run no fuerza nada)' {
            $script:cmd.Parameters['Force'].ParameterSets.Keys | Should -Not -Contain 'Plan'
        }
    }
}
