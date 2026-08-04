# DeprecationPolicy.Tests.ps1
# Tests de la política de deprecación del módulo (ADR 0012).
#
# Una deprecación falla con instrucciones; no avisa y continúa. La evidencia de que el aviso no
# funciona estaba en la propia suite: el warning de `-Publish`/`-DeployReport`, deprecados desde
# ADR 0002, se imprimía decenas de veces al correr los tests. Un mensaje que aparece siempre deja
# de leerse.
#
# Detalle contraintuitivo que estos tests fijan: los alias de parámetro `-Publish`/`-DeployReport`
# **se conservan** en 6.0.0. Borrarlos haría que PowerShell responda "A parameter cannot be found",
# que no dice qué usar en su lugar. Se conservan precisamente para poder fallar bien, y se retiran
# en 6.1.0.
#
# Cubre REQ-1 a REQ-6 de ADR 0012.

BeforeAll {
    Remove-Module 'macss-devops' -ErrorAction SilentlyContinue
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

Describe "REQ-3: los alias se conservan en 6.0.0 para que el fallo sea instructivo" {

    # Sin el alias, PowerShell responde "A parameter cannot be found that matches parameter name
    # 'Publish'", que no dice que hay que usar -Apply. El alias sobrevive hasta 6.1.0.
    It "<Cmdlet> conserva -DeployReport como alias de -Plan" -ForEach @(
        @{ Cmdlet = 'Publish-NodeApi' }
        @{ Cmdlet = 'Publish-FlutterWeb' }
        @{ Cmdlet = 'Invoke-SqlPackage' }
    ) {
        (Get-Command $Cmdlet).Parameters['Plan'].Aliases | Should -Contain 'DeployReport'
    }

    It "<Cmdlet> conserva -Publish como alias de -Apply" -ForEach @(
        @{ Cmdlet = 'Publish-NodeApi' }
        @{ Cmdlet = 'Publish-FlutterWeb' }
        @{ Cmdlet = 'Invoke-SqlPackage' }
    ) {
        (Get-Command $Cmdlet).Parameters['Apply'].Aliases | Should -Contain 'Publish'
    }
}

Describe "REQ-2: -Publish y -DeployReport lanzan en lugar de avisar" {

    It "Publish-FlutterWeb -Publish falla nombrando -Apply" {
        $root = New-FlutterProject
        Push-Location $root
        try {
            $msg = Get-ThrownMessage { Publish-FlutterWeb -Publish -AutoApprove }
            $msg | Should -Match '\-Apply'
        } finally { Pop-Location }
    }

    It "Publish-FlutterWeb -DeployReport falla nombrando -Plan" {
        $root = New-FlutterProject
        Push-Location $root
        try {
            $msg = Get-ThrownMessage { Publish-FlutterWeb -DeployReport }
            $msg | Should -Match '\-Plan'
        } finally { Pop-Location }
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

Describe "REQ-5: Publish-FlutterWebLegacy lanza al invocarse" {

    # En 6.0.0 la función existe únicamente para fallar con instrucciones. Se borra en 6.1.0.
    It "falla nombrando Publish-FlutterWeb" {
        $msg = Get-ThrownMessage { Publish-FlutterWebLegacy -server 'alias-inexistente-xyz' }
        $msg | Should -Match 'Publish-FlutterWeb'
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
