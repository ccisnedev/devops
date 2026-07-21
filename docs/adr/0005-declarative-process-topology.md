# ADR 0005: Topología de procesos declarativa (config-as-data, intersección systemd ∩ pm2)

**Estado:** Propuesto (2026-07-21)

## Contexto

`Publish-NodeApi` soporta dos supervisores (ADR original + ADR 0003): **systemd**
(default) y **pm2**. Para pm2 existe un camino *config-as-code*: si el proyecto trae un
`ecosystem.config.js` en la raíz, el módulo lo empaqueta y hace `pm2 start ecosystem.config.js`.

Ese camino tiene un supuesto no declarado: **"config-as-code == un `.js` que es CommonJS"**.
Se rompe apenas el proyecto es ESM (`package.json` con `"type": "module"`): Node interpreta
cualquier `.js` como ESM, pm2 lo carga con `require()` (CommonJS), falla, y no encuentra
`apps` → `No script path - aborting`. Lo disparó `micro` (Express ESM). Como el ecosistema
Node se mueve hacia ESM y TypeScript moderno emite ESM, esta no es una esquina: es la
trayectoria.

Además, tres fuerzas más grandes enmarcan la decisión:

1. **Dos supervisores, un manifiesto.** Hoy el `ecosystem.config.js` solo sirve a pm2. Un
   proyecto systemd no tiene equivalente declarativo de topología multi-proceso; se apoya en
   un único unit generado. La configuración de procesos debería ser **una sola**, agnóstica
   al supervisor, no una por herramienta.

2. **El destino es contenedores + Kubernetes.** K8s es **config-as-data declarativa**
   (Deployments/Services/ConfigMaps en YAML). Moverse hacia un `.js` imperativo es ir en
   contra de esa dirección; moverse hacia YAML declarativo es un escalón hacia los
   manifiestos de K8s.

3. **El patrón api + worker es real.** Se necesita declarar más de un proceso por despliegue.
   Eso hoy solo lo expresa el ecosystem de pm2 (a mano), no systemd.

## El principio, redefinido

**Config as code** tiene dos sentidos que se estaban confundiendo:

- **El PRINCIPIO** — estado deseado, versionado en git, revisado por PR, despliegue
  reproducible y determinista. **Esto se preserva y se refuerza.**
- **El MECANISMO** — que el archivo sea un `.js` *ejecutable* (`require()`, lógica,
  condicionales). **Esto se deja caer a propósito**, porque es no-determinismo oculto (justo
  lo que los sistemas declarativos eliminaron), ata la config a pm2, y es la causa raíz de la
  ruptura ESM.

Adoptamos **config-as-data**: la topología de procesos se declara como **datos en
`publish.yaml`**, y el módulo **renderiza** la configuración específica del supervisor
(units de systemd o config de pm2) al desplegar. Esto es config-as-code como principio,
config-as-data como mecanismo — al estilo k3s / k8s / docker-compose.

## Decisión

### 1. El schema de `publish.yaml` es la intersección systemd ∩ pm2

Solo se expone en el schema portable lo que **ambos** supervisores pueden honrar de forma
nativa. Lo específico de un supervisor queda fuera (o como extensión marcada como
no-portable).

| Concepto (schema portable) | systemd lo honra con | pm2 lo honra con |
|---|---|---|
| `name` (nombre del proceso) | nombre del unit / `SyslogIdentifier` | `name` del app |
| `script` (entrypoint) | `ExecStart=node <script>` | `script` |
| `cwd` (default: dir del release) | `WorkingDirectory=` | `cwd` |
| `env` (inline, NO-secreto, versionado) | `Environment=K=V` | `env: { K: V }` |
| envFile (secretos) | `EnvironmentFile=` | dotenv del app / `--env` |
| `restart` (`always`/`on-failure`/`no`) | `Restart=` + `RestartSec=` | `autorestart` + `restart_delay` |
| `enabled` (auto-inicio en boot) | `systemctl enable` | `pm2 startup` + `pm2 save` |
| **múltiples procesos** (api + worker) | **N units** (uno por proceso) | N apps en un config |

Esquema resultante:

```yaml
runtime:
  processManager: pm2            # o systemd — el TARGET del render
  build: false                   # ADR 0003
  entrypoint: server.js          # atajo single-process (si no hay processes:)
  env:                           # env inline, NO-secreto, versionado
    NODE_ENV: production
    LD_LIBRARY_PATH: /opt/oracle/instantclient_11_2
  restart: always                # intersección; default always
  restartDelaySec: 5
  processes:                     # OPCIONAL. Ausente -> un proceso = {name: appName, script: entrypoint}
    - name: api
      script: server.js
      env: { ROLE: api }         # se fusiona SOBRE runtime.env
    - name: worker
      script: worker.js
      env: { ROLE: worker }
```

### 2. Lo que queda FUERA del schema portable (y por qué)

- **`instances` / cluster mode / `exec_mode`.** systemd no tiene equivalente al socket
  compartido con balanceo de pm2 cluster. Además K8s escala con **réplicas de pods**, no con
  cluster-en-contenedor (anti-patrón: dos supervisores peleando el ciclo de vida). El default
  es **fork / 1 proceso por unit**, que mapea 1:1 a "un proceso por contenedor". No se
  promueve cluster.
- **`cron_restart`, `watch`, `max_memory_restart`.** Específicos de pm2 o requieren traducción
  no trivial a systemd (timers, path-units, `MemoryMax` con semántica distinta). Fuera del
  schema portable.

Estas capacidades pm2-only siguen disponibles por la **válvula de escape** (§4), documentadas
como no-portables.

### 3. Render por supervisor

- **pm2:** `processes[]` → se **genera** un ecosystem en formato **JSON** dentro del release al
  desplegar (`ecosystem.config.json`; pm2 lo carga nativo, sin trampa CJS/ESM). `env` = merge
  de `runtime.env` + `env` por proceso; secretos vía dotenv del app. `restart` → `autorestart`
  + `restart_delay`. Nadie escribe un ecosystem a mano.
- **systemd:** `processes[]` → **un `.service` por proceso** (`<app>-<name>.service`, o `<app>`
  si es single-process). `env` → líneas `Environment=`; secretos → `EnvironmentFile=`.
  `script` → `ExecStart`. `restart` → `Restart=`. `enabled` → `systemctl enable`.

### 4. `ecosystem.config.*` a mano: deprecado, con válvula de escape

- Se **depreca** el `ecosystem.config.js` escrito a mano como forma recomendada.
- La **detección** se amplía a `ecosystem.config.cjs` → `ecosystem.config.js` (resolver el
  primero que exista) para: (a) no romper repos legacy con `.js` CommonJS (impulsa, tigre,
  fotos); (b) dar una salida ESM-safe (`.cjs` es CommonJS siempre, ignora `type:module`).
- Este camino queda como **válvula de escape pm2-only** para el caso raro que de verdad
  necesite lógica computada. Es la excepción, no el default.

### 5. Restricción del `.env` (secretos)

El archivo de secretos debe ser parseable por la **intersección** de tres consumidores:
`systemd EnvironmentFile` ∩ `bash source` (camino directo pm2) ∩ `dotenv`. En la práctica:
**`KEY=value` plano**, sin interpolación `${VAR}`, sin `export`, sin comillas con espacios ni
`#` inline en el valor. El env NO-secreto vive en `runtime.env` (versionado); el `.env` solo
lleva secretos.

## Consecuencias

- **Un solo manifiesto** describe la topología, agnóstico al supervisor. `publish.yaml` es la
  fuente de verdad; el render tiene múltiples targets (systemd, pm2).
- **Alineado con K8s.** Los mismos datos (`processes: [api, worker]`, `env`, `restart`)
  mapean a Deployments. Se desacopla "qué procesos existen" de "quién los supervisa";
  mañana el target de render puede ser K8s. La intersección systemd ∩ pm2 es además ⊂ el
  modelo de K8s → a prueba de futuro.
- **Fin de la ruptura ESM**: el pm2 config se genera en JSON; ya no depende del `type` del
  proyecto.
- **Retrocompatible**: los `ecosystem.config.js` (CommonJS) existentes siguen funcionando por
  detección; los proyectos systemd single-process no cambian.
- **Costo**: nuevo parser/render en el módulo (PowerShell + `Manage-NodeProcess.sh`), con TDD
  y pruebas integrales en contenedor (Docker) como destino, antes de tocar el módulo instalado.
  El módulo es compartido (tigre, impulsa, fotos, micro) → retrocompatibilidad obligatoria.

## Alternativas descartadas

- **`ecosystem.config.ts`** (TS-first en el manifiesto): pm2 no ejecuta `.ts`, requeriría
  transpilar y rompería `build:false`. La política TS-first (ADR 0002/0003) aplica a la
  *aplicación*, no al manifiesto que consume una herramienta externa fija.
- **`ecosystem.config.mjs`**: soporte ESM de pm2 frágil y dependiente de versión (prod 5.3.1
  vs pre-prod 7.0.3). Riesgoso.
- **Solo `.cjs` como default** (sin `publish.yaml processes`): resuelve la ruptura ESM pero
  no unifica con systemd ni avanza hacia K8s; deja la topología multi-proceso atada a pm2.
