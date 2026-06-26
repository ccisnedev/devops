# Changelog
All notable changes to this project will be documented in this file.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## [5.0.0] - 2026-06-25

### Changed
- **BREAKING — deployment cmdlet taxonomy (ADR 0002):** `Publish-NodeApi`, `Invoke-SqlPackage` and `Publish-FlutterWeb` now share a consistent `-Init` / `-Plan` / `-Apply` vocabulary (Terraform-like plan/apply). `-Apply` (was `-Publish`) renders the plan and asks for confirmation before applying; `-Plan` (was `-DeployReport`) is the dry-run. The old `-Publish` / `-DeployReport` names are kept as **deprecated aliases** (emit a warning) and will be removed in a future major.
- **BREAKING — confirmation by default:** `-Apply` (and `Invoke-SqlPackage -Import`) now require confirmation. Unattended/CI callers must pass **`-AutoApprove`** (a conscious opt-in for non-interactive use). In a non-interactive shell without `-AutoApprove`, the cmdlet **fails with a clear, actionable error** instead of hanging on `Read-Host` (the previous `Invoke-SqlPackage` behavior) or applying silently (the previous `Publish-NodeApi` behavior). Implemented once in the shared `Confirm-MacssChange` helper; covered by Pester and a real non-interactive **container** behavioral test. See [ADR 0002](docs/adr/0002-publish-lifecycle-taxonomy.md).
- **Migration:** rename `-Publish`→`-Apply` and `-DeployReport`→`-Plan` (the aliases still work for now), and add `-AutoApprove` to any scripted/CI deploys.

## [4.0.0] - 2026-06-23

### Changed
- **BREAKING (Publish-NodeApi):** file installation no longer uses `sudo` by default. The rootless model is now the default — the deploy user is expected to own `REMOTE_ROOT/<name>` (e.g. a service account such as `svc-fotos` owning `/opt/app/<name>`), so no elevation is needed. To deploy into a directory the user does not own, opt in explicitly with `runtime.useSudo: true` in `publish.yaml`. `Install-NodeApi.sh` skips the `chown` in rootless mode (files are already owned by the deploy user). **Migration:** deployments that relied on the previous implicit `sudo` must add `useSudo: true`.

## [3.3.3] - 2026-06-23

### Fixed
- Windows PowerShell 5.1 compatibility (the manifest declares `PowerShellVersion = '5.1'`, but the module failed to parse there). Replaced the PS7-only null-coalescing operator (`??`) in `Read-SSHConfig` with a 5.1-compatible expression, and re-saved all `.ps1` files as UTF-8 **with BOM** so 5.1 reads non-ASCII characters (accents, em-dashes) correctly instead of producing string-terminator parse errors. Verified by importing the module under Windows PowerShell 5.1.

## [3.3.2] - 2026-06-23

### Fixed
- New-SshAccess / Remove-SshAccess: the remote exit code is now read from `$LASTEXITCODE` instead of capturing `Invoke-RemoteBash`'s pipeline output, which previously mixed remote stdout into the exit value and could turn a success into a spurious failure (or a garbled error message). Added milestone logging (`[scp]` / `[ssh]`) and a notice that the service-account bootstrap (`-Sudo`) may prompt for the password up to three times (scp, ssh, sudo); the remote `sudo` prompt now renders live. Validated end-to-end by dogfooding `svc-fotos` provisioning on a real VM.

## [3.3.1] - 2026-06-22

### Fixed
- New-SshAccess / Remove-SshAccess: the service-account path (`-Sudo`) now allocates a pseudo-tty (`ssh -tt`) so the remote `sudo` can prompt for its password over an otherwise non-interactive SSH session. Without it the install/revoke failed with "sudo: no tty present". `Invoke-RemoteBash` gained a `-Tty` switch.

## [3.3.0] - 2026-06-22

### Added
- New-SshAccess / Remove-SshAccess: cross-platform (Windows/Linux) cmdlets to manage key-based SSH access. `New-SshAccess` generates (or reuses, via `-KeyPath`) a key pair, installs the public key into the target's `authorized_keys` (with `-BootstrapUser`/`-Sudo` for service accounts), registers a `~/.ssh/config` Host alias, and verifies login. `Remove-SshAccess` revokes a key by base64 blob (`-PublicKey`) or SHA256 fingerprint (`-Fingerprint`), with backup, atomic write and a lockout guard; `-RemoveLocal` also cleans the local key and config alias. Fills the gap left by the absence of `ssh-copy-id` on Windows.

## [3.2.0] - 2026-06-22

### Added
- Publish-NodeApi: optional `ecosystem.config.js` support for the pm2 process manager. When the project root contains an `ecosystem.config.js`, it is packaged into the release and the pm2 path deploys it with `pm2 startOrReload <file> --update-env` followed by `pm2 save` (declarative, config-as-code, supports multiple processes). When the file is absent, the previous single-process behavior (`pm2 start dist/main.js --name <name>`) is preserved. Backward compatible.

## [3.1.1] - 2026-06-13

### Added
- Invoke-SqlPackage: SqlCmd variables from `.env`. Any variable prefixed `SQLVAR_` is passed to SqlPackage as `/v:<name>=<value>` for Publish/DeployReport/Script (e.g. `SQLVAR_FotosApiLoginPassword` -> `/v:FotosApiLoginPassword=...`). Enables injecting secrets (such as login passwords declared in the dacpac model) at deploy time without committing them to the repo. Backward compatible: projects without `SQLVAR_*` variables are unaffected.

## [3.1.0] - 2026-06-11

### Added
- Publish-NodeApi: the healthcheck now respects the API basePath. Resolution precedence: `"modularApi": { "basePath": "..." }` in package.json (modular_api ecosystem convention, single source of truth) > `api.basePath` in publish.yaml (explicit override) > root (`/health`, backward compatible). The banner and DeployReport show the resolved BasePath.
- New shared helpers in PublishHelpers: `Format-ApiBasePath`, `Resolve-ApiBasePath`, and `Resolve-PublishConfigPath`, with Pester coverage (PublishConfigHelpers.Tests.ps1).

### Changed
- Renamed the deployment config file from `deploy.yaml` to `publish.yaml` for coherence with the Publish-* cmdlets. `-Init` now generates `publish.yaml`; `Publish-NodeApi`, `Publish-FlutterWeb`, `Get-RepoInfo`, `Test-RepoHealth`, and `New-DeployWorkflow` accept the legacy `deploy.yaml` name with a deprecation notice.

## [3.0.0] - 2026-05-19

### Changed
- Renamed the published module to macss-devops.
- Moved the publishable entrypoint to code/powershell/macss-devops.psd1.
- Added GitHub Actions publication on pushes to main when code/powershell changes and the version is newer than PSGallery.
- Added a Pester alert for PSGallery API key expiry metadata.

### Fixed
- Made Install-PSDevOpsSkill resolve SKILL.md from the package root first and from the repository root as a local-development fallback.
