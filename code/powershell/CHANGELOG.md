# Changelog
All notable changes to this project will be documented in this file.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/)
and the project adheres to [Semantic Versioning](https://semver.org/).

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
