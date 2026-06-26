# InvokeSqlPackage.Taxonomy.Tests.ps1
# ADR 0002: Invoke-SqlPackage exposes Plan/Apply with -AutoApprove, keeps
# -DeployReport/-Publish as deprecated aliases. -AutoApprove also guards -Import.

BeforeAll {
    Import-Module "$PSScriptRoot/../macss-devops.psd1" -Force
    $script:cmd = Get-Command Invoke-SqlPackage
}

Describe "Invoke-SqlPackage taxonomy (ADR 0002)" {

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
    It "guards both -Apply and -Import with -AutoApprove" {
        $sets = $script:cmd.Parameters['AutoApprove'].ParameterSets.Keys
        $sets | Should -Contain 'Apply'
        $sets | Should -Contain 'Import'
    }
}
