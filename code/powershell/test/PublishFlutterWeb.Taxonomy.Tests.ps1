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

    It "keeps -DeployReport as a deprecated alias of -Plan" {
        $script:cmd.Parameters['Plan'].Aliases | Should -Contain 'DeployReport'
    }
    It "keeps -Publish as a deprecated alias of -Apply" {
        $script:cmd.Parameters['Apply'].Aliases | Should -Contain 'Publish'
    }

    It "defaults to the Apply parameter set" {
        $script:cmd.DefaultParameterSet | Should -Be 'Apply'
    }
    It "places -AutoApprove in the Apply parameter set" {
        $script:cmd.Parameters['AutoApprove'].ParameterSets.Keys | Should -Contain 'Apply'
    }
}
