# SshAccessBootstrapKey.Tests.ps1
# New-SshAccess and Remove-SshAccess accept -BootstrapIdentityFile to authenticate the
# install/revoke with an explicit key (e.g. the OLD key during a rotation), without
# depending on ssh-agent. The remote step (Invoke-RemoteBash) already supports -IdentityFile.

BeforeAll {
    Import-Module "$PSScriptRoot/../macss-devops.psd1" -Force
}

Describe "Explicit bootstrap key (-BootstrapIdentityFile)" {

    It "New-SshAccess exposes -BootstrapIdentityFile" {
        (Get-Command New-SshAccess).Parameters.ContainsKey('BootstrapIdentityFile') | Should -BeTrue
    }

    It "New-SshAccess -BootstrapIdentityFile is a string" {
        (Get-Command New-SshAccess).Parameters['BootstrapIdentityFile'].ParameterType | Should -Be ([string])
    }

    It "Remove-SshAccess exposes -BootstrapIdentityFile" {
        (Get-Command Remove-SshAccess).Parameters.ContainsKey('BootstrapIdentityFile') | Should -BeTrue
    }

    It "Remove-SshAccess -BootstrapIdentityFile is a string" {
        (Get-Command Remove-SshAccess).Parameters['BootstrapIdentityFile'].ParameterType | Should -Be ([string])
    }
}
