# PublishNodeApi.Taxonomy.Tests.ps1
# ADR 0002: Publish-NodeApi exposes the Init/Plan/Apply taxonomy with -AutoApprove,
# and keeps -DeployReport/-Publish as deprecated aliases.

BeforeAll {
    Import-Module "$PSScriptRoot/../macss-devops.psd1" -Force
    $script:cmd = Get-Command Publish-NodeApi
}

Describe "Publish-NodeApi taxonomy (ADR 0002)" {

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

Describe "Publish-NodeApi -PushShared (provisión de sharedPaths, reemplazo limpio)" {

    It "exposes -PushShared" { $script:cmd.Parameters.ContainsKey('PushShared') | Should -BeTrue }

    It "-PushShared is a switch" { $script:cmd.Parameters['PushShared'].SwitchParameter | Should -BeTrue }

    It "places -PushShared in its own parameter set" {
        $script:cmd.Parameters['PushShared'].ParameterSets.Keys | Should -Contain 'PushShared'
    }

    It "does NOT introduce a -Force switch (reemplazo limpio es el default)" {
        $script:cmd.Parameters.ContainsKey('Force') | Should -BeFalse
    }

    It "makes -EnvFile available to the PushShared set" {
        $script:cmd.Parameters['EnvFile'].ParameterSets.Keys | Should -Contain 'PushShared'
    }

    It "reuses -AutoApprove in the PushShared set" {
        $script:cmd.Parameters['AutoApprove'].ParameterSets.Keys | Should -Contain 'PushShared'
    }
}

Describe "Publish-NodeApi body hygiene — no local var collides with a [switch] param" {
    # Regressione: $plan (variable local) colisionaba con el parámetro [switch]$Plan.
    # PowerShell es case-insensitive, así que `$plan = 'wsl'` intentaba asignar un String
    # a la variable-parámetro [switch]$Plan → "Cannot convert String to SwitchParameter".
    # Este guard estático detecta cualquier reincidencia sobre CUALQUIER switch del cmdlet.
    BeforeAll {
        $fnPath = "$PSScriptRoot/../Functions/Publish-NodeApi.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($fnPath, [ref]$null, [ref]$null)
        $fnAst = $ast.Find({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Publish-NodeApi'
            }, $true)

        $script:switchParams = @(
            $fnAst.Body.ParamBlock.Parameters |
                Where-Object { $_.StaticType -eq [System.Management.Automation.SwitchParameter] } |
                ForEach-Object { $_.Name.VariablePath.UserPath }
        )

        $assignments = $fnAst.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst]
            }, $true)
        $script:assignedNames = @(
            $assignments |
                ForEach-Object { $_.Left } |
                Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] } |
                ForEach-Object { $_.VariablePath.UserPath }
        )
    }

    It "detecta los parámetros [switch] del cmdlet" {
        $script:switchParams | Should -Contain 'Plan'
        $script:switchParams | Should -Contain 'Apply'
    }

    It "no asigna ninguna variable local cuyo nombre coincida con un parámetro [switch] (case-insensitive)" {
        $collisions = @(
            $script:assignedNames | Where-Object {
                $name = $_
                @($script:switchParams | Where-Object { $_ -ieq $name }).Count -gt 0
            } | Select-Object -Unique
        )
        $collisions | Should -BeNullOrEmpty -Because "asignar a una variable con el mismo nombre que un [switch] lanza 'Cannot convert String to SwitchParameter' (p.ej. `$plan` vs [switch]`$Plan)"
    }
}
