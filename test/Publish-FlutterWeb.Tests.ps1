# Publish-FlutterWeb.Tests.ps1
# Tests Pester para el cmdlet Publish-FlutterWeb (#10)
# Ejecutar: Invoke-Pester ./test/Publish-FlutterWeb.Tests.ps1

BeforeAll {
    Remove-Module PSDevOps -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot\..\PSDevOps.psd1" -Force
}

# ═══════════════════════════════════════════════════════════════
# STEP 1: Legacy renombrado y exports correctos
# ═══════════════════════════════════════════════════════════════
Describe 'Step 1: Legacy renombrado y exports' {

    Context 'Publish-FlutterWebLegacy — función renombrada' {

        # Verifica que la función legacy existe tras el renombrado.
        # Sin esto, los proyectos que usan Publish-FlutterWebLegacy dejarían de funcionar.
        It 'está disponible como función exportada' {
            $cmd = Get-Command Publish-FlutterWebLegacy -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.CommandType | Should -Be 'Function'
        }

        # El legacy original tenía -server como parámetro obligatorio.
        # El renombrado no debe alterar la firma.
        It 'conserva el parámetro -server del legacy original' {
            $cmd = Get-Command Publish-FlutterWebLegacy
            $cmd.Parameters.Keys | Should -Contain 'server'
        }

        # El archivo fuente debe existir con el nombre nuevo.
        It 'tiene su archivo fuente como Publish-FlutterWebLegacy.ps1' {
            $legacyFile = Join-Path $PSScriptRoot '..\src\Functions\Publish-FlutterWebLegacy.ps1'
            $legacyFile | Should -Exist
        }
    }

    Context 'Archivo legacy antiguo eliminado' {

        # El renombrado debe ser un rename, no una copia.
        # Ahora Publish-FlutterWeb.ps1 existe como la función nueva (Step 3),
        # pero su contenido debe ser distinto al legacy (debe tener ParameterSets).
        It 'Publish-FlutterWeb.ps1 contiene la función nueva, no la legacy' {
            $newFile = Join-Path $PSScriptRoot '..\src\Functions\Publish-FlutterWeb.ps1'
            $content = Get-Content $newFile -Raw
            $content | Should -Match 'ParameterSetName'
        }
    }

    Context 'Exports del manifest PSDevOps.psd1' {

        # El manifest debe exportar el nombre nuevo para que Import-Module lo exponga.
        It 'exporta Publish-FlutterWebLegacy' {
            $manifest = Test-ModuleManifest "$PSScriptRoot\..\PSDevOps.psd1"
            $manifest.ExportedFunctions.Keys | Should -Contain 'Publish-FlutterWebLegacy'
        }

        # A partir de Step 3, Publish-FlutterWeb existe como función nueva.
        It 'exporta Publish-FlutterWeb (función nueva)' {
            $manifest = Test-ModuleManifest "$PSScriptRoot\..\PSDevOps.psd1"
            $manifest.ExportedFunctions.Keys | Should -Contain 'Publish-FlutterWeb'
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# STEP 2: Template deploy.yaml para Publish-FlutterWeb
# ═══════════════════════════════════════════════════════════════
Describe 'Step 2: Template deploy.yaml' {

    BeforeAll {
        $templateDir = Join-Path $PSScriptRoot '..\src\Resources\Publish-FlutterWeb\templates'
        $templatePath = Join-Path $templateDir 'deploy.yaml'
    }

    Context 'Estructura de archivos' {

        # El directorio de templates debe existir siguiendo la convención de Publish-NodeApi.
        It 'existe el directorio src/Resources/Publish-FlutterWeb/templates/' {
            $templateDir | Should -Exist
        }

        # El template deploy.yaml debe existir dentro del directorio de templates.
        It 'existe el archivo deploy.yaml en el directorio de templates' {
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
        It 'contiene la clave server con un valor placeholder' {
            $content.server | Should -Not -BeNullOrEmpty
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

        # Debe tener ParameterSets Init y Deploy, igual que Publish-NodeApi.
        It 'tiene ParameterSets Init y Deploy' {
            $cmd = Get-Command Publish-FlutterWeb
            $sets = $cmd.ParameterSets | Select-Object -ExpandProperty Name
            $sets | Should -Contain 'Init'
            $sets | Should -Contain 'Deploy'
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

        # -Init no debe lanzar excepción cuando pubspec.yaml existe y deploy.yaml no existe.
        It 'no lanza excepción cuando pubspec.yaml existe' {
            $script:initError | Should -BeNullOrEmpty
        }

        # Debe crear deploy.yaml en el directorio actual del proyecto.
        It 'crea deploy.yaml en el directorio del proyecto' {
            Join-Path $testDir 'deploy.yaml' | Should -Exist
        }

        # El deploy.yaml creado debe tener las claves server y port (copiado del template).
        It 'deploy.yaml generado contiene server y port' {
            $content = Get-Content (Join-Path $testDir 'deploy.yaml') -Raw | ConvertFrom-Yaml
            $content.server | Should -Not -BeNullOrEmpty
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

        # Si deploy.yaml ya existe, -Init no debe sobreescribirlo — protege config existente.
        It 'falla si deploy.yaml ya existe' {
            $dupDir = Join-Path $env:TEMP "psdevops_test_dup_$([guid]::NewGuid().ToString().Substring(0,8))"
            New-Item -ItemType Directory -Path $dupDir -Force | Out-Null
            Set-Content -Path (Join-Path $dupDir 'pubspec.yaml') -Value "name: dup_app`nversion: 1.0.0" -Encoding UTF8
            Set-Content -Path (Join-Path $dupDir 'deploy.yaml') -Value "server: x" -Encoding UTF8
            try {
                Push-Location $dupDir
                { Publish-FlutterWeb -Init -ErrorAction Stop } | Should -Throw '*deploy.yaml*'
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
        $scriptPath = Join-Path $PSScriptRoot '..\src\Private\scripts\Install-FlutterWeb.sh'
    }

    Context 'Archivo existe y estructura básica' {

        # El script debe existir en la ruta convencional de scripts bash.
        It 'existe en src/Private/scripts/' {
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
            . "$PSScriptRoot\..\src\Private\PublishHelpers.ps1"
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
        $scriptPath = Join-Path $PSScriptRoot '..\src\Private\scripts\Configure-NginxSite.sh'
    }

    Context 'Archivo existe y estructura básica' {

        It 'existe en src/Private/scripts/' {
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
    }

    Context 'Get-BashScript puede procesar el script' {

        BeforeAll {
            . "$PSScriptRoot\..\src\Private\PublishHelpers.ps1"
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
