# SshKeyPairPassphrase.Tests.ps1
# Regression guard: New-SshKeyPair with an empty passphrase must produce a passphrase-less
# key WITHOUT prompting. On Windows PowerShell 5.1 the empty `-N ''` was dropped and
# ssh-keygen prompted (and could hang); the cmd.exe route fixes it. PS7 already worked.

BeforeAll {
    . "$PSScriptRoot/../Private/SshHelpers.ps1"
}

Describe "New-SshKeyPair (empty passphrase)" {

    It "creates an unattended (passphrase-less) key without prompting" {
        $p = Join-Path ([IO.Path]::GetTempPath()) ("kgtest_" + [guid]::NewGuid().ToString('N').Substring(0,8))
        try {
            $r = New-SshKeyPair -Path $p -Comment 'test@unit'
            Test-Path $r.PrivateKeyPath | Should -BeTrue
            Test-Path $r.PublicKeyPath  | Should -BeTrue
            # The key must have NO passphrase: ssh-keygen -y -P '' succeeds only on a passphrase-less key.
            & ssh-keygen -y -P '' -f $p *> $null
            $LASTEXITCODE | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $p, "$p.pub" -Force -ErrorAction SilentlyContinue
        }
    }

    It "generates an ed25519 key by default" {
        $p = Join-Path ([IO.Path]::GetTempPath()) ("kgtest_" + [guid]::NewGuid().ToString('N').Substring(0,8))
        try {
            New-SshKeyPair -Path $p -Comment 'test@unit' | Out-Null
            (Get-Content "$p.pub" -Raw) | Should -Match 'ssh-ed25519'
        } finally {
            Remove-Item -LiteralPath $p, "$p.pub" -Force -ErrorAction SilentlyContinue
        }
    }
}
