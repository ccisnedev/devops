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

Describe "Test-CleanWorktree scoped to component (monorepo, REQ-7)" {

    BeforeAll {
        $script:mrepo = Join-Path ([IO.Path]::GetTempPath()) "mono-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $script:mrepo 'code/api') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:mrepo 'code/db')  -Force | Out-Null
        & git -C $script:mrepo init -q
        & git -C $script:mrepo config user.email "t@t.t"
        & git -C $script:mrepo config user.name "t"
        Set-Content -Path (Join-Path $script:mrepo 'code/api/server.js') -Value 'console.log(1)'
        Set-Content -Path (Join-Path $script:mrepo 'code/db/schema.sql') -Value 'SELECT 1'
        & git -C $script:mrepo add -A
        & git -C $script:mrepo commit -q -m "init monorepo"
        $script:apiDir = Join-Path $script:mrepo 'code/api'
    }

    AfterAll { Remove-Item -Recurse -Force -Path $script:mrepo -ErrorAction SilentlyContinue }

    It "REQ-7: true for a clean component subdir" {
        Test-CleanWorktree -Path $script:apiDir | Should -BeTrue
    }

    It "REQ-7: NOT blocked by an uncommitted change in ANOTHER component (code/db)" {
        Set-Content -Path (Join-Path $script:mrepo 'code/db/dirty.tmp') -Value 'x'
        try { Test-CleanWorktree -Path $script:apiDir | Should -BeTrue }
        finally { Remove-Item -Force (Join-Path $script:mrepo 'code/db/dirty.tmp') -ErrorAction SilentlyContinue }
    }

    It "REQ-7: false when the change is INSIDE the component subdir" {
        Set-Content -Path (Join-Path $script:apiDir 'dirty.tmp') -Value 'x'
        try { Test-CleanWorktree -Path $script:apiDir | Should -BeFalse }
        finally { Remove-Item -Force (Join-Path $script:apiDir 'dirty.tmp') -ErrorAction SilentlyContinue }
    }
}

Describe "Export-GitSubtreeTar (monorepo subdir packaging, REQ-8)" {

    BeforeAll {
        $script:xrepo = Join-Path ([IO.Path]::GetTempPath()) "xtar-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $script:xrepo 'code/api') -Force | Out-Null
        & git -C $script:xrepo init -q
        & git -C $script:xrepo config user.email "t@t.t"
        & git -C $script:xrepo config user.name "t"
        Set-Content -Path (Join-Path $script:xrepo 'code/api/server.js')    -Value 'console.log(1)'
        Set-Content -Path (Join-Path $script:xrepo 'code/api/package.json') -Value '{}'
        Set-Content -Path (Join-Path $script:xrepo 'README.md')             -Value 'root'
        & git -C $script:xrepo add -A
        & git -C $script:xrepo commit -q -m "init"
        $script:xapi = Join-Path $script:xrepo 'code/api'
    }

    AfterAll { Remove-Item -Recurse -Force -Path $script:xrepo -ErrorAction SilentlyContinue }

    It "REQ-8: packages a NON-EMPTY subtree tar (regression: cwd-relative treeish -> empty tar)" {
        $out = Join-Path ([IO.Path]::GetTempPath()) "sub-$([guid]::NewGuid().ToString('N').Substring(0,8)).tar"
        try {
            Export-GitSubtreeTar -Path $script:xapi -OutTar $out
            Test-Path $out | Should -BeTrue
            # el bug (treeish relativo al cwd en un subdir) producia un tar VACIO -> 0 entradas.
            # (No sirve chequear tamaño: tar rellena al blocking factor de 10240 bytes, asi que
            #  un tar vacio y uno con archivos chicos pesan igual.)
            Push-Location (Split-Path $out -Parent)
            try { $entries = @(& tar -tf (Split-Path $out -Leaf)) } finally { Pop-Location }
            $entries.Count | Should -BeGreaterThan 0
        } finally { Remove-Item -Force $out -ErrorAction SilentlyContinue }
    }

    It "REQ-8: places component files at the ROOT of the tar (excludes repo-root files)" {
        $out = Join-Path ([IO.Path]::GetTempPath()) "sub-$([guid]::NewGuid().ToString('N').Substring(0,8)).tar"
        try {
            Export-GitSubtreeTar -Path $script:xapi -OutTar $out
            # Push-Location + nombre relativo: evita que 'tar' interprete 'C:' como host remoto.
            Push-Location (Split-Path $out -Parent)
            try { $entries = & tar -tf (Split-Path $out -Leaf) } finally { Pop-Location }
            $entries | Should -Contain 'server.js'
            $entries | Should -Not -Contain 'README.md'
        } finally { Remove-Item -Force $out -ErrorAction SilentlyContinue }
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

Describe "Publish-NodeApi -AllowDirty parameter (ADR 0003)" {

    BeforeAll {
        Import-Module "$PSScriptRoot/../macss-devops.psd1" -Force
        $script:cmd = Get-Command Publish-NodeApi
    }

    It "exposes -AllowDirty" {
        $script:cmd.Parameters.ContainsKey('AllowDirty') | Should -BeTrue
    }

    It "places -AllowDirty in the Apply parameter set" {
        $script:cmd.Parameters['AllowDirty'].ParameterSets.Keys | Should -Contain 'Apply'
    }
}

Describe "Publish-NodeApi -Init scaffolds runtime by tsconfig presence (ADR 0003)" {

    BeforeAll {
        Import-Module "$PSScriptRoot/../macss-devops.psd1" -Force
    }

    BeforeEach {
        $script:proj = Join-Path ([IO.Path]::GetTempPath()) "initrt-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:proj -Force | Out-Null
        Set-Content -Path (Join-Path $script:proj 'package.json') -Value '{ "name": "demo", "version": "1.0.0" }'
        $script:prev = Get-Location
        Set-Location $script:proj
    }

    AfterEach {
        Set-Location $script:prev
        Remove-Item -Recurse -Force -Path $script:proj -ErrorAction SilentlyContinue
    }

    It "no tsconfig -> build:false + entrypoint server.js" {
        Publish-NodeApi -Init | Out-Null
        $yaml = Get-Content (Join-Path $script:proj 'publish.yaml') -Raw
        $yaml | Should -Match 'build:\s*false'
        $yaml | Should -Match 'entrypoint:\s*server\.js'
    }

    It "with tsconfig -> build:true + entrypoint dist/main.js" {
        Set-Content -Path (Join-Path $script:proj 'tsconfig.json') -Value '{}'
        Publish-NodeApi -Init | Out-Null
        $yaml = Get-Content (Join-Path $script:proj 'publish.yaml') -Raw
        $yaml | Should -Match 'build:\s*true'
        $yaml | Should -Match 'entrypoint:\s*dist/main\.js'
    }
}
