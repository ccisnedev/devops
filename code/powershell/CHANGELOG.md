# Changelog
All notable changes to this project will be documented in this file.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## [6.0.2] - 2026-08-05

### Fixed

- **El plan no detectaba que el site de nginx no sirviera desde `current`.** Solo comprobaba que
  el archivo de configuracion existiera, y reportaba *"config existe (no se modifica)"* en nivel
  informativo. En un site con `root /var/www/<app>;` --plano, sin symlink-- el deploy creaba la
  release, movia `current`, imprimia `DEPLOYED` y terminaba en verde **sin cambiar lo que ve el
  usuario**. Un exito falso que nada en la salida delataba.

  Ahora el sondeo compara el `root` del site contra `<webroot>/<app>/current` y, si no coincide,
  emite una fila de severidad `error`. Por ADR 0009 eso es un bloqueante: `-Apply` aborta antes de
  compilar, con `-Force` como escape explicito. Tampoco anuncia ya "crear configuracion nginx",
  porque el archivo existe: apunta mal, que es otra cosa.

- **`-Init` de `Publish-FlutterWeb` sembraba `PORT=8080` y `NODE_ENV=production`.** Son claves de
  una API Node que en una web estatica no lee nadie, y `PORT` ademas confunde porque el puerto de
  nginx vive en `publish.yaml`. `Add-EnvDeployKey` gana `-NodeDefaults`, que solo pide
  `Publish-NodeApi`.

## [6.0.1] - 2026-08-05

### Fixed

- **`Invoke-SqlPackage` no usaba el resolvedor de identidad que 6.0.0 introdujo.**
  `Resolve-SqlDbIdentity` estaba implementado y con tests en verde, pero el cmdlet nunca lo
  llamaba: seguia exigiendo `DB_NAME` en el env. Al retirar esa clave --que es justo lo que ADR
  0011 pide hacer-- el cmdlet fallaba con *"Faltan variables en .env. Se requieren: DB_SERVER,
  DB_NAME, DB_USER, DB_PASSWORD"*, y el reporte mostraba `Base datos:` vacio.

  `Build-SqlPackageArgs` recibe ahora el nombre resuelto por parametro y ya no lo lee del entorno;
  el env vuelve a ser solo conexion y credenciales. Cuando `DB_NAME` actua como override
  legitimo (DB Tier-1), el encabezado lo dice: `Base datos: dev_carlos  (override de DB_NAME; el
  proyecto declara 'IMPULSA')`.

  Probar que un helper funciona no prueba que alguien lo use. Se agregan tests que asertan el
  **cableado**: que `Invoke-SqlPackage` referencia `Resolve-SqlDbIdentity`, que `Invoke-PgSchema`
  referencia `Resolve-PgDbIdentity`, y que el helper de argumentos ya no exige `DB_NAME`.

## [6.0.0] - 2026-08-05

Release de ruptura. **Invocaciones y archivos de configuración que hoy funcionan dejarán de
funcionar hasta migrarlos.** Todo lo que rompe falla con un mensaje que dice qué poner en su lugar
y dónde; abajo está el procedimiento completo.

Las tres rupturas van juntas a propósito: quien tenga que recorrer sus env files, que los recorra
una sola vez.

### Changed

- **El destino de despliegue se llama por lo que es: `MACSS_DEPLOY_SSH_ALIAS`** (antes
  `MACSS_DEPLOY_SERVER`). ADR 0010. `MACSS_DEPLOY_SERVER` y `DB_SERVER` se llamaban igual y
  significaban cosas incompatibles —un alias que solo existe en el `~/.ssh/config` de quien
  despliega, y una IP resoluble desde cualquier parte—. El nombre nuevo se autodocumenta: si
  alguien pone una IP ahí, salta a la vista que está mal. Se conserva el prefijo `MACSS_DEPLOY_`
  porque es el contrato del filtro que impide que el metadato de despliegue viaje al servidor.
- **`Publish-FlutterWeb` y `Publish-DockerStack` adoptan `-EnvFile`.** El destino sale del env file
  gitignored, no de `publish.yaml` ni de `stack.yaml`. Un alias SSH es *machine-local*: versionarlo
  hace que el repo no sea portable y obliga a editar un archivo del repo para cambiar de entorno.
  La clave `server:` desaparece de ambos templates.
- **`Invoke-PgSchema` gana `-EnvFile`** en `-Plan`, `-Apply`, `-Dump` y `-Script`, en paridad con
  `Invoke-SqlPackage`. **No** adopta alias SSH: su destino es un endpoint de red, no un host al que
  saltar.
- **La identidad de la base sale del archivo de proyecto** (ADR 0011). SQL Server la lee de `<Name>`
  del `.sqlproj`; PostgreSQL, de `database:` en `pgschema.yaml`. `DB_NAME` era idéntico en `.env` y
  `.env.production` en todos los repos medidos: identidad duplicada, no configuración. `DB_NAME`
  sobrevive como **override explícito** para las DB Tier-1 desechables (`dev_<nombre>`), y el plan
  lo muestra marcado como tal.
- **Una deprecación falla; no avisa y continúa** (ADR 0012). El aviso blando no retrasa la ruptura:
  la vuelve permanente. La prueba estaba en esta misma suite, donde el warning de
  `-Publish`/`-DeployReport` se imprimía decenas de veces sin que nadie migrara.
- **`deploy.yaml` deja de ser fallback de `publish.yaml`** y pasa a fallar. El aviso anterior era un
  `Write-Host`: ni se capturaba con `-WarningVariable` ni aparecía en un log de CI.

### Removed

- **Alias `-Publish` y `-DeployReport`.** Use `-Apply` y `-Plan`. En contexto desatendido, `-Apply`
  requiere `-AutoApprove` (ADR 0002 §4).
- **`Publish-FlutterWebLegacy`.** Use `Publish-FlutterWeb`.
- **`Resolve-DeployTarget`** (helper privado), reemplazado por `Resolve-DeployTargetFromEnv`.
- **`PGDATABASE` del env** de `Invoke-PgSchema`, movido a `pgschema.yaml`.

### Added

- `Deny-DeprecatedUsage`: única vía de producir un error de deprecación, para que ningún mensaje
  quede a criterio de quien escribe el `throw`.
- `Resolve-DeployTargetFromEnv`, `Resolve-SqlDbIdentity`, `Resolve-PgDbIdentity`.
- `database:` en el template de `pgschema.yaml`.

### Fixed

- **La suite no estaba aislada del módulo publicado.** `Remove-Module` por nombre quita *una*
  versión, así que el módulo instalado en `PSModulePath` podía quedar cargado junto al del repo y
  ganar la resolución de nombres: los tests pasaban a medir el módulo instalado en vez del código
  bajo prueba.

### Migración

**1. Renombrar la clave de destino** en cada `.env` y `.env.production` de los repos con
`Publish-NodeApi`, `Publish-FlutterWeb` o `Publish-DockerStack`:

```diff
- MACSS_DEPLOY_SERVER=prod
+ MACSS_DEPLOY_SSH_ALIAS=prod
```

El valor no cambia: sigue siendo el alias de `~/.ssh/config`. Son archivos **gitignored**: hay que
tocarlos en cada estación de trabajo y en cada servidor. Los `.env.example` de `micro`, `pyme` y
`tigre` sí están versionados y van por commit.

**2. Sacar `server:` de los archivos versionados** y llevar su valor a la clave de arriba:

```diff
  # publish.yaml (Flutter Web) / stack.yaml (Docker)
- server: prod
```

**3. Retirar `DB_NAME` del env** cuando solo repita el nombre del `.sqlproj`. Consérvelo únicamente
si apunta a una base distinta (Tier-1).

**4. Mover `PGDATABASE`** del `.env` a `pgschema.yaml`:

```diff
  # pgschema.yaml
+ database: mi_base
```

**5. Actualizar las invocaciones:**

```diff
- Publish-NodeApi -Publish
+ Publish-NodeApi -Apply -AutoApprove          # -AutoApprove en CI y scripts desatendidos
- Publish-FlutterWeb -DeployReport
+ Publish-FlutterWeb -Plan
```

**6. Renombrar `deploy.yaml` a `publish.yaml`.** El contenido no cambia.

> **Nota para CI:** el runner fija la versión del módulo en su `Dockerfile`
> (`Install-Module macss-devops -RequiredVersion ...`). Suba ese pin a `6.0.0` y republique el
> runner **después** de migrar los repos, no antes.

## [5.8.0] - 2026-07-31

### Added
- **Artefacto de plan + paridad `-Plan`/`-Apply` (ADR 0009)**. Nuevo helper compartido
  `Private/DeployPlan.ps1`: un objeto de plan común (`New-DeployPlan`/`New-DeployPlanRow`),
  **un solo renderer** (`Show-DeployPlan`) usado por `-Plan` **y** `-Apply`, y un escritor de
  reporte markdown (`Save-DeployPlan`/`Format-DeployPlanMarkdown`).
  - `-Plan` ahora **persiste** un reporte de cambios en `.macss/plans/<cmdlet>-<target>-<ts>.md`
    (gitignored; override con el modelo `-OutFile`, estilo `terraform plan -out`).
  - `-Apply` ahora **muestra el mismo plan que `-Plan`** (mismo sondeo del servidor) antes de
    confirmar, cumpliendo por fin el ADR 0002 §"Confirmation flow" paso 1 ("reuse the -Plan
    rendering"). `-Apply` **no** escribe reporte.
  - Recompute en vivo (no plan bloqueado): el reporte es un snapshot; un `-PlanFile` bloqueado
    queda diferido.
- **`-Apply` aborta ante bloqueantes del plan**. Una fila de severidad `error` significa que el
  deploy ya se sabe fallido (hoy: el puerto de nginx ocupado por otro proceso). Antes solo se
  pintaba en rojo y el deploy seguía: bajo `-AutoApprove` nadie lee la pantalla, así que se
  compilaba y subía el artefacto para fallar al final. Ahora `Get-DeployPlanBlocker` los extrae y
  `-Apply` falla limpio **antes** de confirmar y compilar, nombrando cada bloqueante; **`-Force`**
  es el escape explícito. Misma lección que el guard de puerto de pm2 (5.7.0).
- **Test de contenedor del plan** (`test/PublishFlutterWebPlan.container.test.ps1`, ADR 0009
  REQ-5). Contra un sshd real en contenedor, ejercita el sondeo en tres escenarios —greenfield,
  release+nginx existentes, y puerto ocupado por un proceso real— y comprueba filas, severidades,
  número de acciones, el reporte escrito y el bloqueante detectado de punta a punta.

### Changed
- **`Publish-FlutterWeb` migrado como referencia** al nuevo modelo. Su `-Apply` deja de confirmar
  a ciegas: enseña versión `current`, si la release existe y el estado de nginx, igual que `-Plan`.
  Builder `Private/FlutterWebPlan.ps1` compartido por ambas ramas, partido en `Invoke-FlutterWebProbe`
  (I/O por SSH) y `ConvertTo-FlutterWebPlan` (puro), de modo que la asignación de severidad —la que
  decide si un deploy se bloquea— se testea sin servidor.
- **`Save-DeployPlan` crea `.macss/.gitignore` con `*`** (patrón `.terraform/`). El reporte lleva
  alias e IP del servidor; antes dependía de que cada proyecto consumidor recordara ignorarlo.
- **`-Timestamp` fija también el nombre del archivo** del reporte, no solo su cuerpo: antes una
  llamada "determinista" seguía generando un nombre distinto en cada ejecución.
- **El reporte markdown escapa `|` y saltos de línea** en las celdas. Irrelevante para Flutter Web,
  necesario antes del rollout a cmdlets cuyos valores son menos dóciles (nombres de objetos SQL).

### Notes
- Rollout pendiente a `Publish-NodeApi`, `Publish-DockerStack`, `Invoke-SqlPackage`,
  `Invoke-PgSchema` (mismo patrón; requieren validación con tests de contenedor).
- `-Apply` ahora abre una conexión SSH **antes** de pedir confirmación (el sondeo alimenta el plan
  que se muestra). Es read-only, pero un `-Apply` cancelado ya habrá contactado al servidor.

## [5.7.1] - 2026-07-23

### Fixed
- **`Install-FlutterWeb.sh`: bloque de symlink duplicado**. El paso «6. Actualizar symlink
  current» (más un `chmod -R 755` colgante) estaba repetido literalmente al final del script,
  ejecutando `ln -sfn` y los `echo DEPLOYED:` dos veces por deploy. Inofensivo (idempotente)
  pero ruidoso: la salida mostraba «Release anterior» apuntando a la release recién creada y
  un `DEPLOYED:` doble. Eliminada la repetición; el script deja el mismo estado con una sola
  pasada. Detectado durante el despliegue limpio de `pyme` a prod (2026-07-23).

### Added
- **Test e2e de contenedor para Flutter Web** (`test/PublishFlutterWeb.e2e.container.test.sh`).
  En un contenedor Linux limpio con nginx real (shim de `systemctl`), ejercita
  `Install-FlutterWeb.sh` + `Configure-NginxSite.sh` juntos y prueba que el sitio **sirve** de
  verdad: `/` → 200, `version.json`, y fallback SPA (deep-link → 200). Incluye el guard de
  regresión del bloque duplicado (**`DEPLOYED` aparece exactamente una vez**) y la idempotencia de
  nginx (segundo run → `NGINX:EXISTS`). Antes no había cobertura de contenedor para Flutter Web.

## [5.7.0] - 2026-07-22

### Fixed
- **Guard de handoff de puerto (pm2)**: antes de `pm2 start`, `Manage-NodeProcess.sh` espera
  (acotado, `PORT_FREE_TIMEOUT`, default 15s) a que el `PORT` quede libre. Un restart de la
  propia app libera el puerto en <2s y el deploy continúa; pero si un proceso **ajeno** (p. ej.
  un git-clone/legacy en el mismo host) sigue reteniéndolo, el deploy **falla limpio** nombrando
  el puerto, en vez de dejar que pm2 entre en un crash-loop `EADDRINUSE`.
  Motivado por el incidente 2026-07-22: un cutover con el legacy aún escuchando produjo 254
  reinicios `EADDRINUSE` en `:3020` (~1h de fotos caídas para los consumidores del file server
  servidos vía ese puerto). Con el guard, ese cutover habría fallado con un solo mensaje claro.
  Aplica a los dos caminos de pm2 (config-as-code y arranque directo). Probe TCP portable
  (`/dev/tcp`), sin dependencias nuevas. Test de contenedor nuevo.

## [5.6.0] - 2026-07-22

### Deprecated
- **`Publish-FlutterWebLegacy`**: queda deprecado y emite un `Write-Warning` al invocarse.
  Reemplazado por `Publish-FlutterWeb` (releases inmutables versionadas + rollback vía symlink
  `current`). Legacy ejecuta `sudo rm -rf /var/www/<name>/*` (borra sub-apps y releases previas),
  no versiona y no permite rollback. Sigue disponible por retrocompatibilidad (aún lo usan
  fintech_operaciones y pyme) y **se eliminará en la próxima versión major** una vez migrados
  sus consumidores. La función gana `[CmdletBinding()]` (habilita common params, no-breaking).

### Added
- **ADR 0007**: `Publish-FlutterWeb` adopta el destino-desde-env-file (`-EnvFile` +
  `MACSS_DEPLOY_SERVER`) por paridad con `Publish-NodeApi` (ADR 0004). Documenta la decisión y
  sus particularidades de web estática (no sube `.env`; el env file es solo selector de destino).
  Implementación trackeada en #54.

## [5.5.0] - 2026-07-21

### Added
- **Topología de procesos declarativa (ADR 0005)**: `publish.yaml` acepta `runtime.env`
  (env no-secreto, versionado) y `runtime.processes` (uno o varios procesos: api + worker).
  Con el supervisor pm2, `Publish-NodeApi` renderiza un `ecosystem.config.json` (config-as-data)
  vía `New-Pm2EcosystemJson` y lo coloca en el release. El schema es la intersección
  systemd ∩ pm2 (name/script/cwd/env); rechaza claves pm2-only (instances/cluster,
  cron_restart, watch, max_memory).

### Fixed
- **pm2 config-as-code en proyectos ESM (`type:module`)**: la detección resuelve por
  precedencia `ecosystem.config.json` → `.cjs` → `.js`. Un `ecosystem.config.js` ESM ya no
  rompe pm2 con "No script path"; el JSON generado lo carga nativo. El `.cjs` queda como
  válvula de escape para configs con lógica.

### Notes
- Retrocompatible: los `ecosystem.config.js` (CommonJS) existentes y los proyectos systemd
  single-process no cambian. La generación del JSON es opt-in (solo con `runtime.env`/
  `runtime.processes`).

## [5.4.0] - 2026-07-16

### Added
- **`Publish-NodeApi -PushShared`**: provisiona los `sharedPaths` declarados en `publish.yaml`
  mediante `Push-Shared.sh`, con reemplazo limpio del contenido en destino.

### Changed
- **`-Plan` muestra acciones verificadas**: el plan ahora refleja el build real y el env file
  resuelto, en lugar de acciones asumidas.
- **`Install-NodeApi.sh` endurece el guard de `sharedPaths`**: falla explícitamente si la lista
  llega vacía, en vez de continuar silenciosamente.

## [5.3.8] - 2026-07-07

### Changed
- **Deploy target moved out of `publish.yaml` into the gitignored env file (ADR 0004).**
  The target server was an SSH alias in the *versioned* `publish.yaml` — but an alias is
  **machine-local** (each workstation/CI names the same environment differently), so committing
  it coupled the shared repo to one machine. Following how kubectl/docker-context/Terraform
  keep environment identity separate from the local connection binding, the target now lives in
  the (already gitignored, already per-environment) **env file** under a namespaced key
  **`MACSS_DEPLOY_SERVER`** (an alias in the operator's `~/.ssh/config`). The environment is
  selected at invocation with **`-EnvFile <path>`** (default `.env`; prod is explicit:
  `-EnvFile .env.production`) — so switching or adding a target is a local, gitignored change,
  never a PR. A bare `-Apply` targets `.env` (the developer's own / pre-prod), so **production
  is never the default**. `MACSS_DEPLOY_*` keys are **stripped from the `.env` uploaded** to the
  server (deploy-time metadata, not app runtime config). `-Init` scaffolds `MACSS_DEPLOY_SERVER=`
  into both `.env` and `.env.production`. `publish.yaml` keeps only the portable deploy contract.
  New helpers `Resolve-DeployTarget`, `Remove-DeployOnlyEnvKeys`, `Add-EnvDeployKey` (Pester
  REQ-11..15); validated end-to-end on pre-prod (target from env, `.env` uploaded without
  `MACSS_DEPLOY_*`, crypto `/agenda_detalle_mes` → 200, 0 restarts).
- **`Invoke-SqlPackage` gains `-EnvFile`** (same environment-selection model): the SQL server
  credentials already lived in `.env`; `-EnvFile` (default `.env`) lets you pick the environment
  (`.env` / `.env.production`) at invocation instead of the hard-coded `.env`. Validated e2e
  against SQL Server 2022 **in a container** (`test/InvokeSqlPackage.container.test.ps1`):
  `-Apply -EnvFile .env.container` builds the SQL project and deploys the table to the
  containerized server, while a bare `-Plan` (default `.env` pointing at a dead server) fails to
  connect — proving `-EnvFile` genuinely selects the target file, not a hard-coded path.

### Removed
- **`-Server` override and the `servers:` allowlist (5.3.7) — superseded by ADR 0004.** Their
  sole consumer (impulsa, on a branch) migrated to `MACSS_DEPLOY_SERVER` in the same change. The
  allowlist re-introduced the very friction `-Server` was meant to remove (duplicating the
  default; a PR to add a new target), and the alias-in-`publish.yaml` was not portable.

## [5.3.7] - 2026-07-07

### Added
- **`-Server` override: pick the deploy target at invocation time (no PR to switch env).**
  The target server is a deploy-time decision, not a property of the code, but it lived only
  as `server:` in the versioned `publish.yaml` — so alternating pre-prod↔prod meant editing
  and committing the file (a PR on a protected main, polluting history). `Publish-NodeApi` now
  accepts `-Server <alias>` (on `-Apply` and `-Plan`) that overrides `publish.yaml`'s `server`.
  Precedence: `-Server` → else `publish.yaml server:`. The committed `server:` stays as the
  **default** (a bare deploy still goes to a known target — the original mis-target guardrail),
  and `publish.yaml` may declare an optional **`servers:` allowlist**; the chosen target (default
  or `-Server`) must be in it, so a `-Server` that's mistyped or copied from another project
  **fails fast** instead of deploying to the wrong host. Covered by new Pester specs (REQ-10,
  `Resolve-DeployServer`).

## [5.3.6] - 2026-07-07

### Added
- **build:false: `runtime.sharedPaths` for gitignored runtime files (secrets/keys).** A
  build:false release ships only what's in git (`git archive HEAD`), so files the app reads
  at runtime but that are **not** versioned — RSA keys, certs, credentials — were absent from
  the release. The app would boot and pass `/health` (which doesn't touch them) but then
  **crash on the first real request** that needs them (`ENOENT`), pm2 crash-loops, and the
  reverse proxy sees the port down → 5xx. Surfaced deploying impulsa: `utils/cripto.js` reads
  `./key/privatekey.pem` (gitignored `*.pem`) → unhandledRejection → crash-loop → nginx 503,
  while `/health` stayed green. `publish.yaml` now accepts `runtime.sharedPaths: [<path>, ...]`:
  each path is staged **once** by the operator under `<remoteRoot>/<name>/shared/<path>` (never
  in git) and `Install-NodeApi.sh` symlinks it into every release. If a declared shared path
  isn't staged, the install **fails fast (exit 6)** with a clear message instead of shipping a
  release that would crash-loop. `.env` continues to be handled as before (copied per release).
  Covered by new Pester specs (REQ-9, `Resolve-NodeRuntime.SharedPaths`).

## [5.3.5] - 2026-07-07

### Fixed
- **build:false: deploying from a subdirectory of the repo (monorepo) produced an empty
  package and failed with "entrypoint not versioned in git".** The packaging ran
  `git -C <cwd> archive HEAD:<prefix>` with git's cwd set to the component subdir (e.g.
  `code/api`), so git resolved `HEAD:<prefix>` **relative to the cwd** (`<prefix>/<prefix>`) —
  an inexistent tree → empty tar → the entrypoint check tripped (exit 3). Extracted the
  packaging into `Export-GitSubtreeTar`, which runs `git archive` from the repo **toplevel**
  (`--show-toplevel`) with the treeish from `--show-prefix`, archiving the component subtree
  with its files at the tar root. Depth-agnostic: works whether the api is at the repo root
  or N folders deep — you still just `cd` into the api folder and run the cmdlet.
- **build:false clean-worktree guard blocked on unrelated changes elsewhere in the repo.**
  `Test-CleanWorktree` ran `git status --porcelain` with no pathspec (whole repo), so in a
  monorepo an uncommitted file in *another* component (`code/db`, `code/app`, `docs/…`) would
  block the api deploy. It now scopes to `-- .` (the component subtree); when `-Path` is the
  repo root the behavior is unchanged.

Both surfaced while deploying impulsa's `code/api` from the new monorepo. Covered by new
Pester specs (REQ-7 scoped worktree ×3, REQ-8 subdir packaging ×2).

## [5.3.4] - 2026-07-03

### Fixed
- **pm2 (config-as-code) kept running the previous release after a deploy.** Immutable
  deploys swap the `current` symlink to the new release dir, but `pm2 startOrReload` did a
  graceful reload that reuses each app's already-resolved script realpath (the *previous*
  release), so the process kept executing the old code even though `current`, the source and
  the `RELEASE` file all pointed at the new release. `Manage-NodeProcess.sh` now does
  `pm2 delete` + `pm2 start` on the ecosystem file so pm2 re-resolves the script through the
  updated `current` symlink and actually runs the new release (brief restart; a zero-downtime
  reload would need cluster mode + a stable non-symlinked script path). Covered by a new Docker
  container test (`ManageNodeProcessPm2Symlink.container.test.sh`): two releases behind a
  `current` symlink, swap the symlink, assert the live process serves the new release.

## [5.3.3] - 2026-07-03

### Fixed
- **build:false: clear, actionable error when the source has no committed lockfile.**
  `npm ci` (used for reproducible production installs) requires a `package-lock.json` /
  `npm-shrinkwrap.json`, and build:false ships from `git archive HEAD` (tracked files only).
  When the lockfile was gitignored/untracked it was absent from the package and `npm ci`
  failed deep in WSL with a cryptic `EUSAGE`. `Build-NodeApiPackage.sh` now checks for a
  versioned lockfile up front and exits with a message telling the user to commit it
  (un-gitignore → `git add` → re-run) — no silent `npm install` fallback, so releases stay
  reproducible. Container test extended: source without a lockfile → exit 5 + actionable
  message. Validated by a real end-to-end deploy of the plain-JS `impulsa` API to pre-prod
  (WSL `npm ci` of `oracledb`/`mssql` → scp → pm2 → live `/health` 200).

## [5.3.2] - 2026-07-03

### Fixed
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
