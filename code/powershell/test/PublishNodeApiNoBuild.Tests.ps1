# PublishNodeApiNoBuild.Tests.ps1
# ADR 0003: Publish-NodeApi no-build runtime.
# Unit specs for the helpers that back build:false (REQ-1..REQ-6).

BeforeAll {
    . "$PSScriptRoot/../Private/PublishHelpers.ps1"
}

Describe "Resolve-NodeRuntime (REQ-1..3)" {

    It "REQ-1: defaults to build=true, entrypoint=dist/main.js when runtime is absent" {
        $r = Resolve-NodeRuntime -PublishConfig @{ server = 'prod' }
        $r.Build | Should -BeTrue
        $r.Entrypoint | Should -Be 'dist/main.js'
    }

    It "REQ-1: defaults to build=true when runtime exists but build is unset" {
        $r = Resolve-NodeRuntime -PublishConfig @{ runtime = @{ processManager = 'pm2' } }
        $r.Build | Should -BeTrue
        $r.Entrypoint | Should -Be 'dist/main.js'
    }

    It "REQ-2: build=false yields entrypoint=server.js by default" {
        $r = Resolve-NodeRuntime -PublishConfig @{ runtime = @{ build = $false } }
        $r.Build | Should -BeFalse
        $r.Entrypoint | Should -Be 'server.js'
    }

    It "REQ-3: explicit entrypoint overrides the default in build:false" {
        $r = Resolve-NodeRuntime -PublishConfig @{ runtime = @{ build = $false; entrypoint = 'src/index.js' } }
        $r.Build | Should -BeFalse
        $r.Entrypoint | Should -Be 'src/index.js'
    }

    It "REQ-3: explicit entrypoint overrides the default in build:true" {
        $r = Resolve-NodeRuntime -PublishConfig @{ runtime = @{ build = $true; entrypoint = 'dist/server.js' } }
        $r.Build | Should -BeTrue
        $r.Entrypoint | Should -Be 'dist/server.js'
    }

    It "REQ-3: normalizes a leading ./ in the entrypoint" {
        $r = Resolve-NodeRuntime -PublishConfig @{ runtime = @{ build = $false; entrypoint = './server.js' } }
        $r.Entrypoint | Should -Be 'server.js'
    }
}

Describe "Get-ReleaseId (REQ-4)" {

    It "REQ-4: composes v{version}+{shortSha}" {
        Get-ReleaseId -Version '1.0.0' -ShortSha 'abc1234' | Should -Be 'v1.0.0+abc1234'
    }

    It "REQ-4: strips build metadata already present in the version" {
        Get-ReleaseId -Version '1.0.0+local' -ShortSha 'abc1234' | Should -Be 'v1.0.0+abc1234'
    }
}

Describe "Test-CleanWorktree (REQ-5)" {

    BeforeAll {
        $script:repo = Join-Path ([IO.Path]::GetTempPath()) "cleanwt-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:repo -Force | Out-Null
        & git -C $script:repo init -q
        & git -C $script:repo config user.email "t@t.t"
        & git -C $script:repo config user.name "t"
        Set-Content -Path (Join-Path $script:repo 'a.txt') -Value 'hello'
        & git -C $script:repo add -A
        & git -C $script:repo commit -q -m "init"
    }

    AfterAll {
        Remove-Item -Recurse -Force -Path $script:repo -ErrorAction SilentlyContinue
    }

    It "REQ-5: true for a clean worktree" {
        Test-CleanWorktree -Path $script:repo | Should -BeTrue
    }

    It "REQ-5: false when a tracked file is modified" {
        Set-Content -Path (Join-Path $script:repo 'a.txt') -Value 'changed'
        Test-CleanWorktree -Path $script:repo | Should -BeFalse
    }
}

Describe "Get-ProdModulesPlan (REQ-6)" {

    It "REQ-6: selects wsl on a Windows host" {
        Get-ProdModulesPlan -IsWindowsHost $true | Should -Be 'wsl'
    }

    It "REQ-6: selects native on a non-Windows host" {
        Get-ProdModulesPlan -IsWindowsHost $false | Should -Be 'native'
    }
}
