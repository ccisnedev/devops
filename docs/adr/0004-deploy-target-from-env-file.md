# ADR 0004: Deploy target lives in the (gitignored) env file, selected by `-EnvFile`

**Status:** Accepted (2026-07-07) · **Enmendada** (2026-08-12) por la ADR 0011 del handbook

> **Enmienda — de dónde lo toma un ejecutor que no es una persona.**
> Esta ADR decidió que el destino sale del env file y no del archivo versionado, y eso no
> cambia. Lo que no resolvió es que el env file está gitignoreado: tras `actions/checkout` no
> existe, así que un runner de CI no tiene de dónde leerlo y ningún job de deploy podía correr.
>
> Desde 6.6.0 el destino también puede venir de la **variable de entorno**
> `MACSS_DEPLOY_SSH_ALIAS`, con la precedencia de dotenv que adopta la ADR 0011 del handbook:
> **el entorno del proceso gana sobre el archivo**. El archivo es un default para cuando el
> entorno no dijo nada.
>
> Dos condiciones inseparables, para que la precedencia no se vuelva un peligro: el valor
> resuelto **se imprime siempre con su origen**, y la ausencia de ambos sigue siendo un error
> explícito (ADR 0012), nunca un valor por defecto.

## Context

`Publish-NodeApi` (and the other deploy cmdlets) read the target server from
`publish.yaml`'s `server:` key — an alias in the operator's `~/.ssh/config`. `5.3.7`
added `-Server <alias>` + an optional `servers:` allowlist to override it without editing
the file. Two problems surfaced almost immediately:

1. **The SSH alias is machine-local, not portable.** `server: pre-prod` in the *versioned*
   `publish.yaml` names an alias that exists only in one developer's `~/.ssh/config`. On
   another machine (or the CI runner) that same environment is reached by a different alias.
   Committing the alias couples the shared repo to one workstation's local naming.
2. **The `servers:` allowlist re-introduced the friction it was meant to remove.** To be
   safe it had to contain the default (duplication), and adding a new target meant editing
   the file → a PR on protected `main` → exactly what `-Server` was for.

Every mature deploy tool keeps two concerns separate:

- **Environment identity** (pre-prod / prod) — portable, stable.
- **Connection binding** (host, user, key) — machine/operator-specific, secret-adjacent.

and resolves the connection from **local, per-machine config**, choosing the target
**explicitly at invocation**:

- **kubectl** `--context prod` → mapping lives in `~/.kube/config` (local, has secrets).
- **docker** `--context prod` → local contexts.
- **Terraform** → env selected per run (`workspace` / `-var-file`), credentials from env vars.
- **Ansible** → `-i inventories/prod` (hosts + connection vars) chosen at invocation.
- **Capistrano** (closest analog: SSH releases/current/shared) → `cap production deploy`,
  stage is a mandatory invocation argument.
- **12-Factor (III)** → config that varies per deploy (hostnames, creds) lives in the
  environment, never the repo.

This cmdlet already has that local, per-machine store: **`~/.ssh/config`** (alias → HostName
/ User / IdentityFile). The mistake was putting the alias *name* in the versioned repo.

The project already carries a per-environment, **gitignored** config file: `.env` /
`.env.production` (the app's runtime config, uploaded to the server). That is the natural,
already-per-machine home for the deploy target too.

## Decision

### 1. Remove `server` (and the `servers:` allowlist) from `publish.yaml`

`publish.yaml` keeps only the **portable deploy contract** (runtime, entrypoint,
`sharedPaths`, health, api.basePath). It no longer contains any environment-specific target.
(`server`/`servers` existed only in `5.3.7`, used solely by impulsa on a branch — removing
them breaks no released consumer.)

### 2. The deploy target lives in the env file, namespaced

Each gitignored env file declares its own target with a **namespaced** key:

```dotenv
MACSS_DEPLOY_SERVER=pre-prod-mio     # alias in the operator's ~/.ssh/config
```

- `MACSS_DEPLOY_*` is **deploy-time metadata**, not app runtime config. The cmdlet reads it
  for its own use and **strips every `MACSS_DEPLOY_*` key from the `.env` it uploads** to the
  server, so the app's runtime environment stays clean.
- The value is a `~/.ssh/config` alias (per-machine). Different workstations/CI point the same
  logical environment at their own alias — nothing environment-specific is committed.

### 3. `-EnvFile <path>` selects the environment (default `.env`)

```
Publish-NodeApi -Apply                          # -> .env            (dev / pre-prod default)
Publish-NodeApi -Apply -EnvFile .env.production # -> prod (explicit)
```

- `-EnvFile` is a **path** (à la Docker `--env-file`): flexible — any file, including a
  developer's own container env — and gets shell tab-completion. Default `.env`.
- Chosen over a name-based `-Environment <name>` (→ `.env.<name>`) at this stage to avoid
  locking a naming convention prematurely. `-EnvFile` is the primitive; a name-based
  `-Environment` can be layered later as sugar (`-Environment production` ≡
  `-EnvFile .env.production`) **without breaking anything**, so this choice is not a dead end.
- **Safety:** a bare `-Apply` uses `.env` — the developer's own / pre-prod environment.
  **Production is never the default**; it requires an explicit `-EnvFile .env.production`
  (as run manually or from the GitHub Actions runner).
- If the selected env file is missing, or lacks `MACSS_DEPLOY_SERVER`, the cmdlet **fails
  fast** with an actionable message (run `-Init`, set the key) — never a silent wrong target.

### 4. `-Init` scaffolds the deploy key

`-Init` ensures `MACSS_DEPLOY_SERVER=` (with an explanatory comment) exists in **both** `.env`
and `.env.production`, creating `.env.production` if absent. The generated `publish.yaml`
template no longer contains `server`.

### 5. Standardize across deploy cmdlets

The target-from-env mechanism is shared (a helper reused by every deploy cmdlet). `-EnvFile`
+ `MACSS_DEPLOY_SERVER` replaces the per-cmdlet `server:`/`$deployConfig.server` reads.
`Invoke-SqlPackage` (already reads `.env`) adopts the same convention; the remaining deploy
cmdlets (`Publish-FlutterWeb`, `Publish-DockerStack`, `Invoke-PgSchema`) follow (issue #44).

## Testable requirements

**U** = Pester unit, **C** = Docker container, **S** = suite/no-regression.

- **REQ-11 (U)** `Resolve-DeployTarget` returns the `MACSS_DEPLOY_SERVER` value from a parsed
  env hashtable.
- **REQ-12 (U)** `Resolve-DeployTarget` **throws** an actionable error when
  `MACSS_DEPLOY_SERVER` is absent/empty.
- **REQ-13 (U)** Uploaded-env filtering removes **every** `MACSS_DEPLOY_*` key and preserves
  all other keys (order/values intact).
- **REQ-14 (U)** `-EnvFile` defaults to `.env`; a passed path is honored; a missing file
  fails fast with an actionable message.
- **REQ-15 (U)** `-Init` writes `MACSS_DEPLOY_SERVER=` into `.env` and `.env.production`
  (creating `.env.production`), idempotently (does not duplicate if already present), and the
  `publish.yaml` template has no `server`.
- **REQ-16 (C)** End-to-end: with an SSH-target container and an env file whose
  `MACSS_DEPLOY_SERVER` points at it, `-Apply -EnvFile <file>` deploys to that container, the
  uploaded `current/.env` contains the app keys but **no** `MACSS_DEPLOY_*`, and `/health`
  responds.
- **REQ-17 (S)** Full Pester suite + container tests pass; `5.3.7`'s `-Server`/allowlist
  removed; `ModuleVersion` bumped to `5.3.8`.

## Consequences

- **Portable repo:** `publish.yaml` no longer references any machine-local alias; the same
  repo deploys from any workstation or CI, each resolving the target from its own env file +
  `~/.ssh/config`.
- **No duplication, no PR to switch/add a target:** a new environment is a new gitignored env
  file; nothing in the repo changes.
- **Safer default:** bare `-Apply` targets the developer's own / pre-prod env; production is
  always an explicit `-EnvFile .env.production`.
- **One mental model:** "which environment?" = "which env file?" — it selects app config
  **and** target together. (The `.env`-selection concern noted in ADR 0003's wake is resolved
  by the same lever.)
- **Breaking vs 5.3.7 only:** `-Server` and `servers:` are removed. Their sole consumer
  (impulsa, on a branch) migrates to `MACSS_DEPLOY_SERVER` in the same change. Released as
  **5.3.8**.
- **Deferred:** a name-based `-Environment <name>` sugar over `-EnvFile`; `.env` layering
  (base + per-env override) à la dotenv-flow — added only if the free-form phase shows a need.
