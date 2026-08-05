# PublishFlutterWeb.Taxonomy.Tests.ps1
# ADR 0002: Publish-FlutterWeb exposes Init/Plan/Apply with -AutoApprove,
# keeps -DeployReport/-Publish as deprecated aliases.

BeforeAll {
    Import-Module "$PSScriptRoot/../macss-devops.psd1" -Force
    $script:cmd = Get-Command Publish-FlutterWeb
}

Describe "Publish-FlutterWeb taxonomy (ADR 0002)" {

    It "exposes -Init" { $script:cmd.Parameters.ContainsKey('Init') | Should -BeTrue }
    It "exposes -Plan" { $script:cmd.Parameters.ContainsKey('Plan') | Should -BeTrue }
    It "exposes -Apply" { $script:cmd.Parameters.ContainsKey('Apply') | Should -BeTrue }
    It "exposes -AutoApprove" { $script:cmd.Parameters.ContainsKey('AutoApprove') | Should -BeTrue }

    # ADR 0012: los alias se RETIRAN en 6.0.0. La busqueda de uso real encontro cuatro
    # llamadores --tres plantillas de organizacion y el workflow de retiro-- y se migraron a
    # -Apply -AutoApprove antes de tocar el modulo. Sin llamadores, conservarlos no explica
    # nada a nadie.
    It "no longer declares -DeployReport" {
        $script:cmd.Parameters['Plan'].Aliases | Should -Not -Contain 'DeployReport'
    }
    It "no longer declares -Publish" {
        $script:cmd.Parameters['Apply'].Aliases | Should -Not -Contain 'Publish'
    }

    It "defaults to the Apply parameter set" {
        $script:cmd.DefaultParameterSet | Should -Be 'Apply'
    }
    It "places -AutoApprove in the Apply parameter set" {
        $script:cmd.Parameters['AutoApprove'].ParameterSets.Keys | Should -Contain 'Apply'
    }
}
