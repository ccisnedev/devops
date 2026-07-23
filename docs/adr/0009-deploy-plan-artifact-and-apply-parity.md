# ADR 0009: Artefacto de plan + paridad de render entre `-Plan` y `-Apply`

**Status:** Accepted (2026-07-23)

## Context

El ADR 0002 definió la taxonomía Init/Plan/Apply y, en el *Confirmation flow for -Apply*,
paso 1, mandató: **"Build and render the plan (reusing the -Plan rendering)."** En la práctica
esto quedó incumplido: hoy `-Apply` (en `Publish-FlutterWeb`, `Publish-NodeApi`, ...) imprime
solo un resumen de la **config local** y confirma con una acción de una línea, mientras que
`-Plan` además **sondea el servidor** (versión `current`, si la release existe, estado de nginx /
sharedPaths / puertos) y muestra las acciones. Es decir, `-Apply` confirma contra un plan más
pobre que el que `-Plan` enseña — divergencia observada durante el despliegue de `pyme` a prod
(2026-07-23).

Además, el plan solo existía en pantalla: no quedaba un **artefacto** revisable (para adjuntar a
un ticket/PR, comparar entre entornos, o auditar qué se iba a cambiar).

## Decision

### 1. Un solo objeto de plan y un solo renderer (paridad `-Plan` == `-Apply`)

Se introduce el helper compartido `Private/DeployPlan.ps1`:

- `New-DeployPlan -Cmdlet -Target -Sections -Actions` → objeto de plan común (agnóstico al cmdlet):
  sceciones ordenadas de `label -> valor` (string o fila con severidad) + lista de acciones.
- `New-DeployPlanRow -Text -Level` (`info|ok|warn|error|muted`) → valor con severidad, que
  determina el color en pantalla y un marcador en el reporte.
- `Show-DeployPlan -Plan` → render a pantalla. **Lo usan tanto `-Plan` como `-Apply`**, de modo
  que el preview contra el que `-Apply` confirma es idéntico al de `-Plan` **por construcción**.

Cada cmdlet aporta un builder específico (p.ej. `Get-FlutterWebPlan`) que hace el **sondeo
read-only** del servidor y devuelve el objeto común. `-Apply` construye el mismo plan (mismo
sondeo) y lo muestra **antes** de `Confirm-MacssChange`.

### 2. `-Plan` persiste un reporte de cambios; `-Apply` no

- `Save-DeployPlan -Plan -ProjectRoot [-OutFile] [-Timestamp]` escribe el plan como **markdown**
  en `.macss/plans/<cmdlet>-<target>-<timestamp>.md` (gitignored), o en `-OutFile` (paridad con
  `terraform plan -out`). `Format-DeployPlanMarkdown` es el render puro (testeable).
- **`-Plan` escribe el archivo; `-Apply` NO.** `-Apply` muestra el mismo plan en pantalla pero no
  genera reporte (es una acción, no un dry-run archivable).

### 3. Recompute en vivo (no plan bloqueado)

`-Apply` **recomputa** el plan en el momento (no consume el archivo que `-Plan` haya escrito). Es
más simple y encaja con la escala actual. Se acepta el **trade-off**: el estado del servidor puede
cambiar entre un `-Plan` previo y el `-Apply`, así que el reporte en disco es un *snapshot*, no un
plan bloqueado. Un `-Apply` que consuma un `-PlanFile` (garantía apply==plan, estilo terraform) se
**difiere** hasta que un caso real lo exija.

### 4. Alcance

Aplica a todos los cmdlets con Plan/Apply: `Publish-FlutterWeb`, `Publish-NodeApi`,
`Publish-DockerStack`, `Invoke-SqlPackage`, `Invoke-PgSchema`. La primera entrega migra
**`Publish-FlutterWeb`** como referencia (helpers compartidos + builder + tests). El resto se
migra al mismo patrón en PRs de seguimiento (requieren validación con tests de contenedor).

## Testable requirements

**U** = Pester unit, **C** = container/SSH, **S** = suite/no-regression.

- **REQ-1 (U)** `New-DeployPlan`/`New-DeployPlanRow`/`ConvertTo-DeployPlanRow` construyen y
  normalizan el objeto de plan (string plano → fila `info`; `$null` → `muted`).
- **REQ-2 (U)** `Format-DeployPlanMarkdown` incluye título con cmdlet, target, timestamp inyectado,
  una tabla por sección, marcadores por severidad y acciones numeradas; omite el timestamp si no se
  pasa.
- **REQ-3 (U)** `Save-DeployPlan` escribe bajo `.macss/plans/` (o `-OutFile`), en UTF-8 sin BOM, y
  retorna la ruta.
- **REQ-4 (U)** `Show-DeployPlan` renderiza sin excepción.
- **REQ-5 (C)** `Publish-FlutterWeb -Plan` escribe un reporte y `-Apply` muestra el mismo plan
  (mismo sondeo) antes de confirmar.
- **REQ-6 (S)** Suite Pester sin regresión; `ModuleVersion` bumped.

## Consequences

- **`-Apply` deja de confirmar a ciegas:** enseña el estado real del servidor (mismo que `-Plan`),
  cumpliendo por fin el ADR 0002 §paso 1.
- **Artefacto auditable:** `-Plan` deja un markdown para PR/ticket/diff entre entornos.
- **Un solo renderer:** la divergencia Plan/Apply no puede reaparecer sin romper tests.
- **Costo:** `-Apply` hace un round-trip SSH read-only extra antes del build (fail-fast si el
  servidor no responde — beneficio neto).
- **Snapshot, no lock:** el reporte en disco puede quedar desfasado del `-Apply` (recompute en
  vivo); un modo `-PlanFile` bloqueado queda diferido.
- **`.macss/` gitignored** en los proyectos consumidores (el cmdlet imprime la ruta escrita).
- **Pendiente:** rollout a `Publish-NodeApi`, `Publish-DockerStack`, `Invoke-SqlPackage`,
  `Invoke-PgSchema`.
