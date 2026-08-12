# PublishEnvSecret.Taxonomy.Tests.ps1
# ADR 0002: el cmdlet expone la taxonomía Plan/Apply con -AutoApprove, como el resto de la
# familia. No tiene -Init: no hay nada que andamiar — el env file ya existe o no hay qué publicar.

BeforeAll {
    Import-Module "$PSScriptRoot/../macss-devops.psd1" -Force
    $script:cmd = Get-Command Publish-EnvSecret
}

Describe "Publish-EnvSecret taxonomy (ADR 0002)" {

    It "se exporta desde el módulo" { $script:cmd | Should -Not -BeNullOrEmpty }

    It "expone -Plan"        { $script:cmd.Parameters.ContainsKey('Plan') | Should -BeTrue }
    It "expone -Apply"       { $script:cmd.Parameters.ContainsKey('Apply') | Should -BeTrue }
    It "expone -AutoApprove" { $script:cmd.Parameters.ContainsKey('AutoApprove') | Should -BeTrue }

    It "-AutoApprove vive en el set de Apply" {
        $script:cmd.Parameters['AutoApprove'].ParameterSets.Keys | Should -Contain 'Apply'
    }

    It "el set por defecto es Apply" {
        $script:cmd.DefaultParameterSet | Should -Be 'Apply'
    }

    It "expone -EnvFile, y por defecto es .env" {
        # Misma convención que la familia (ADR 0004): producción es explícita.
        $script:cmd.Parameters.ContainsKey('EnvFile') | Should -BeTrue
    }

    It "expone -Component restringido a db, api y app" {
        $validos = $script:cmd.Parameters['Component'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $validos.ValidValues | Should -Be @('db', 'api', 'app')
    }

    It "expone -Environment" { $script:cmd.Parameters.ContainsKey('Environment') | Should -BeTrue }
}

Describe "Publish-EnvSecret — lo que no debe hacer" {

    BeforeAll { $script:fuente = Get-Content "$PSScriptRoot/../Functions/Publish-EnvSecret.ps1" -Raw }

    It "no pasa el valor del secret por la línea de comandos" {
        # Dejaría el secreto visible para cualquiera que liste procesos en la máquina.
        $script:fuente | Should -Not -Match "gh secret set[^\n]*--body"
    }

    It "confirma antes de publicar (ADR 0002)" {
        $script:fuente | Should -Match 'Confirm-MacssChange'
    }

    It "usa el nombre de secret del componente" {
        $script:fuente | Should -Match 'Resolve-EnvSecretName'
    }
}
