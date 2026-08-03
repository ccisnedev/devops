# ADR 0010: Completar ADR 0004 en el resto de la familia (`Publish-DockerStack`, `Invoke-PgSchema`)

**Status:** Proposed (2026-08-03)

## Context

ADR 0004 decidió que **todos** los cmdlets de despliegue eligen el entorno por invocación
(`-EnvFile <path>`) y resuelven el destino desde el env file **gitignored**, no desde un archivo
versionado. `Publish-NodeApi` e `Invoke-SqlPackage` lo adoptaron; ADR 0007 lo especificó para
`Publish-FlutterWeb` pero quedó en *Proposed* y sin implementar. `Publish-DockerStack` e
`Invoke-PgSchema` nunca se abordaron.

Estado real medido en `5.8.0`:

| Cmdlet | Destino hoy | Naturaleza del destino | ADR 0004 |
|---|---|---|---|
| `Publish-NodeApi` | `-EnvFile` → `MACSS_DEPLOY_SERVER` | alias SSH | adoptado |
| `Invoke-SqlPackage` | `-EnvFile` → `DB_SERVER` / `DB_NAME` | conexión SQL Server | adoptado |
| `Publish-FlutterWeb` | `publish.yaml: server:` | alias SSH | **pendiente — ADR 0007** |
| `Publish-DockerStack` | `stack.yaml: server:` | alias SSH | **pendiente — este ADR** |
| `Invoke-PgSchema` | `.env` fijo, sin `-EnvFile` | conexión PostgreSQL | **pendiente — este ADR** |

### La familia no tiene un solo defecto, tiene dos

Agruparlos como "los que faltan" oculta que el problema no es el mismo:

**Defecto A — el destino vive en un archivo versionado.** Es el que ADR 0004 corrigió. Un alias
SSH es *machine-local*: nombra una entrada de `~/.ssh/config` que solo existe en la máquina de
quien despliega. Versionarlo hace que el repo no sea portable y obliga a **editar un archivo
versionado para cambiar de entorno**. Afecta a `Publish-FlutterWeb` (`publish.yaml: server:`) y a
`Publish-DockerStack` (`stack.yaml: server:`).

**Defecto B — no se puede elegir el env file.** `Invoke-PgSchema` **nunca tuvo el defecto A**: su
destino (`PGHOST`, `PGDATABASE`, `PGUSER`) ya vive en el `.env` gitignored, donde corresponde. Lo
que le falta es el selector: lee `.env` de forma fija, así que no hay manera de apuntar a
`.env.production`. Es exactamente el hueco que `Invoke-SqlPackage` ya cerró con `-EnvFile`.

Confundir ambos llevaría a introducir `MACSS_DEPLOY_SERVER` en `Invoke-PgSchema`, donde no
significa nada: no hay salto SSH que resolver, hay una cadena de conexión.

### Una diferencia entre los dos casos del defecto A

`Publish-DockerStack` **sube el `.env` al servidor** como env-file del stack
(`docker compose --env-file`). Está en la misma situación que `Publish-NodeApi`: el env file es
config de runtime *y* portador del destino, así que las claves `MACSS_DEPLOY_*` **deben filtrarse**
antes de subirlo (ADR 0004 §2, helper `Remove-DeployOnlyEnvKeys`).

`Publish-FlutterWeb` no sube nada — la web es estática — y por eso ADR 0007 §2 declara que ahí no
hay filtrado que hacer. La asimetría es real y debe quedar escrita para que nadie la "corrija".

## Decision

### 1. `Publish-DockerStack` adopta `-EnvFile` + `MACSS_DEPLOY_SERVER`

Mismo modelo que ADR 0004 y ADR 0007, reutilizando el helper compartido — no se duplica lógica.

```
Publish-DockerStack -Apply                          # -> .env             (entorno por defecto)
Publish-DockerStack -Apply -EnvFile .env.production # -> prod (explícito)
Publish-DockerStack -Plan  -EnvFile .env.production # dry-run contra prod
```

`server` sale de `stack.yaml`. El resto del esquema (`stack.name`, `composeFile`, `build`,
`include`, `health`, `postDeploy`) permanece: describe **qué** se despliega, no **dónde**.

**El `.env` que sube al servidor se filtra** con `Remove-DeployOnlyEnvKeys`: ninguna clave
`MACSS_DEPLOY_*` viaja al host.

### 2. `Invoke-PgSchema` gana `-EnvFile`, y nada más

Paridad con `Invoke-SqlPackage`: `-EnvFile <path>`, default `.env`, aplicado a todos los modos
(`-Plan`, `-Apply`, `-Dump`, `-Script`).

**No adopta `MACSS_DEPLOY_SERVER`.** Su destino son las variables `PG*` del propio env file. Añadir
un alias SSH sería inventar un salto que no existe.

### 3. Un solo helper para el defecto A

`Resolve-DeployTargetFromEnv` (nuevo, en `Private/PublishHelpers.ps1`) concentra el patrón que hoy
`Publish-NodeApi` resuelve en línea, y lo consumen `Publish-FlutterWeb` y `Publish-DockerStack`:

1. Lee el env file indicado por `-EnvFile`; si existe, resuelve con `Resolve-DeployTarget`.
2. Si no hay `MACSS_DEPLOY_SERVER` y el archivo versionado declara `server:`, **cae al legacy con
   warning de deprecación** (ventana de transición, ADR 0007 §5).
3. Si no hay ninguno de los dos, falla con un mensaje accionable que nombra el cmdlet, el env file
   buscado y la clave que falta.

### 4. Producción nunca es el default

Un `-Apply` desnudo apunta a `.env`. Producción exige `-EnvFile .env.production` explícito, en los
tres cmdlets. Esto ya rige en `Publish-NodeApi` e `Invoke-SqlPackage`.

### 5. Compatibilidad: fallback con warning, no corte duro

Los tres cmdlets están publicados y en uso. `stack.yaml: server:` y `publish.yaml: server:` siguen
funcionando durante la ventana de transición, emitiendo deprecación. `Invoke-PgSchema` sin
`-EnvFile` sigue leyendo `.env`, que es su comportamiento actual y además el nuevo default.

**Ninguna invocación existente se rompe con este ADR.**

### 6. `-Init` siembra la clave de destino

En `Publish-DockerStack`, `-Init` asegura `MACSS_DEPLOY_SERVER=` en `.env` y crea `.env.production`
si falta, idempotente; el template de `stack.yaml` deja de traer `server`. En `Invoke-PgSchema`,
`-Init` crea también `.env.production`.

## Testable requirements

**U** = Pester unit, **C** = container/SSH, **S** = suite/no-regresión.

- **REQ-1 (U)** `Resolve-DeployTargetFromEnv` devuelve `MACSS_DEPLOY_SERVER` del env file indicado.
- **REQ-2 (U)** Si el env no define la clave y hay `server:` legacy, devuelve el legacy y emite un
  warning de deprecación que nombra el cmdlet.
- **REQ-3 (U)** Si no hay ninguno de los dos, lanza un error que nombra el env file buscado y la
  clave faltante.
- **REQ-4 (U)** El env file gana sobre el legacy cuando ambos están presentes.
- **REQ-5 (U)** `Publish-DockerStack` y `Publish-FlutterWeb` exponen `-EnvFile` con default `.env`
  en los parameter sets `Plan` y `Apply`.
- **REQ-6 (U)** `Invoke-PgSchema` expone `-EnvFile` con default `.env` en `Plan`, `Apply`, `Dump` y
  `Script`, y **no** referencia `MACSS_DEPLOY_SERVER` en ninguna ruta de código.
- **REQ-7 (U)** El `.env` que `Publish-DockerStack` sube al servidor no contiene claves
  `MACSS_DEPLOY_*`.
- **REQ-8 (U)** `Publish-FlutterWeb` no sube ningún env file (hereda REQ-6 de ADR 0007).
- **REQ-9 (U)** `-Init` de `Publish-DockerStack` siembra `MACSS_DEPLOY_SERVER=` y el template de
  `stack.yaml` ya no trae `server`.
- **REQ-10 (C)** End-to-end contra contenedor SSH: `-Apply -EnvFile <file>` despliega al destino de
  ese env file.
- **REQ-11 (S)** Suite Pester completa en verde; `ModuleVersion` bumped.

## Consequences

- **Un solo modelo mental en todo el toolkit:** "¿qué entorno? = ¿qué env file?". Deja de haber
  cmdlets que se configuran editando un archivo versionado.
- **Repos portables:** el mismo repo despliega desde cualquier estación o desde CI, cada uno
  resolviendo el destino contra su propio `~/.ssh/config`.
- **Default seguro y uniforme:** prod siempre explícito, en los cinco cmdlets.
- **Asimetría documentada:** `Publish-DockerStack` filtra `MACSS_DEPLOY_*` porque sube el env;
  `Publish-FlutterWeb` no filtra porque no sube nada. No es una inconsistencia: es una consecuencia
  de qué despliega cada uno.
- **`Invoke-PgSchema` queda fuera del modelo de alias SSH** a propósito. Su destino es una conexión,
  no un host al que saltar.
- **Cierra ADR 0004 §5** y el issue #44: no queda ningún cmdlet de despliegue fuera del patrón.
- **Deuda que este ADR no cierra:** el sugar `-Environment <name>` sobre `-EnvFile` (ADR 0004 §3) y
  el traslado de `port` al env (ADR 0007 §3) siguen diferidos.
