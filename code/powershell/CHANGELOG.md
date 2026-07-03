# Changelog
All notable changes to this project will be documented in this file.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## [5.3.1] - 2026-07-02

### Fixed
- **Publish-NodeApi `-Apply` (build:false) crashed with "Cannot convert String to
  SwitchParameter".** The local variable `$plan` (holding `'wsl'`/`'native'` from
  `Get-ProdModulesPlan`) collided with the cmdlet's own `[switch]$Plan` parameter — PowerShell
  variable names are case-insensitive, so `$plan = 'wsl'` tried to assign a String to the
  `[switch]` parameter variable and threw. The error surfaced only inside the full cmdlet (the
  `$Plan` parameter is in scope there), so unit/harness/container tests missed it. Renamed the
  local to `$modulesPlan`. Added a static AST guard test that fails if **any** local assignment
  target in `Publish-NodeApi` collides (case-insensitively) with one of its `[switch]`
  parameters (`Init`/`Plan`/`Apply`/`AutoApprove`/`AllowDirty`).
- **build:false packaging no longer mutates the working tree, and works on WSL.** The
  production `npm ci --omit=dev` previously ran **in place** in the project directory: on a
  Windows host that meant running it over `/mnt/c` (drvfs) inside WSL, which failed with
  `EIO` on `unlink` (e.g. deleting the pre-existing `oracledb-*-win32-x64.node`); and on any
  host it stripped the developer's `devDependencies` from their local `node_modules`.
  Packaging now runs in an **ephemeral `mktemp` dir** (native ext4, never drvfs, never the
  working tree) via a new `Build-NodeApiPackage.sh`: `git archive HEAD` → temp dir →
  `npm ci --omit=dev` → tar. Same script drives both the WSL (Windows host) and native (Linux
  host) paths. Covered by a new Docker container test
  (`BuildNodeApiPackage.container.test.sh`): build in a throwaway dir, `--omit=dev` honoured,
  source tree untouched, missing-entrypoint rejected.

## [5.3.0] - 2026-07-02

### Added
- **Publish-DockerStack: despliegue de stacks Docker Compose a un servidor remoto vía SSH.**
  Contraparte de `Publish-NodeApi` para infraestructura contenedorizada, con la misma taxonomía
  `Init`/`Plan`/`Apply` + `-AutoApprove` (ADR 0002) y la misma disciplina de secretos
  (`stack.yaml` versionado sin secretos; `.env` gitignored que se copia al servidor como env-file
  del stack). Releases versionados en `/opt/stacks/<name>/releases/<v{version}+{sha}>` con symlink
  `current` para rollback. Tres modos de build: `server` (build en el servidor), `transfer`
  (build local + `docker save`/`load`, mismo artefacto sin registry) y `none`. Healthcheck por
  contenedor (`healthy`/`running`) o URL, y hooks `postDeploy` (p.ej. aplicar realm-as-code).
  Reutiliza los helpers de publicación existentes (SSH config, `Invoke-RemoteScript`,
  `Confirm-MacssChange`, `Get-BashScript`). Motivación: desplegar el stack de Keycloak (IAM) sin
  Terraform, en el mismo toolchain que ya se opera.

## [5.2.0] - 2026-07-02

### Added
- **Publish-NodeApi: no-build runtime for any Node API (ADR 0003).** The cmdlet no longer
  assumes TypeScript. `publish.yaml` gains `runtime.build` (default `true`) and
  `runtime.entrypoint` (default `dist/main.js` in build:true, `server.js` in build:false).
  With `build: false` the cmdlet skips `tsconfig.json`/`npm run build` and ships the project
  **source packaged from `git archive HEAD`** (subtree-aware, tracked files only) plus the
  production `node_modules`. Motivating case: deploy a plain-JavaScript Express API
  (impulsa) as immutable, versioned releases while migrating to TS — same cmdlet.
- **Release identity `v{version}+{shortSha}` + provenance.** Every deploy in a git repo is
  tagged with the short commit sha (so static `package.json` versions still yield unique
  releases), and a `RELEASE` file (name/version/release/sha/timestamp) is written into the
  release for server-side drift detection.
- **Clean-worktree guard for build:false.** `-Apply` refuses a dirty worktree (build:false
  ships from `HEAD`); override with the new **`-AllowDirty`** (tags the release `+dirty`).
- **`-Init` scaffolds by project type.** With no `tsconfig.json`, `-Init` writes
  `build: false` + `entrypoint: server.js` instead of failing.
- **Behavioral evidence:** new Docker container tests for the source install
  (`Install-NodeApiNoBuild.container.test.sh`) and a full end-to-end deploy
  (`PublishNodeApi.e2e.container.test.sh`: install → pm2 → live `/health` 200).

### Changed
- **Linux-native `node_modules` on Windows hosts (build:false).** The production
  `npm ci --omit=dev` runs inside **WSL** on Windows so native bindings (e.g. `oracledb`
  thick) match the Linux target; native on Linux hosts. Scoped to `build: false`; the
  TypeScript (`build: true`) build path is unchanged.
- **Release directory naming.** Deploys in a git repo now use `releases/v{version}+{sha}`
  (previously `releases/v{version}`). Rollback-by-symlink and healthchecks are unaffected.
- `Install-NodeApi.sh` validates the configured entrypoint (was hard-coded `dist/main.js`);
  backward-compatible via a generic `__*__` placeholder fallback.

## [5.1.1] - 2026-06-26

### Fixed
- **New-SshAccess on Windows PowerShell 5.1: empty passphrase no longer prompts.** `New-SshKeyPair` passed `-N ''` for an unattended key, but Windows PowerShell 5.1 silently drops empty-string arguments to native commands, so `ssh-keygen` received no value and **prompted for a passphrase** (and could hang). Fixed by routing the empty-passphrase case through `cmd.exe` (where `-N ""` survives) on PS 5.1; PowerShell 7 (Windows/Linux) is unchanged. Unblocks colleagues on stock Windows PowerShell provisioning a key with `New-SshAccess`.

## [5.1.0] - 2026-06-26

### Added
- **New-SshAccess / Remove-SshAccess: `-BootstrapIdentityFile`.** The install/revoke connection can now authenticate with an explicit private key (passed to ssh as `-i`), so the bootstrap works **without ssh-agent**. Motivating use case: **key rotation** — authenticate with the OLD key while installing the new one (New-SshAccess) and while revoking the old one (Remove-SshAccess). Backward compatible: when omitted, ssh falls back to its default auth (agent/password). Validated end-to-end by rotating a host from a shared key to a dedicated per-host key.

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
