# ADR 0002: Publish lifecycle taxonomy (Init / Plan / Apply) with explicit approval

**Status:** Accepted (2026-06-25)

## Context

The deployment cmdlets (`Publish-NodeApi`, `Invoke-SqlPackage`, `Publish-FlutterWeb`)
grew their parameter names ad hoc, copied from SqlPackage. The vocabulary became
inconsistent and confusing:

- `Publish-NodeApi` has a redundant `-Publish` switch (the cmdlet verb is already "Publish").
- The dry-run is `-DeployReport`, mixing a third word ("deploy") with "publish".
- Confirmation is inconsistent and unsafe: `Invoke-SqlPackage -Publish` prompts via
  `Read-Host`, which **throws in non-interactive shells** (breaking CI and automation),
  while `Publish-NodeApi -Publish` applies with **no confirmation at all**.

We want one stable, self-consistent vocabulary across the whole module, and a confirmation
model that is both safe (no accidental unattended deploys) and automatable.

## Decision

### Lifecycle modes (identical across all deployment cmdlets)

- **`-Init`** — scaffold the configuration files (no remote action).
- **`-Plan`** — dry-run: show what would change against the target; make no changes.
- **`-Apply`** — execute: render the plan, confirm, then apply.
- **`-AutoApprove`** — modifier for `-Apply`: skip the confirmation prompt for unattended
  use. The name denotes a *conscious decision* to run unattended (not "force/override").

This mirrors the widely understood `plan` / `apply` model (Terraform). It removes the word
"deploy" and the redundant `-Publish` switch. "Publish" remains only as the cmdlet family
verb (an approved PowerShell verb for deploying to a destination).

### Confirmation flow for `-Apply`

1. Build and render the plan (reusing the `-Plan` rendering).
2. If `-AutoApprove` is set → apply directly (log that it was auto-approved).
3. Else if the host is interactive → prompt (Y/N) showing the summary.
4. Else (non-interactive **and** no `-AutoApprove`) → **fail** with a clear, actionable
   error ("confirmation required; re-run with -AutoApprove for unattended use").
   Never hang on `Read-Host`; never apply silently.

Industry precedent for "interactive by default + explicit opt-out": gcloud `--quiet`,
Terraform `-auto-approve`, apt `-y`.

### Migration

The previous names are kept as **deprecated aliases** for one major version, emitting a
deprecation warning on use:

- `-DeployReport` → alias of `-Plan`
- `-Publish` → alias of `-Apply`

They are removed in the next major.

### Scope and implementation

- Applies to `Publish-NodeApi`, `Invoke-SqlPackage` (`-Plan` / `-Apply`), `Publish-FlutterWeb`.
- The confirmation flow lives in a single shared `Private` helper and is reused by all of
  them (DRY, one place for TTY detection + prompt + non-interactive guard).
- `SupportsShouldProcess` / `-WhatIf` is intentionally **not** used: it would add a second,
  poorer dry-run mechanism alongside the richer `-Plan`.
- Cmdlet-name consistency (e.g., renaming `Invoke-SqlPackage` into the `Publish-*` family) is
  deferred to a later phase.

## Consequences

- **Breaking change:** `-Apply` requires confirmation by default; unattended callers (CI and
  our own automation) must add `-AutoApprove`. This is intentional — it forces a conscious
  decision for unattended deploys. Released as a major version (`5.0.0`).
- `Read-Host`-in-non-interactive failures are eliminated (replaced by a clear, actionable error).
- One vocabulary across the module, stable as new `Publish-*` cmdlets are added.
- Deprecated aliases ease migration and are removed in the next major.
- Development follows strict TDD with behavioral, container-based tests for the runtime paths.
