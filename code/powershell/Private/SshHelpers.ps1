# SshHelpers.ps1
# Shared helpers for New-SshAccess / Remove-SshAccess.
# Pure, testable logic (config blocks, key generation, permissions) plus a
# thin remote-exec wrapper. No business logic lives in the cmdlets that is not here.

# Cross-version Windows detection ($IsWindows is PS6+ only; psd1 targets 5.1+).
$script:OnWindows = ($env:OS -eq 'Windows_NT')

<#
.SYNOPSIS
Returns the absolute path to the current user's .ssh directory, creating it if missing.
#>
function Get-SshUserDir {
    [CmdletBinding()]
    param()
    $home = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    $dir = Join-Path $home '.ssh'
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        if (-not $script:OnWindows) { & chmod 700 $dir }
    }
    return $dir
}

<#
.SYNOPSIS
Builds an ~/.ssh/config Host block (pure string, no I/O).
#>
function New-SshConfigEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$User,
        [int]$Port = 22,
        [Parameter(Mandatory)][string]$IdentityFile
    )
    return @(
        "Host $Alias"
        "    HostName $HostName"
        "    User $User"
        "    Port $Port"
        "    IdentityFile $IdentityFile"
        "    IdentitiesOnly yes"
    ) -join "`n"
}

<#
.SYNOPSIS
Adds (or replaces, with -Force) a Host block in an ssh config file. Idempotent.
Returns an object with the action taken: created | appended | replaced.
#>
function Add-SshConfigHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$User,
        [int]$Port = 22,
        [Parameter(Mandatory)][string]$IdentityFile,
        [switch]$Force
    )
    $block = New-SshConfigEntry -Alias $Alias -HostName $HostName -User $User -Port $Port -IdentityFile $IdentityFile

    if (-not (Test-Path $ConfigPath)) {
        $dir = Split-Path -Parent $ConfigPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -Path $ConfigPath -Value ($block + "`n") -Encoding UTF8
        return [pscustomobject]@{ Action = 'created'; Alias = $Alias }
    }

    $content = Get-Content $ConfigPath -Raw
    $pattern = "(?ms)^Host[ \t]+$([regex]::Escape($Alias))[ \t]*\r?$.*?(?=^Host[ \t]|\z)"
    if ($content -match $pattern) {
        if (-not $Force) {
            throw "Host '$Alias' already exists in $ConfigPath. Use -Force to replace it."
        }
        $content = [regex]::Replace($content, $pattern, ($block + "`n"))
        Set-Content -Path $ConfigPath -Value $content -Encoding UTF8
        return [pscustomobject]@{ Action = 'replaced'; Alias = $Alias }
    }
    Add-Content -Path $ConfigPath -Value ("`n" + $block + "`n")
    return [pscustomobject]@{ Action = 'appended'; Alias = $Alias }
}

<#
.SYNOPSIS
Removes a Host block (by alias) from an ssh config file. Returns $true if removed.
#>
function Remove-SshConfigHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Alias
    )
    if (-not (Test-Path $ConfigPath)) { return $false }
    $content = Get-Content $ConfigPath -Raw
    $pattern = "(?ms)^Host[ \t]+$([regex]::Escape($Alias))[ \t]*\r?$.*?(?=^Host[ \t]|\z)"
    if ($content -notmatch $pattern) { return $false }
    $content = [regex]::Replace($content, $pattern, '')
    Set-Content -Path $ConfigPath -Value ($content.TrimEnd() + "`n") -Encoding UTF8
    return $true
}

<#
.SYNOPSIS
Restricts permissions on a private key file (chmod 600 on Linux, ACL reset on Windows).
OpenSSH refuses to use a private key with loose permissions.
#>
function Protect-SshPrivateKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ($script:OnWindows) {
        $me = "$env:USERNAME"
        & icacls $Path /inheritance:r *> $null
        & icacls $Path /grant:r "${me}:F" *> $null
    } else {
        & chmod 600 $Path
    }
}

<#
.SYNOPSIS
Generates an SSH key pair with ssh-keygen. Returns paths, public key and fingerprint.
Empty -Passphrase produces an unattended (deploy) key.
#>
function New-SshKeyPair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Type = 'ed25519',
        [string]$Comment = '',
        [string]$Passphrase = '',
        [switch]$Force
    )
    if (Test-Path $Path) {
        if (-not $Force) { throw "A key already exists at $Path. Use -Force to overwrite." }
        Remove-Item -LiteralPath $Path, "$Path.pub" -Force -ErrorAction SilentlyContinue
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $kgArgs = @('-t', $Type, '-f', $Path, '-C', $Comment, '-N', $Passphrase, '-q')
    & ssh-keygen @kgArgs
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed (exit $LASTEXITCODE)" }

    Protect-SshPrivateKey -Path $Path

    return [pscustomobject]@{
        PrivateKeyPath = $Path
        PublicKeyPath  = "$Path.pub"
        PublicKey      = (Get-Content "$Path.pub" -Raw).Trim()
        Fingerprint    = (Get-SshKeyFingerprint -PublicKeyPath "$Path.pub")
    }
}

<#
.SYNOPSIS
Returns the SHA256 fingerprint of a public key file.
#>
function Get-SshKeyFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PublicKeyPath)
    $line = & ssh-keygen -lf $PublicKeyPath
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen -lf failed for $PublicKeyPath" }
    return (($line -split '\s+')[1])
}

<#
.SYNOPSIS
Extracts the base64 blob (second field) of a public key line. Used to match keys
in a server's authorized_keys regardless of the trailing comment.
#>
function Get-SshPublicKeyBlob {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PublicKey)
    return (($PublicKey.Trim() -split '\s+')[1])
}

<#
.SYNOPSIS
Runs a bash script on a remote host over SSH. If -IdentityFile is given it is used
(-i); otherwise SSH falls back to its default auth (password/agent) - this is how
the first-time bootstrap install works before any key is authorized.
Returns the process exit code; remote stdout/stderr are written to the host.
#>
function Invoke-RemoteBash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptContent,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$HostName,
        [int]$Port = 22,
        [string]$IdentityFile,
        [switch]$Tty,
        [string]$Prefix = 'macss_ssh_'
    )
    # Normalize to LF and write a UTF-8 (no BOM) temp script.
    $unix = $ScriptContent -replace "`r`n", "`n" -replace "`r", "`n"
    $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), ("{0}{1}.sh" -f $Prefix, ([guid]::NewGuid().ToString())))
    [System.IO.File]::WriteAllText($tmp, $unix, (New-Object System.Text.UTF8Encoding($false)))

    $idArgs = @()
    if ($IdentityFile) { $idArgs = @('-i', $IdentityFile, '-o', 'IdentitiesOnly=yes') }
    $common = @('-o', 'StrictHostKeyChecking=accept-new', '-P', "$Port") + $idArgs

    $remote = "/tmp/" + [IO.Path]::GetFileName($tmp)
    try {
        & scp @common $tmp "$($User)@$($HostName):$remote"
        if ($LASTEXITCODE -ne 0) { throw "scp failed (exit $LASTEXITCODE)" }

        # ssh uses -p (lowercase) for port; rebuild without the scp-style -P.
        # -tt forces a pseudo-tty so an in-script `sudo` can prompt for its password
        # (a service-account install/revoke runs via sudo over a non-interactive ssh).
        $ttyArgs = @(); if ($Tty) { $ttyArgs = @('-tt') }
        $sshCommon = @('-o', 'StrictHostKeyChecking=accept-new', '-p', "$Port") + $ttyArgs + $idArgs
        & ssh @sshCommon "$($User)@$($HostName)" "bash $remote; rc=`$?; rm -f $remote; exit `$rc"
        return $LASTEXITCODE
    }
    finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}
