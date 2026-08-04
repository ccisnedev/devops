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

    # ADR 0012: los alias se CONSERVAN en 6.0.0 aunque su uso ya lance. Sin el alias,
    # PowerShell responde "A parameter cannot be found that matches parameter name 'Publish'",
    # que no dice a que migrar. Se conservan para poder fallar bien; se retiran en 6.1.0.
    It "keeps -DeployReport declared so the failure can name -Plan" {
        $script:cmd.Parameters['Plan'].Aliases | Should -Contain 'DeployReport'
    }
    It "keeps -Publish declared so the failure can name -Apply" {
        $script:cmd.Parameters['Apply'].Aliases | Should -Contain 'Publish'
    }

    It "defaults to the Apply parameter set" {
        $script:cmd.DefaultParameterSet | Should -Be 'Apply'
    }
    It "places -AutoApprove in the Apply parameter set" {
        $script:cmd.Parameters['AutoApprove'].ParameterSets.Keys | Should -Contain 'Apply'
    }
}
