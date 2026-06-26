<#
.SYNOPSIS
Provisions key-based SSH access to a host: generates (or reuses) a key pair, installs
the public key on the server, registers a Host alias in ~/.ssh/config, and verifies it.

.DESCRIPTION
One command to get `ssh <alias>` working against a server with a dedicated key.
Cross-platform (Windows / Linux under PowerShell). Fills the gap left by the absence
of `ssh-copy-id` on Windows and adds -TargetUser/-Sudo support for service accounts.

The private key never leaves ~/.ssh. The public key is appended (idempotently) to the
target user's authorized_keys; when the bootstrap login differs from the target user,
the install runs via sudo.

.PARAMETER Server
Alias to create in ~/.ssh/config (this is what later goes in publish.yaml as `server:`).

.PARAMETER HostName
IP or DNS name of the server.

.PARAMETER User
Account the alias logs in as and that will own the key on the server (e.g. svc-fotos).

.PARAMETER Port
SSH port (default 22).

.PARAMETER BootstrapUser
Account used to install the public key the first time (defaults to -User). Use this when
you cannot yet log in as -User (e.g. a no-login service account): connect as your own
account and install into the service account's authorized_keys with -Sudo.

.PARAMETER Sudo
Install into -User's authorized_keys via sudo. Implied when BootstrapUser differs from User.

.PARAMETER BootstrapIdentityFile
Private key used to authenticate the install connection (passed to ssh as -i, with
IdentitiesOnly). Use it to bootstrap WITHOUT ssh-agent - e.g. during a key rotation,
authenticate with the OLD key while installing the new one. When omitted, ssh uses its
default auth (agent/password).

.PARAMETER KeyType
Key algorithm (default ed25519).

.PARAMETER KeyPath
Path of the key. Defaults to ~/.ssh/<Server>. If the path already exists it is REUSED
(install/register an existing key); otherwise a new pair is generated.

.PARAMETER Comment
Public key comment (default "<User>@<Server>-<yyyyMMdd>").

.PARAMETER Force
Overwrite an existing key at -KeyPath and replace an existing Host alias.

.EXAMPLE
New-SshAccess -Server fotos-vm -HostName 192.168.10.110 -User svc-fotos -BootstrapUser '44358590@cacsi.local' -Sudo
#>
function New-SshAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$User,
        [int]$Port = 22,
        [string]$BootstrapUser,
        [string]$BootstrapIdentityFile,
        [switch]$Sudo,
        [string]$KeyType = 'ed25519',
        [string]$KeyPath,
        [string]$Comment,
        [switch]$Force
    )

    $ErrorActionPreference = 'Stop'
    . "$PSScriptRoot/../Private/SshHelpers.ps1"
    . "$PSScriptRoot/../Private/PublishHelpers.ps1"

    Write-Host ""
    Write-Host "  New-SshAccess - $Server ($User@$HostName)" -ForegroundColor Cyan

    $sshDir = Get-SshUserDir
    if (-not $KeyPath) { $KeyPath = Join-Path $sshDir $Server }
    if (-not $Comment) { $Comment = "$User@$Server-$(Get-Date -Format 'yyyyMMdd')" }

    # 1. Key pair: reuse if KeyPath exists, otherwise generate.
    if ((Test-Path $KeyPath) -and -not $Force) {
        if (-not (Test-Path "$KeyPath.pub")) {
            throw "Private key '$KeyPath' exists but '$KeyPath.pub' is missing. Provide the public key or use -Force to regenerate."
        }
        Write-Host "  Reusing existing key: $KeyPath" -ForegroundColor DarkGray
        $pub = (Get-Content "$KeyPath.pub" -Raw).Trim()
        $fingerprint = Get-SshKeyFingerprint -PublicKeyPath "$KeyPath.pub"
        Protect-SshPrivateKey -Path $KeyPath
    } else {
        Write-Host "  Generating key pair ($KeyType): $KeyPath" -ForegroundColor DarkGray
        $key = New-SshKeyPair -Path $KeyPath -Type $KeyType -Comment $Comment -Force:$Force
        $pub = $key.PublicKey
        $fingerprint = $key.Fingerprint
    }

    # 2. Install the public key on the server (bootstrap login; sudo if needed).
    $bootstrap = if ($BootstrapUser) { $BootstrapUser } else { $User }
    $useSudo = ($Sudo -or ($bootstrap -ne $User))
    Write-Host "  Installing public key for '$User' via '$bootstrap' (sudo=$useSudo)..." -ForegroundColor DarkGray
    if ($useSudo) { Write-Host "  You may be prompted for your password up to 3 times (scp, ssh, sudo)." -ForegroundColor Yellow }

    $installScript = Get-BashScript -ScriptName 'Install-AuthorizedKey.sh' -Placeholders @{
        '__TARGET_USER__' = $User
        '__PUBKEY__'      = $pub
        '__USE_SUDO__'    = ($(if ($useSudo) { '1' } else { '0' }))
    }
    Invoke-RemoteBash -ScriptContent $installScript -User $bootstrap -HostName $HostName -Port $Port -IdentityFile $BootstrapIdentityFile -Tty:$useSudo -Prefix 'macss_authkey_'
    $rc = $LASTEXITCODE
    if ($rc -ne 0) { throw "Public key install failed (exit $rc)." }

    # 3. Register the Host alias.
    $configPath = Join-Path $sshDir 'config'
    $cfg = Add-SshConfigHost -ConfigPath $configPath -Alias $Server -HostName $HostName -User $User -Port $Port -IdentityFile $KeyPath -Force:$Force
    Write-Host "  ssh config: $($cfg.Action) Host '$Server'" -ForegroundColor DarkGray

    # 4. Verify key-based login works.
    Write-Host "  Verifying key-based login..." -ForegroundColor DarkGray
    Invoke-RemoteBash -ScriptContent 'exit 0' -User $User -HostName $HostName -Port $Port -IdentityFile $KeyPath -Prefix 'macss_verify_'
    $vrc = $LASTEXITCODE
    if ($vrc -ne 0) {
        Write-Host "  WARNING: verification failed (exit $vrc). Key installed but login not confirmed." -ForegroundColor Yellow
    } else {
        Write-Host "  OK: ssh $Server  (login as $User)" -ForegroundColor Green
    }

    return [pscustomobject]@{
        Server      = $Server
        HostName    = $HostName
        User        = $User
        KeyPath     = $KeyPath
        Fingerprint = $fingerprint
        Verified    = ($vrc -eq 0)
    }
}
