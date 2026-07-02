# ADR 0003: `Publish-NodeApi` — any Node API (no-build runtime)

**Status:** Accepted (2026-07-02)

## Context

`Publish-NodeApi` currently assumes the project is **TypeScript**: it requires
`tsconfig.json`, runs `npm run build`, and hard-codes the entrypoint to
`dist/main.js`. That is the only TypeScript-specific part of the pipeline. Everything
downstream — versioned `releases/<id>` + `current` symlink, `.env` → `EnvironmentFile`,
systemd/pm2 management, healthcheck, `-Plan`/`-Apply` with confirmation (ADR 0002),
rootless/sudo — is runtime-agnostic and battle-tested.

The motivating case is the **impulsa API** (`impulsa_api`): a plain-JavaScript Express
app (`server.js`, PM2 process `impulsa`, `oracledb` thick v5 native binding, **no**
`tsconfig`/build). Today it runs in production from a **git clone executed in place**,
which invites live edits on the server. We want to deploy it as **immutable, versioned
releases** — exactly like the TypeScript apps — *without* waiting for a TS migration, and
with the same cmdlet.

Two observations shape the decision:

1. `js ↔ ts` is **not** a runtime difference — both are Node. The only real difference is
   whether a **build** step runs. So the cmdlet stays `Publish-NodeApi`; we make the build
   *optional*, not the runtime *generic*. (Rename triggers, deferred: a non-Node runtime, or
   a non-HTTP worker — neither applies today. Fleet is 100% Node + pm2.)
2. Native modules (`oracledb` thick) are compiled **per platform**. `npm ci` on a Windows
   host produces a Windows binary that will **not load on the Linux target**. The shipped
   `node_modules` must therefore be produced for Linux.

## Decision

### 1. `publish.yaml` runtime schema (two new keys, backward-compatible defaults)

```yaml
runtime:
  processManager: pm2        # existing
  build: true                # NEW — default true. false = no-build (ship source as-is)
  entrypoint: dist/main.js   # NEW — default: dist/main.js when build:true, server.js when build:false
```

- `build: true` (default) → **current behavior is unchanged**: require `tsconfig.json`,
  `npm run build`, assert the built entrypoint.
- `build: false` → do **not** require `tsconfig.json`, do **not** run `npm run build`;
  ship the project source.
- `entrypoint` is the release-relative path the process runs (`current/<entrypoint>`).
  Explicit value in `publish.yaml` wins; otherwise the per-mode default above.

### 2. Packaging

- `build: true` → unchanged: tarball = `dist/` + `node_modules/` + `package.json`
  (+ `ecosystem.config.js` when present).
- `build: false` → tarball = **`git archive` of the project subtree at `HEAD`** (tracked
  files only — deterministic, no local cruft, no `.env`, no `logs/`) **+** `node_modules/`.
  In a monorepo the subtree is `git archive HEAD:<relpath>` where `<relpath>` is the project
  dir relative to the repo root (empty relpath → whole repo). `package.json`, the entrypoint
  and `ecosystem.config.js` are tracked, so they come from the archive.

Because `build: false` ships from `HEAD`, **what deploys equals a known commit** — the
foundation for the release identity and the anti-drift guarantee below.

### 3. Linux-native `node_modules` (host-OS aware)

The **production** `node_modules` (`npm ci --omit=dev`) is produced for the Linux target:

- **Linux host** → install natively.
- **Windows host** → install inside **WSL** (reusing `Get-ValidWSLDistro` +
  `ConvertTo-WSLPath`), so native bindings (`oracledb`) match the server.

**Scope (conservative):** wired into the **`build: false`** path only for now, so the
existing TypeScript (`build: true`) flow is byte-for-byte unchanged. `Get-ProdModulesPlan`
is mode-agnostic (host-OS → strategy), so extending it to `build: true` later — which would
also fix the latent "native dep built on Windows ships a Windows binary" bug for TS apps — is
a one-line wiring change, deferred to avoid destabilizing current TS deploys.

### 4. Release identity & anti-drift

- Release id = **`v{version}+{shortSha}`** (`{version}` from `package.json`, `{shortSha}` =
  `git rev-parse --short HEAD`). This makes each deploy uniquely identifiable even when
  `package.json` version is static (impulsa is pinned at `1.0.0`).
- **Clean-worktree guard:** `build: false` ships from `HEAD`, so a dirty tree would deploy
  something different from what you see. `-Apply` **refuses a dirty worktree** unless
  `-AllowDirty` is passed (which tags the id `+dirty` and packages the working dir instead).
- The tarball includes a **`RELEASE`** provenance file (`name`, `version`, `sha`, UTC
  timestamp). The app may expose the sha at `/health` to detect server-side drift at a glance.

### 5. `-Init` for no-build projects

When `-Init` runs and there is **no** `tsconfig.json`, it scaffolds `publish.yaml` with
`build: false` and `entrypoint: server.js` (instead of failing). With a `tsconfig.json`
present, behavior is unchanged (`build: true`).

### 6. Remote install script

`Install-NodeApi.sh` asserts the **configured entrypoint** (new `__ENTRYPOINT__`
placeholder) instead of a hard-coded `dist/main.js`, and writes the `RELEASE` file into the
release. Default placeholder keeps `dist/main.js`, so TS installs are unchanged.

## Testable requirements

Each requirement maps to a test. **U** = Pester unit, **C** = Docker container (real
evidence), **S** = full suite / no-regression.

- **REQ-1 (U)** `Resolve-NodeRuntime` returns `Build=$true`, `Entrypoint='dist/main.js'`
  when `runtime` is absent or `build` unset (backward compatible).
- **REQ-2 (U)** `Resolve-NodeRuntime` returns `Build=$false`, `Entrypoint='server.js'`
  when `runtime.build: false` and no explicit entrypoint.
- **REQ-3 (U)** An explicit `runtime.entrypoint` overrides the per-mode default in both modes.
- **REQ-4 (U)** `Get-ReleaseId -Version '1.0.0' -ShortSha 'abc1234'` → `v1.0.0+abc1234`;
  build metadata in the version (`1.0.0+x`) is stripped before composing.
- **REQ-5 (U)** `Test-CleanWorktree` is `$true` for a clean git repo and `$false` when a
  tracked file is modified.
- **REQ-6 (U)** `Get-ProdModulesPlan -IsWindowsHost $true` selects the **WSL** strategy;
  `$false` selects **native**.
- **REQ-7 (C)** `Install-NodeApi.sh` with `__ENTRYPOINT__=server.js` installs a **source**
  tarball (contains `server.js`, no `dist/`): `releases/<id>/server.js` exists, `current`
  symlink points to it, `current/.env` exists, and a `RELEASE` file is present. Runs as a
  non-root owner in an image without sudo (rootless), mirroring the existing test.
- **REQ-8 (C)** Backward-compatible: `Install-NodeApi.sh` with the default
  `__ENTRYPOINT__=dist/main.js` still installs a `dist/`-based tarball (existing container
  test keeps passing).
- **REQ-9 (C)** End-to-end no-build: from a source tarball, start `node server.js` and get a
  successful **healthcheck** against `/health` — proving a real running process, not just files.
- **REQ-10 (S)** The full Pester suite and all container tests pass on the branch (no
  regression), and `ModuleVersion` is bumped to `5.2.0`.

## Consequences

- **Non-breaking, additive:** defaults preserve the TypeScript path. Released as **5.2.0**.
- One cmdlet, two runtimes; migrating impulsa to TS later is just flipping `build: true` +
  `entrypoint: dist/main.js`.
- Windows hosts build prod `node_modules` in WSL **for `build: false`** (correct for native
  deps like `oracledb`); the `build: true` path is unchanged. Extending WSL to `build: true`
  is deferred (would fix a latent Windows-binary bug for TS apps with native deps).
- Immutable releases + `RELEASE`/sha remove the incentive and the means to edit prod in place.
- **Out of scope (phase 2, enabled by this model):** `-Rollback`, release retention
  (keep-last-N), `-Verify`/drift check. Tracked separately.
