# ADR 0007: `Publish-FlutterWeb` resuelve el destino con `-EnvFile` (paridad ADR 0004)

**Status:** Proposed (2026-07-22)

## Context

ADR 0004 decidió, para **todos** los cmdlets de despliegue, separar la *identidad de
entorno* (pre-prod / prod) del *binding de conexión* (host/user/key), resolviendo el destino
desde el env file **gitignored** (`MACSS_DEPLOY_SERVER`) elegido con `-EnvFile <path>` en la
invocación. `Publish-NodeApi` e `Invoke-SqlPackage` ya lo adoptaron; ADR 0004 §5 dejó a
`Publish-FlutterWeb` como pendiente. El issue #44 aún describe el enfoque anterior
(`-Server` + allowlist `servers:`), **superado** por ADR 0004 el mismo día — de modo que la
adopción de `-EnvFile` en `Publish-FlutterWeb` no está trackeada de forma vigente.

Hoy `Publish-FlutterWeb` lee el destino de `publish.yaml`:

```yaml
server: your-ssh-alias    # alias en ~/.ssh/config  ← machine-local, versionado
port: 4000                # puerto nginx del site dedicado
```

Esto arrastra el mismo defecto que ADR 0004 corrigió en la API: el alias SSH es
**local a la máquina**, no portable, y vive versionado en el repo. Con el objetivo actual de
mover el frontend a **pre-prod** primero y **prod** después (impulsa), y con `web-server`
reservándose para observabilidad (Grafana), necesitamos elegir el destino por invocación sin
editar un archivo versionado.

Dos diferencias respecto de la API que este ADR debe resolver:

1. **Flutter Web es estático: no se sube ningún `.env` al servidor.** En `Publish-NodeApi` el
   env file es config de runtime *y* portador del destino, y el cmdlet **filtra** las claves
   `MACSS_DEPLOY_*` del `.env` que sube (ADR 0004 §2). En Flutter Web no se sube env alguno:
   el env file es **puramente un selector de destino local**. No hay filtrado que hacer.
2. **Un repo Flutter no suele tener `.env`.** La config de la app vive en `lib/app/const.dart`
   / `preferences.dart`, no en dotenv. Introducir `.env` / `.env.production` en el repo Flutter
   es una convención **nueva**, y su único propósito allí es el destino de despliegue.

## Decision

### 1. Adoptar `-EnvFile` + `MACSS_DEPLOY_SERVER`, retirar `server` de `publish.yaml`

Igual que ADR 0004: el destino sale de `MACSS_DEPLOY_SERVER` en el env file gitignored,
elegido con `-EnvFile <path>` (default `.env`). Reutiliza el helper compartido
`Resolve-DeployTarget` (`Private/PublishHelpers.ps1`) — no se duplica lógica.

```
Publish-FlutterWeb -Apply                          # -> .env             (pre-prod por defecto)
Publish-FlutterWeb -Apply -EnvFile .env.production # -> prod (explícito)
Publish-FlutterWeb -Plan  -EnvFile .env.production # dry-run contra prod
```

- **Producción nunca es el default:** un `-Apply` desnudo apunta a `.env` (pre-prod / entorno
  del desarrollador); prod exige `-EnvFile .env.production` explícito.
- Fail-fast con mensaje accionable si el env file falta o no tiene `MACSS_DEPLOY_SERVER`.

### 2. No se sube ningún env; el env file es solo selector de destino

`Publish-FlutterWeb` **no** sube `.env` al servidor (la web es estática). No hay filtrado de
`MACSS_DEPLOY_*`. Esto es una divergencia explícita frente a `Publish-NodeApi` y debe quedar
documentada en la ayuda del cmdlet para no inducir a pensar que el `.env` viaja al server.

### 3. `port` permanece en `publish.yaml` (por ahora)

`port` describe el site nginx que crea `Configure-NginxSite.sh` cuando **no existe** config —
es una propiedad del site, portable entre entornos, no un secreto ni un binding local. Se
mantiene en `publish.yaml` (versionado). *(Nota: en sites nginx hechos a mano — p.ej. impulsa
en prod, servido en :443 por dominio — `port` es inerte porque el site ya existe y el script
no lo sobreescribe; ver el análisis de estado de impulsa.)* Mover `port` al env se difiere
hasta que un caso real lo exija.

### 4. `-Init` siembra la clave de destino

`-Init` asegura `MACSS_DEPLOY_SERVER=` (con comentario explicativo) en `.env` y
`.env.production` (creando `.env.production` si falta), idempotente, y el template
`publish.yaml` generado **ya no** contiene `server` (conserva `port`). Debe añadir
`.env`/`.env.production` al `.gitignore` del proyecto Flutter si no están.

### 5. Compatibilidad

- Los `publish.yaml` existentes con `server:` siguen leyéndose como **fallback** durante una
  ventana de transición, emitiendo un warning que recomienda migrar a `MACSS_DEPLOY_SERVER`.
  (Alternativa considerada: corte duro como en ADR 0004 §1 — allí era viable porque `server`
  solo lo usaba impulsa en una rama; aquí `Publish-FlutterWeb` ya está publicado y en uso, así
  que se prefiere fallback + deprecación.)

## Testable requirements

**U** = Pester unit, **C** = container/SSH, **S** = suite/no-regression.

- **REQ-1 (U)** `Publish-FlutterWeb -Plan/-Apply` resuelve el destino vía `Resolve-DeployTarget`
  desde `MACSS_DEPLOY_SERVER` del env file indicado por `-EnvFile` (default `.env`).
- **REQ-2 (U)** Falla con error accionable si el env file falta o no define `MACSS_DEPLOY_SERVER`.
- **REQ-3 (U)** `-EnvFile` default es `.env`; un path pasado se honra; prod requiere
  `.env.production` explícito (un `-Apply` desnudo nunca apunta a prod).
- **REQ-4 (U)** `-Init` escribe `MACSS_DEPLOY_SERVER=` en `.env` y `.env.production`
  (creándolo), idempotente; el template `publish.yaml` no tiene `server` y sí `port`.
- **REQ-5 (U)** Fallback: un `publish.yaml` con `server:` y sin env sigue funcionando y emite
  warning de deprecación.
- **REQ-6 (U)** `Publish-FlutterWeb` **no** intenta subir ningún `.env` al servidor (la web es
  estática) — ninguna ruta de código sube el env file.
- **REQ-7 (C)** End-to-end contra un contenedor SSH: `-Apply -EnvFile <file>` despliega la
  release al destino de ese env file; el site queda servido.
- **REQ-8 (S)** Suite Pester + tests de contenedor pasan; `ModuleVersion` bumped.

## Consequences

- **Repo portable:** `publish.yaml` deja de nombrar un alias local; el mismo repo despliega
  desde cualquier workstation/CI, cada uno resolviendo el destino desde su env + `~/.ssh/config`.
- **Un solo modelo mental** en todo el toolkit: "¿qué entorno? = ¿qué env file?".
- **Default seguro:** pre-prod por defecto; prod siempre explícito — habilita justo el flujo
  "pre-prod → prod" que motivó esto.
- **Divergencia documentada:** a diferencia de la API, el env no viaja al server; es solo
  selector de destino.
- **Supersede** el checkbox de `Publish-FlutterWeb` del issue #44 (enfoque `-Server`), alineándolo
  con ADR 0004.
- **Diferido:** mover `port` al env; sugar `-Environment <name>` sobre `-EnvFile` (ADR 0004 §3).
