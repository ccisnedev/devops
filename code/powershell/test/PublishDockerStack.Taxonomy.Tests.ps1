# PublishDockerStack.Taxonomy.Tests.ps1
# ADR 0002: Publish-DockerStack expone la taxonomía Init/Plan/Apply con -AutoApprove,
# igual que Publish-NodeApi. Al ser un cmdlet nuevo no arrastra alias deprecados.

BeforeAll {
    Import-Module "$PSScriptRoot/../macss-devops.psd1" -Force
    $script:cmd = Get-Command Publish-DockerStack
}

Describe "Publish-DockerStack taxonomy (ADR 0002)" {

    It "exposes -Init"        { $script:cmd.Parameters.ContainsKey('Init') | Should -BeTrue }
    It "exposes -Plan"        { $script:cmd.Parameters.ContainsKey('Plan') | Should -BeTrue }
    It "exposes -Apply"       { $script:cmd.Parameters.ContainsKey('Apply') | Should -BeTrue }
    It "exposes -AutoApprove" { $script:cmd.Parameters.ContainsKey('AutoApprove') | Should -BeTrue }
    It "exposes -AllowDirty"  { $script:cmd.Parameters.ContainsKey('AllowDirty') | Should -BeTrue }

    It "defaults to the Apply parameter set" {
        $script:cmd.DefaultParameterSet | Should -Be 'Apply'
    }
    It "places -AutoApprove in the Apply parameter set" {
        $script:cmd.Parameters['AutoApprove'].ParameterSets.Keys | Should -Contain 'Apply'
    }
    It "is exported by the module manifest" {
        (Get-Module macss-devops).ExportedFunctions.Keys | Should -Contain 'Publish-DockerStack'
    }
}

Describe "Get-DockerStackConfig validation" {

    BeforeAll {
        # Cargar los helpers privados directamente (convención del repo para funciones no exportadas).
        Import-Module powershell-yaml -ErrorAction SilentlyContinue
        . "$PSScriptRoot/../Private/PublishHelpers.ps1"
        . "$PSScriptRoot/../Private/DockerStackHelpers.ps1"
        $script:root = Join-Path ([IO.Path]::GetTempPath()) ("dockstack_" + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $script:root | Out-Null
    }
    AfterAll {
        Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "throws when stack.yaml is missing" {
        { Get-DockerStackConfig -ProjectRoot $script:root } | Should -Throw "*stack.yaml*"
    }

    It "throws when server is still the placeholder" {
        Set-Content -Path (Join-Path $script:root 'stack.yaml') -Value "server: your-ssh-alias`nstack:`n  name: x`n"
        Set-Content -Path (Join-Path $script:root '.env') -Value "X=1`n"
        { Get-DockerStackConfig -ProjectRoot $script:root } | Should -Throw "*your-ssh-alias*"
    }

    It "parses a valid config and defaults build to server" {
        Set-Content -Path (Join-Path $script:root 'stack.yaml') -Value "server: pre-prod`nstack:`n  name: iam`n  composeFile: docker-compose.yml`n"
        $cfg = Get-DockerStackConfig -ProjectRoot $script:root
        $cfg.Name  | Should -Be 'iam'
        $cfg.Build | Should -Be 'server'
    }

    It "requires image when build is transfer" {
        Set-Content -Path (Join-Path $script:root 'stack.yaml') -Value "server: pre-prod`nstack:`n  name: iam`n  build: transfer`n"
        { Get-DockerStackConfig -ProjectRoot $script:root } | Should -Throw "*transfer*"
    }
}
