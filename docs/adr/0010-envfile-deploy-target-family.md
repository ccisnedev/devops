# ADR 0010: El destino de despliegue se nombra por lo que es (`MACSS_DEPLOY_SSH_ALIAS`)

**Status:** Proposed (2026-08-04)
**Supersede:** ADR 0007 §5 (fallback silencioso) — ver §5 de este documento.

## Context

ADR 0004 decidió que todos los cmdlets de despliegue eligen el entorno por invocación
(`-EnvFile <path>`) y resuelven el destino desde el env file **gitignored**, no desde un archivo
versionado. `Publish-NodeApi` e `Invoke-SqlPackage` lo adoptaron; ADR 0007 lo especificó para
`Publish-FlutterWeb` pero quedó sin implementar, y `Publish-DockerStack` e `Invoke-PgSchema` nunca
se abordaron.

Al retomarlo apareció que agrupar los cmdlets como "los que faltan" oculta la distinción que de
verdad manda.

### La pregunta que ordena la familia

No es *"¿qué cmdlet quedó fuera?"*, es: **¿el destino es una máquina a la que salto, o un endpoint
con el que hablo?**

| Tipo | Qué despliega | Destino | Qué es el valor |
|---|---|---|---|
| **app** | Flutter web (estático) | máquina → SSH | alias de `~/.ssh/config` |
| **api** | Node / Dart / Python | máquina → SSH | alias de `~/.ssh/config` |
| **stack** | contenedores | máquina → SSH | alias de `~/.ssh/config` |
| **db** | SQL Server / PostgreSQL | endpoint de red | IP o URL + credenciales |

Tres contra uno, no dos contra uno: `Publish-DockerStack` cae del lado de app/api. Y los dos
cmdlets de base de datos quedan juntos del otro lado por la misma razón, no por casualidad.

### El nombre estaba mintiendo

`MACSS_DEPLOY_SERVER` y `DB_SERVER` se llaman igual y significan cosas distintas: el primero es un
**alias local** que solo existe en el `~/.ssh/config` de quien despliega; el segundo es una **IP o
URL** resoluble desde cualquier parte. Dos claves `*_SERVER` con semánticas incompatibles es
precisamente lo que hace que la familia parezca inconsistente cuando no lo es.

Un nombre que declara su propósito elimina la ambigüedad: si alguien pone una IP en
`MACSS_DEPLOY_SSH_ALIAS`, salta a la vista que está mal.

El nombre además hace trabajo hacia adelante. Cuando llegue el render a k3s (ADR 0006, ADR 0008),
el destino **no será un alias SSH** sino un contexto de kubeconfig. Bajo el nombre `SERVER` esa
diferencia se esconde; bajo `SSH_ALIAS` obliga a declararla como otra clave,
`MACSS_DEPLOY_KUBE_CONTEXT`.

### Por qué se conserva el prefijo `MACSS_DEPLOY_`

`SSH_ALIAS` a secas se lee mejor, pero rompe un contrato existente. El filtro que impide que el
metadato de despliegue viaje al servidor funciona **por prefijo**:

```powershell
$Lines | Where-Object { $_ -notmatch '^\s*MACSS_DEPLOY_[A-Za-z0-9_]*\s*=' }
```

`Publish-NodeApi` sube el `.env` al servidor, y `Publish-DockerStack` lo subirá como env-file del
stack. Una clave sin el prefijo quedaría fuera del filtro y acabaría en el env del host. El prefijo
no es decoración: es la marca de "esto no viaja".

## Decision

### 1. La clave se llama `MACSS_DEPLOY_SSH_ALIAS`

Para los tres cmdlets cuyo destino es una máquina: `Publish-NodeApi`, `Publish-FlutterWeb` y
`Publish-DockerStack`.

```
Publish-FlutterWeb  -Apply                          # -> .env             (entorno por defecto)
Publish-DockerStack -Apply -EnvFile .env.production # -> prod (explícito)
```

`MACSS_DEPLOY_KUBE_CONTEXT` queda **reservado** para el render a k3s. No se implementa aquí.

### 2. Los cmdlets de base de datos no adoptan alias

`Invoke-SqlPackage` conserva `DB_SERVER`; `Invoke-PgSchema` conserva sus variables `PG*`. Ahí
`SERVER` es un nombre honesto: es un servidor de verdad, alcanzable por red. Lo único que le falta
a `Invoke-PgSchema` es el **selector**: gana `-EnvFile` (default `.env`) en `-Plan`, `-Apply`,
`-Dump` y `-Script`, en paridad con `Invoke-SqlPackage`. Nada más.

### 3. `Publish-DockerStack` y `Publish-FlutterWeb` adoptan `-EnvFile`

Con el helper compartido `Resolve-DeployTargetFromEnv` (`Private/PublishHelpers.ps1`), que
concentra lo que hoy `Publish-NodeApi` resuelve en línea. `server` desaparece de `stack.yaml` y de
`publish.yaml`; el resto del esquema permanece, porque describe **qué** se despliega, no **dónde**.

El `.env` que `Publish-DockerStack` sube se filtra con `Remove-DeployOnlyEnvKeys`. `Publish-FlutterWeb`
no filtra porque no sube nada: la web es estática (ADR 0007 §2). La asimetría es una consecuencia
de qué despliega cada uno, no una inconsistencia.

### 4. Producción nunca es el default

Un `-Apply` desnudo apunta a `.env`. Producción exige `-EnvFile .env.production` explícito, en los
cinco cmdlets.

### 5. Compatibilidad: fallar con instrucciones, no seguir funcionando

**Esta sección supersede el fallback silencioso de ADR 0007 §5.**

Un fallback que sigue funcionando con la clave vieja y solo emite un warning **perpetúa la deuda**:
nadie migra lo que no le impide trabajar, y el warning se vuelve ruido de fondo. La compatibilidad
aquí no consiste en aceptar lo viejo, sino en **fallar de inmediato con el nombre correcto a
colocar**. Obliga a migrar y a la vez entrega toda la información necesaria para hacerlo.

Cuando se detecte un mecanismo deprecado, el cmdlet **falla** con un mensaje que dice qué se
encontró, qué debe ponerse en su lugar y dónde:

```
Publish-FlutterWeb: 'MACSS_DEPLOY_SERVER' está deprecado desde 6.0.0.
  Renómbrelo a 'MACSS_DEPLOY_SSH_ALIAS' en '.env.production'.
  El valor no cambia: sigue siendo el alias de ~/.ssh/config.
  Ver ADR 0010.
```

Mecanismos que disparan el fallo:

| Se encuentra | Mensaje indica |
|---|---|
| `MACSS_DEPLOY_SERVER` en el env file | renombrar a `MACSS_DEPLOY_SSH_ALIAS` |
| `server:` en `publish.yaml` | mover el valor a `MACSS_DEPLOY_SSH_ALIAS` del env y borrar la clave |
| `server:` en `stack.yaml` | ídem |

El fallo es **detectivo**, no un efecto secundario: si el env define la clave nueva y además
arrastra la vieja, también falla — porque tener las dos es justo el estado ambiguo que hay que
eliminar.

### 6. Dos releases

| Release | Qué hace |
|---|---|
| **6.0.0** | Introduce `MACSS_DEPLOY_SSH_ALIAS` y `-EnvFile` en toda la familia. **Falla** ante cualquier mecanismo deprecado, con el mensaje de migración. |
| **6.1.0** | **Retira la detección de claves deprecadas.** El código de deprecación se borra; una clave vieja pasa a ser simplemente una clave desconocida. |

Es un **major** porque invocaciones que hoy funcionan dejarán de funcionar hasta que se renombre la
clave. Eso es deliberado, y es el punto.

La limpieza de 6.1.0 queda registrada en `docs/roadmap.md`: el riesgo de este modelo es dejar el
andamiaje de deprecación puesto para siempre, que es otra forma de la misma deuda.

### 7. `-Init` siembra la clave nueva

`Publish-DockerStack -Init` y `Publish-FlutterWeb -Init` aseguran `MACSS_DEPLOY_SSH_ALIAS=` en
`.env`, crean `.env.production` si falta, y añaden ambos al `.gitignore`. Los templates de
`stack.yaml` y `publish.yaml` ya no traen `server`. El helper existente que sembraba
`MACSS_DEPLOY_SERVER` se renombra en consecuencia.

## Testable requirements

**U** = Pester unit, **C** = container/SSH, **S** = suite/no-regresión.

- **REQ-1 (U)** `Resolve-DeployTargetFromEnv` devuelve `MACSS_DEPLOY_SSH_ALIAS` del env file
  indicado por `-EnvFile` (default `.env`).
- **REQ-2 (U)** Falla con error accionable si el env file falta o no define la clave: el mensaje
  nombra el env file buscado y la clave esperada.
- **REQ-3 (U)** **Falla** si encuentra `MACSS_DEPLOY_SERVER`; el mensaje nombra la clave vieja, la
  nueva y el archivo donde renombrarla.
- **REQ-4 (U)** **Falla** si encuentra `server:` en el archivo versionado; el mensaje indica mover
  el valor al env.
- **REQ-5 (U)** Falla también si coexisten la clave nueva y la vieja: el estado ambiguo no se
  resuelve en silencio.
- **REQ-6 (U)** `Publish-NodeApi`, `Publish-FlutterWeb` y `Publish-DockerStack` exponen `-EnvFile`
  con default `.env` en los parameter sets `Plan` y `Apply`.
- **REQ-7 (U)** `Invoke-PgSchema` expone `-EnvFile` con default `.env` en `Plan`, `Apply`, `Dump` y
  `Script`, y **no** referencia ningún alias SSH en ninguna ruta de código.
- **REQ-8 (U)** El `.env` que sube `Publish-DockerStack` no contiene claves `MACSS_DEPLOY_*`,
  incluida la nueva.
- **REQ-9 (U)** `Publish-FlutterWeb` no sube ningún env file.
- **REQ-10 (U)** `-Init` siembra `MACSS_DEPLOY_SSH_ALIAS=`; los templates de `stack.yaml` y
  `publish.yaml` no traen `server`.
- **REQ-11 (C)** End-to-end contra contenedor SSH: `-Apply -EnvFile <file>` despliega al destino de
  ese env file.
- **REQ-12 (S)** Suite Pester completa en verde; `ModuleVersion` a `6.0.0`; CHANGELOG con sección
  `### Changed` de ruptura y las instrucciones de migración.

## Consequences

- **Un solo modelo mental:** "¿qué entorno? = ¿qué env file?", y el nombre de la clave dice qué
  clase de destino es.
- **La migración ocurre, y ocurre pronto.** El corte duro tiene un costo real —16 env files en 8
  repos solo en una estación, más las copias en los servidores, más las otras estaciones— pero se
  paga una vez y con instrucciones en pantalla, en lugar de arrastrarse indefinidamente.
- **Parte de la migración es un commit y parte no.** `micro`, `pyme` y `tigre` declaran la clave en
  su `.env.example`, que **sí** está versionado; el resto son archivos gitignored que hay que tocar
  máquina por máquina y servidor por servidor.
- **El andamiaje de deprecación tiene fecha de retiro** y está anotado en el roadmap. Sin eso, el
  código de compatibilidad se queda para siempre.
- **Se abre la puerta a k3s sin ambigüedad:** `MACSS_DEPLOY_KUBE_CONTEXT` es otra clave, no otro
  valor de la misma.
- **Deuda que este ADR no cierra:** el sugar `-Environment <name>` (ADR 0004 §3) y el traslado de
  `port` al env (ADR 0007 §3) siguen diferidos.
