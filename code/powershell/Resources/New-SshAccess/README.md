# New-SshAccess / Remove-SshAccess

Cross-platform (Windows / Linux, under PowerShell) cmdlets to manage key-based SSH
access to a host. They replace the manual, error-prone "generate a key, copy it to the
server, edit ~/.ssh/config" dance and fill the gap left by the absence of `ssh-copy-id`
on Windows. The private key always stays in `~/.ssh` (never in a repo).

## New-SshAccess

Generates (or reuses) a key pair, installs the public key on the server, registers a
`~/.ssh/config` Host alias, and verifies the login.

```powershell
# Service account (you log in with your own account and install for svc-fotos via sudo):
New-SshAccess -Server fotos-vm -HostName 192.168.10.110 -User svc-fotos `
              -BootstrapUser '44358590@cacsi.local' -Sudo

# Plain account (you can already log in as that user):
New-SshAccess -Server my-host -HostName 10.0.0.5 -User deploy
```

Result: `ssh fotos-vm` logs in as the target user with the new key, and `fotos-vm` is
ready to use as the `server:` value in a `publish.yaml`.

Key parameters: `-Server` (config alias), `-HostName`, `-User` (target/owner),
`-BootstrapUser` (login used to install; defaults to `-User`), `-Sudo` (install into
another user's `authorized_keys`), `-KeyType` (default `ed25519`), `-KeyPath` (default
`~/.ssh/<Server>`; reused if it already exists), `-Force`.

## Remove-SshAccess (revoke)

SSH keys have no native expiry: a key is valid while its public key sits in the server's
`authorized_keys`. This cmdlet removes the matching line (by base64 blob or by SHA256
fingerprint), keeping a backup, writing atomically, and refusing to leave zero keys
(lockout guard) unless `-Force`.

```powershell
# Revoke a leaked/old key on a server (match by public key file):
Remove-SshAccess -HostName 192.168.10.18 -User deploy `
                 -PublicKey C:\path\to\old.pub -BootstrapUser me -Sudo

# Revoke by fingerprint and also clean the local key + config alias:
Remove-SshAccess -Server fotos-vm -Fingerprint SHA256:abc... -RemoveLocal
```

## Rotation

Rotation is the composition of both, per server that trusts the key:

1. `New-SshAccess ...` (new key) and confirm it verifies.
2. `Remove-SshAccess -PublicKey <old.pub> ...` to retire the old key.

Never revoke the key you are currently connecting with before the new one is verified.

## Notes

- For CI, the private key belongs in a secrets store (e.g. a GitHub Actions secret),
  never as a file committed to a repository.
- On Windows the cmdlet restricts the private key ACL (OpenSSH refuses keys with loose
  permissions); on Linux it sets `chmod 600`.
