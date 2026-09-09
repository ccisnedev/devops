# SshAccessPublicKeyFile.Tests.ps1
# New-SshAccess -PublicKeyFile: install SOMEONE ELSE's public key into the target user's
# authorized_keys. The private key stays on the colleague's machine, so the cmdlet must
# not generate a key, must not touch the operator's ~/.ssh/config and cannot verify the
# login. Motivating case: give a support technician `ssh prod` as a shared service
# account without moving private keys around.

# Evaluated at discovery time (BeforeAll runs later), so -Skip: can see it.
$script:HaveKeygen = $null -ne (Get-Command ssh-keygen -ErrorAction SilentlyContinue)

BeforeAll {
    Import-Module "$PSScriptRoot/../macss-devops.psd1" -Force
    . "$PSScriptRoot/../Private/SshHelpers.ps1"
}

Describe "New-SshAccess -PublicKeyFile (install a foreign .pub)" {

    It "exposes -PublicKeyFile as a string" {
        $p = (Get-Command New-SshAccess).Parameters
        $p.ContainsKey('PublicKeyFile') | Should -BeTrue
        $p['PublicKeyFile'].ParameterType | Should -Be ([string])
    }

    It "-PublicKeyFile lives in its own parameter set where -Server is NOT mandatory" {
        $cmd = Get-Command New-SshAccess
        $set = $cmd.ParameterSets | Where-Object { $_.Parameters.Name -contains 'PublicKeyFile' } | Select-Object -First 1
        $set | Should -Not -BeNullOrEmpty
        ($set.Parameters | Where-Object Name -eq 'PublicKeyFile').IsMandatory | Should -BeTrue
        ($set.Parameters | Where-Object Name -eq 'Server').IsMandatory | Should -BeFalse
    }

    It "the generate set (no -PublicKeyFile) keeps -Server mandatory" {
        $cmd = Get-Command New-SshAccess
        $set = $cmd.ParameterSets | Where-Object { $_.Parameters.Name -notcontains 'PublicKeyFile' } | Select-Object -First 1
        $set | Should -Not -BeNullOrEmpty
        ($set.Parameters | Where-Object Name -eq 'Server').IsMandatory | Should -BeTrue
    }

    It "does not accept -KeyPath, -KeyType, -Comment together with -PublicKeyFile" {
        $cmd = Get-Command New-SshAccess
        $set = $cmd.ParameterSets | Where-Object { $_.Parameters.Name -contains 'PublicKeyFile' } | Select-Object -First 1
        foreach ($p in 'KeyPath', 'KeyType', 'Comment') {
            $set.Parameters.Name | Should -Not -Contain $p
        }
    }
}

Describe "New-SshAccess -PublicKeyFile end-to-end (remote mocked)" -Skip:(-not $script:HaveKeygen) {

    BeforeAll {
        $script:key = Join-Path $TestDrive 'colleague'
        New-SshKeyPair -Path $script:key -Type ed25519 -Comment 'soporte@prod-mmeca-20260909' | Out-Null
        $script:pub = (Get-Content "$($script:key).pub" -Raw).Trim()

        Mock -ModuleName macss-devops Invoke-RemoteBash { $global:LASTEXITCODE = 0 }
        Mock -ModuleName macss-devops Add-SshConfigHost { throw "must not touch the operator's ssh config" }
        Mock -ModuleName macss-devops New-SshKeyPair { throw "must not generate a key" }
    }

    It "installs the received key via the bootstrap user with sudo, without generating a key or touching ~/.ssh/config" {
        $r = New-SshAccess -PublicKeyFile "$($script:key).pub" -Server prod -HostName 192.168.10.18 -User soporte `
                -BootstrapUser cacsiadmin -BootstrapIdentityFile 'C:\fake\prod' 6>$null

        Should -Invoke -ModuleName macss-devops Invoke-RemoteBash -Times 1 -Exactly -ParameterFilter {
            $User -eq 'cacsiadmin' -and $HostName -eq '192.168.10.18' -and $IdentityFile -eq 'C:\fake\prod' -and
            $Tty -eq $true -and
            $ScriptContent -match 'TARGET_USER="soporte"' -and
            $ScriptContent -match 'USE_SUDO="1"' -and
            $ScriptContent.Contains($script:pub)
        }
        Should -Invoke -ModuleName macss-devops Add-SshConfigHost -Times 0
        Should -Invoke -ModuleName macss-devops New-SshKeyPair -Times 0

        $r.User        | Should -Be 'soporte'
        $r.Server      | Should -Be 'prod'
        $r.Verified    | Should -BeFalse
        $r.KeyPath     | Should -BeNullOrEmpty
        $r.Comment     | Should -Be 'soporte@prod-mmeca-20260909'
        $r.Fingerprint | Should -Match '^SHA256:'
        $r.ConfigBlock | Should -Match '(?m)^Host prod$'
        $r.ConfigBlock | Should -Match '(?m)^    User soporte$'
        $r.ConfigBlock | Should -Match '(?m)^    IdentityFile ~/.ssh/prod$'
    }

    It "defaults the printed alias to -HostName when -Server is omitted" {
        $r = New-SshAccess -PublicKeyFile "$($script:key).pub" -HostName 192.168.10.18 -User soporte -BootstrapUser cacsiadmin 6>$null
        $r.Server | Should -Be '192.168.10.18'
    }

    It "fails when the remote install fails" {
        Mock -ModuleName macss-devops Invoke-RemoteBash { $global:LASTEXITCODE = 1 }
        { New-SshAccess -PublicKeyFile "$($script:key).pub" -HostName 192.168.10.18 -User soporte -BootstrapUser cacsiadmin 6>$null } |
            Should -Throw '*install failed*'
    }

    It "refuses a private key file before contacting the server" {
        { New-SshAccess -PublicKeyFile $script:key -HostName 192.168.10.18 -User soporte -BootstrapUser cacsiadmin 6>$null } |
            Should -Throw '*PRIVATE*'
        Should -Invoke -ModuleName macss-devops Invoke-RemoteBash -Times 0 -Exactly -ParameterFilter { $ScriptContent -match 'PRIVATE' }
    }
}

Describe "Read-SshPublicKeyFile (validation of the received .pub)" {

    It "rejects a missing file" {
        { Read-SshPublicKeyFile -Path (Join-Path $TestDrive 'nope.pub') } | Should -Throw '*not found*'
    }

    It "rejects a PRIVATE key (the colleague sent the wrong file)" {
        $f = Join-Path $TestDrive 'oops'
        Set-Content -Path $f -Value "-----BEGIN OPENSSH PRIVATE KEY-----`nb3BlbnNzaC1rZXktdjEAAAAA`n-----END OPENSSH PRIVATE KEY-----"
        { Read-SshPublicKeyFile -Path $f } | Should -Throw '*PRIVATE*'
    }

    It "rejects a file that is not an OpenSSH public key" {
        $f = Join-Path $TestDrive 'garbage.pub'
        Set-Content -Path $f -Value 'hola mundo'
        { Read-SshPublicKeyFile -Path $f } | Should -Throw '*does not look like*'
    }

    It "rejects a file with more than one key line" {
        $f = Join-Path $TestDrive 'two.pub'
        Set-Content -Path $f -Value "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA a`nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA b"
        { Read-SshPublicKeyFile -Path $f } | Should -Throw '*exactly one*'
    }

    It "returns type, blob, comment and SHA256 fingerprint for a real ed25519 .pub" -Skip:(-not $script:HaveKeygen) {
        $key = Join-Path $TestDrive 'mmeca'
        $comment = 'soporte@prod-mmeca-20260909'
        New-SshKeyPair -Path $key -Type ed25519 -Comment $comment | Out-Null
        $r = Read-SshPublicKeyFile -Path "$key.pub"
        $r.Type        | Should -Be 'ssh-ed25519'
        $r.Blob        | Should -Match '^AAAA'
        $r.Comment     | Should -Be $comment
        $r.Fingerprint | Should -Match '^SHA256:'
        $r.PublicKey   | Should -Be ((Get-Content "$key.pub" -Raw).Trim())
    }

    It "tolerates a trailing newline / CRLF (file sent from Windows)" -Skip:(-not $script:HaveKeygen) {
        $key = Join-Path $TestDrive 'crlf'
        New-SshKeyPair -Path $key -Type ed25519 -Comment 'x' | Out-Null
        $crlf = Join-Path $TestDrive 'crlf-copy.pub'
        [IO.File]::WriteAllText($crlf, ((Get-Content "$key.pub" -Raw).Trim() + "`r`n`r`n"))
        (Read-SshPublicKeyFile -Path $crlf).Blob | Should -Be (Read-SshPublicKeyFile -Path "$key.pub").Blob
    }
}
