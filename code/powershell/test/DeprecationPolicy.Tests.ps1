# DeprecationPolicy.Tests.ps1
# Tests de la política de deprecación del módulo (ADR 0012).
#
# Una deprecación falla con instrucciones; no avisa y continúa. La evidencia de que el aviso no
# funciona estaba en la propia suite: el warning de `-Publish`/`-DeployReport`, deprecados desde
# ADR 0002, se imprimía decenas de veces al correr los tests. Un mensaje que aparece siempre deja
# de leerse.
#
# La regla es por evidencia, no por calendario: se busca el uso real antes de decidir. Si quedan
# llamadores, se falla con instrucciones y el borrado espera (`deploy.yaml`, `MACSS_DEPLOY_SERVER`).
# Si no quedan, se borra: mantener andamiaje para explicarle algo a nadie es la misma deuda con otro
# disfraz. Los alias `-Publish`/`-DeployReport` y `Publish-FlutterWebLegacy` cayeron del segundo
# lado, tras migrar sus cuatro llamadores reales.
#
# Cubre REQ-1 a REQ-6 de ADR 0012.

BeforeAll {
    # Remove-Module por nombre quita UNA version. Si el modulo publicado esta instalado en
    # PSModulePath, puede quedar cargado junto al del repo y ganar la resolucion de nombres: la
    # suite pasaria a medir el modulo instalado en vez del codigo bajo prueba. -All las quita todas.
    Get-Module 'macss-devops' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot\..\macss-devops.psd1" -Force
    . "$PSScriptRoot/../Private/PublishHelpers.ps1"

    function Get-ThrownMessage {
        param([scriptblock]$Action)
        try { & $Action *> $null; return $null } catch { return $_.Exception.Message }
    }

    function New-FlutterProject {
        param([string]$ConfigName = 'publish.yaml')
        $root = Join-Path ([IO.Path]::GetTempPath()) ("macss_dep_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -Path (Join-Path $root 'pubspec.yaml') -Value "name: dep_app`nversion: 1.0.0" -Encoding UTF8
        Set-Content -Path (Join-Path $root $ConfigName) -Value "port: 4000" -Encoding UTF8
        Set-Content -Path (Join-Path $root '.env') -Value "MACSS_DEPLOY_SSH_ALIAS=alias-inexistente-xyz" -Encoding UTF8
        return $root
    }
}

Describe "REQ-1: el mensaje de deprecación lo produce un solo helper" {

    It "Deny-DeprecatedUsage está disponible" {
        Get-Command Deny-DeprecatedUsage -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "el mensaje lleva cmdlet, elemento deprecado, reemplazo y versión de retiro" {
        $msg = Get-ThrownMessage {
            Deny-DeprecatedUsage -Cmdlet 'Publish-NodeApi' -What '-Publish' `
                                 -UseInstead '-Apply' -Since '6.0.0' -Reference 'ADR 0002'
        }
        $msg | Should -Match 'Publish-NodeApi'
        $msg | Should -Match '\-Publish'
        $msg | Should -Match '\-Apply'
        $msg | Should -Match '6\.0\.0'
        $msg | Should -Match 'ADR 0002'
    }
}

Describe "REQ-2: los alias sin llamadores se borran" {

    # No se conservan "para poder fallar bien": no queda nadie a quien explicarle nada. Los cuatro
    # llamadores reales --tres plantillas de organizacion y el workflow de retiro-- se migraron a
    # -Apply -AutoApprove antes de tocar el modulo. Un quinto sitio aparente resulto ser un repo
    # archivado, que no ejecuta workflows.
    It "<Cmdlet> ya no declara -DeployReport" -ForEach @(
        @{ Cmdlet = 'Publish-NodeApi' }
        @{ Cmdlet = 'Publish-FlutterWeb' }
        @{ Cmdlet = 'Invoke-SqlPackage' }
    ) {
        (Get-Command $Cmdlet).Parameters['Plan'].Aliases | Should -Not -Contain 'DeployReport'
    }

    It "<Cmdlet> ya no declara -Publish" -ForEach @(
        @{ Cmdlet = 'Publish-NodeApi' }
        @{ Cmdlet = 'Publish-FlutterWeb' }
        @{ Cmdlet = 'Invoke-SqlPackage' }
    ) {
        (Get-Command $Cmdlet).Parameters['Apply'].Aliases | Should -Not -Contain 'Publish'
    }
}

Describe "REQ-3: borrar el alias no altera la taxonomia de ADR 0002" {

    It "<Cmdlet> conserva -Plan, -Apply y -AutoApprove" -ForEach @(
        @{ Cmdlet = 'Publish-NodeApi' }
        @{ Cmdlet = 'Publish-FlutterWeb' }
        @{ Cmdlet = 'Invoke-SqlPackage' }
    ) {
        $keys = (Get-Command $Cmdlet).Parameters.Keys
        $keys | Should -Contain 'Plan'
        $keys | Should -Contain 'Apply'
        $keys | Should -Contain 'AutoApprove'
    }
}

Describe "REQ-4: deploy.yaml deja de ser un fallback y pasa a fallar" {

    It "un proyecto con deploy.yaml y sin publish.yaml falla" {
        $root = New-FlutterProject -ConfigName 'deploy.yaml'
        Push-Location $root
        try {
            Get-ThrownMessage { Publish-FlutterWeb -Plan } | Should -Not -BeNullOrEmpty
        } finally { Pop-Location }
    }

    It "el mensaje nombra los dos archivos, para que se sepa qué renombrar" {
        $root = New-FlutterProject -ConfigName 'deploy.yaml'
        Push-Location $root
        try {
            $msg = Get-ThrownMessage { Publish-FlutterWeb -Plan }
            $msg | Should -Match 'deploy\.yaml'
            $msg | Should -Match 'publish\.yaml'
        } finally { Pop-Location }
    }
}

Describe "REQ-5: Publish-FlutterWebLegacy ya no existe" {

    # Cero usos en toda la organizacion, asi que se borra sin fase intermedia.
    It "no esta disponible como comando" {
        # Get-Command autocargaria el modulo publicado desde PSModulePath y lo encontraria ahi.
        # La pregunta es si lo exporta el modulo bajo prueba.
        (Get-Module 'macss-devops').ExportedCommands.Keys | Should -Not -Contain 'Publish-FlutterWebLegacy'
    }

    It "no figura en el manifiesto" {
        $m = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\macss-devops.psd1')
        $m.FunctionsToExport | Should -Not -Contain 'Publish-FlutterWebLegacy'
    }

    It "su archivo fuente fue eliminado" {
        Join-Path $PSScriptRoot '..\Functions\Publish-FlutterWebLegacy.ps1' | Should -Not -Exist
    }
}

Describe "REQ-6: no queda ningún aviso blando en el código" {

    # La única vía de deprecación es la excepción. Un Write-Host amarillo, como el que usaba
    # deploy.yaml, ni siquiera se captura con -WarningVariable ni aparece en un log de CI.
    It "<Area> no emite avisos de deprecación por Write-Warning o Write-Host" -ForEach @(
        @{ Area = 'Functions' }
        @{ Area = 'Private' }
    ) {
        $offenders = @(
            Get-ChildItem -Path (Join-Path $PSScriptRoot "..\$Area") -Filter *.ps1 -Recurse -File |
                Where-Object {
                    $src = Get-Content $_.FullName -Raw -Encoding UTF8
                    $src -match '(?im)^\s*Write-(Warning|Host).*(deprecad|deprecat)'
                } | ForEach-Object { $_.Name }
        )
        $offenders -join ', ' | Should -BeNullOrEmpty
    }
}
