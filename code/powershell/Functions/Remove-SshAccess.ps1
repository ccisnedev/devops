<#
.SYNOPSIS
Revokes an SSH key: removes its public key from a server's authorized_keys, and
optionally removes the local private key and ~/.ssh/config alias.

.DESCRIPTION
SSH keys have no native expiry; a key is valid while its public key sits in the
server's authorized_keys. This cmdlet removes the matching line (matched by base64
blob or by SHA256 fingerprint), with a backup, an atomic write, and a lockout guard
(it refuses to leave zero keys unless -Force).

Use it to retire a key or to complete a rotation (New-SshAccess for the new key,
verify, then Remove-SshAccess for the old one).

.PARAMETER Server
ssh config alias of the target. HostName/User/Port are resolved from ~/.ssh/config.
Alternatively pass -HostName and -User explicitly.

.PARAMETER HostName
Server IP/DNS (when not using -Server).

.PARAMETER User
Target account whose authorized_keys is edited (when not using -Server).

.PARAMETER Port
SSH port (default 22).

.PARAMETER PublicKey
Path to (or content of) the public key to revoke. Matched by its base64 blob.

.PARAMETER Fingerprint
SHA256 fingerprint of the key to revoke (e.g. SHA256:...). Alternative to -PublicKey.

.PARAMETER BootstrapUser
Account used to connect (defaults to the target user). Use your own account + -Sudo to
edit a service account's authorized_keys.

.PARAMETER Sudo
Edit the target user's authorized_keys via sudo. Implied when BootstrapUser differs.

.PARAMETER RemoveLocal
Also remove the local private/public key files and the ~/.ssh/config alias.

.PARAMETER Force
Allow removing the last remaining key (lockout override).

.EXAMPLE
Remove-SshAccess -HostName 192.168.10.18 -User deploy -PublicKey C:\old\publickey -BootstrapUser me -Sudo
#>
function Remove-SshAccess {
    [CmdletBinding()]
    param(
        [string]$Server,
        [string]$HostName,
        [string]$User,
        [int]$Port = 22,
        [string]$PublicKey,
        [string]$Fingerprint,
        [string]$BootstrapUser,
        [switch]$Sudo,
        [switch]$RemoveLocal,
        [switch]$Force
    )

    $ErrorActionPreference = 'Stop'
    . "$PSScriptRoot/../Private/SshHelpers.ps1"
    . "$PSScriptRoot/../Private/PublishHelpers.ps1"
    . "$PSScriptRoot/../Private/Read-SSHConfig.ps1"

    # Validate target.
    if (-not $Server -and -not ($HostName -and $User)) {
        throw "Specify -Server (an ssh config alias) or both -HostName and -User."
    }
    # Validate key identification.
    if (-not $PublicKey -and -not $Fingerprint) {
        throw "Specify the key to revoke with -PublicKey or -Fingerprint."
    }
    if ($PublicKey -and $Fingerprint) {
        throw "Use only one of -PublicKey or -Fingerprint."
    }

    # Resolve connection details.
    $keyPathLocal = $null
    if ($Server) {
        $cfg = Read-SSHConfig -HostAlias $Server
        if (-not $HostName) { $HostName = $cfg.HostName }
        if (-not $User)     { $User = $cfg.User }
        if ($cfg.Port)      { $Port = [int]$cfg.Port }
        $keyPathLocal = $cfg.IdentityFile
    }

    # Determine match mode/value.
    if ($PublicKey) {
        $pubContent = if (Test-Path $PublicKey) { (Get-Content $PublicKey -Raw).Trim() } else { $PublicKey.Trim() }
        $matchMode = 'blob'
        $matchValue = Get-SshPublicKeyBlob -PublicKey $pubContent
    } else {
        $matchMode = 'fingerprint'
        $matchValue = $Fingerprint
    }

    $bootstrap = if ($BootstrapUser) { $BootstrapUser } else { $User }
    $useSudo = ($Sudo -or ($bootstrap -ne $User))

    Write-Host ""
    Write-Host "  Remove-SshAccess - $User@$HostName (match: $matchMode)" -ForegroundColor Cyan

    $script = Get-BashScript -ScriptName 'Remove-AuthorizedKey.sh' -Placeholders @{
        '__TARGET_USER__' = $User
        '__MATCH_MODE__'  = $matchMode
        '__MATCH_VALUE__' = $matchValue
        '__USE_SUDO__'    = ($(if ($useSudo) { '1' } else { '0' }))
        '__FORCE__'       = ($(if ($Force) { '1' } else { '0' }))
    }
    Invoke-RemoteBash -ScriptContent $script -User $bootstrap -HostName $HostName -Port $Port -Tty:$useSudo -Prefix 'macss_revoke_'
    $rc = $LASTEXITCODE
    if ($rc -ne 0) { throw "Key revocation failed (exit $rc). Nothing was left in a partial state (backup kept on server)." }
    Write-Host "  Revoked on $HostName (backup kept as authorized_keys.bak.*)" -ForegroundColor Green

    # Optional local cleanup.
    if ($RemoveLocal) {
        $sshDir = Get-SshUserDir
        $configPath = Join-Path $sshDir 'config'
        if ($Server) {
            if (Remove-SshConfigHost -ConfigPath $configPath -Alias $Server) {
                Write-Host "  Removed Host '$Server' from ssh config" -ForegroundColor DarkGray
            }
        }
        $localKey = if ($keyPathLocal) { $keyPathLocal } elseif ($PublicKey -and (Test-Path $PublicKey)) { ($PublicKey -replace '\.pub$', '') } else { $null }
        if ($localKey -and (Test-Path $localKey)) {
            Remove-Item -LiteralPath $localKey, "$localKey.pub" -Force -ErrorAction SilentlyContinue
            Write-Host "  Removed local key files: $localKey(.pub)" -ForegroundColor DarkGray
        }
    }

    return [pscustomobject]@{
        HostName  = $HostName
        User      = $User
        MatchMode = $matchMode
        Revoked   = $true
    }
}
