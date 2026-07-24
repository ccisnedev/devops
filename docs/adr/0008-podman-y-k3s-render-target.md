# ADR 0008: Podman como engine y k3s como render target, disparados por el ambiente `demo`

**Estado:** Propuesto (2026-07-24)

## Contexto

**ADR 0006** definió la estrategia de contenedores por etapas (Etapa 0
contenerizar → Etapa 1 un host/muchos contenedores → Etapa 2 k3s+GitOps → Etapa 3
k8s) y anticipó que `macss-devops` evoluciona a **emisor multi-target**
(`Publish-* -Target <pm2|systemd|compose|podman|k3s>`) sobre el invariante
`publish.yaml` (topología declarativa, ADR 0005). Dejó dos cosas abiertas:

1. **El engine de la Etapa 1 sin decidir:** "`docker compose` (introducción) o
   Podman + Quadlet". Un o-inclusivo que hay que cerrar antes de construir imágenes
   y pipeline de build.
2. **La Etapa 2 (k3s) sin disparador concreto:** "cuando se necesite multi-nodo…".

El nuevo ambiente **`demo`** (ADR 0008 del repositorio `handbook`, «Ambiente demo:
réplica autocontenida de producción con datos sintéticos») es el disparador.
`demo` debe ser una **réplica autocontenida del release de
producción** de cuatro productos (`micro`, `impulsa`, `pyme`, `tigre`) —cada uno
con API, base de datos y web— más las complementarias imprescindibles: del orden de
**20+ workloads** en un mismo substrato, que además debe **resetearse entre
cohortes** de capacitación. Con esa cardinalidad y ese requisito de reset, la
orquestación se paga sola: es el caso que justifica ejecutar la Etapa 2 ahora, no
"más adelante". Y construir el clúster obliga a fijar el engine.

## Decisión

### 1. Adoptar **Podman** como engine de contenedores

Cierra el o-inclusivo de ADR 0006 Etapa 1 a favor de **Podman** (build de
imágenes, uso local de los desarrolladores, y Quadlet donde aplique). Razones,
ancladas a nuestro contexto:

- **Rootless y daemonless:** en los runners self-hosted de CI, construir sin un
  daemon privilegiado reduce superficie de ataque de forma concreta.
- **Licenciamiento:** los desarrolladores están en Windows; Docker Desktop exige
  licencia paga por encima de cierto umbral, Podman Desktop no.
- **Coherencia con ADR 0006**, que ya nombró "Podman + Quadlet" como el mejor
  encaje dado el estado del fleet.
- **Sin lock-in:** ambos producen y consumen **imágenes OCI estándar**. Lo que se
  construye con uno corre en el otro sin cambios; si Podman resulta áspero en los
  laptops Windows, el repliegue estándar (Docker Desktop local + Podman en CI) no
  exige rehacer nada. Decisión de bajo costo de reversión.

### 2. k3s como substrato de `demo` (ejecuta la Etapa 2 de ADR 0006)

`demo` corre sobre un clúster **k3s** (single-node al inicio). Precisión técnica
que evita confusión: **k3s no usa Docker ni Podman en runtime — trae `containerd`
embebido**. La elección de engine (Decisión 1) es sobre *con qué se construyen las
imágenes y qué usan los devs en local*, no sobre qué las ejecuta en el clúster.

### 3. Emisor `-Target k3s`

`macss-devops` implementa el emisor k3s: **build & push de la imagen a un
registry**, **render de manifiestos desde `publish.yaml`** (el invariante de ADR
0005) y `kubectl apply`. Es trabajo de implementación nuevo (no una simple
extensión de config). Se arranca **mínimo**: contenerizar primero API + web de un
producto; las bases (SQL Server, Oracle) entran como `StatefulSet` a partir de
imágenes oficiales/community con `PVC`; se crece desde ahí. Requiere un **registry
de imágenes** on-prem, que pasa a ser dependencia de infraestructura.

### 4. La selección de ambiente sigue el modelo de ADR 0004 — sin `server` en YAML

`demo` **no** introduce ningún `ValidateSet` de ambientes ni devuelve `server:` al
`publish.yaml`. Se materializa como un env file gitignored `.env.demo` con
`MACSS_DEPLOY_SERVER=<alias-demo>` (alias en `~/.ssh/config`), elegido por
`-EnvFile .env.demo`. Añadir `demo` cuesta **cero cambios en el módulo** para los
cmdlets ya convergidos (`Publish-NodeApi`, `Invoke-SqlPackage`). Esto es explícito
y semántico —el nombre del ambiente vive en el nombre del archivo—, sin azúcar
sintáctica, conforme se pidió.

### 5. Completar la convergencia a env-file (cerrar issue #44)

Para que `demo` funcione de manera uniforme en todos los targets, se termina la
migración pendiente de ADR 0004 §5 / ADR 0007: `Publish-DockerStack` e
`Invoke-PgSchema` adoptan `-EnvFile` + `MACSS_DEPLOY_SERVER` y dejan de leer
`server:` del YAML versionado. Resultado: **un solo mecanismo de destino en todo el
toolkit**. El `publish.yaml` se estandariza como esquema único (runtime,
entrypoint, health, `sharedPaths`, `port`) — pero el destino **nunca** vuelve a él;
esa fue la corrección de ADR 0004 y se mantiene.

## Consecuencias

- **Positivas:** engine decidido → se puede construir el pipeline de imágenes; k3s
  entra con un caso de negocio real (no especulativo); `demo` doble propósito
  (capacitación + piloto de la migración a contenedores de producción); un único
  mecanismo de selección de ambiente en todo el toolkit al cerrar #44.
- **Costos y riesgos:** el emisor `-Target k3s` es implementación nueva
  (Dockerfiles, registry, render de manifiestos, `kubectl apply`); un **registry**
  on-prem que operar; curva de aprendizaje de k3s/Podman; nuevos modos de fallo
  (image pull, disponibilidad del registry). Como advirtió ADR 0006, la complejidad
  no se evapora: **sube de capa** (RBAC, clúster, registry) y se vuelve declarativa.
- **Divergencia con producción:** la capa de supervisión de `demo` (k3s/containerd)
  difiere de la de prod (pm2/systemd). Es deliberado: el invariante de fidelidad es
  `publish.yaml`, no el supervisor — y `demo` es justamente el banco de pruebas de
  esa migración antes de tocar producción.

## Alternativas consideradas

- **Docker en vez de Podman** — descartado por licenciamiento en devs Windows y por
  el modelo daemon/root frente a rootless/daemonless de Podman en CI. Reversible por
  compatibilidad OCI si hiciera falta.
- **`docker compose` / `Publish-DockerStack` para `demo` en vez de k3s** — descartado:
  con 20+ workloads multiproducto y requisito de reset por cohorte, la orquestación
  se justifica; y `demo` sirve además de piloto de k3s para producción. Compose
  sigue siendo válido para stacks chicos de un host (Etapa 1).
- **Devolver `server` a un `publish.yaml` estándar** — descartado: reintroduce el
  defecto que ADR 0004 corrigió (el alias SSH es local a la máquina, no portable).
  La estandarización buscada se logra terminando la convergencia a env-file
  (Decisión 5), no revirtiéndola.

## Relación con otros ADR

Se apoya en **ADR 0004** (destino desde env-file), **ADR 0005** (topología
declarativa como invariante de render), **ADR 0006** (estrategia de contenedores por
etapas: este ADR cierra su Etapa 1-engine y ejecuta su Etapa 2) y **ADR 0007**
(convergencia de `Publish-FlutterWeb` a env-file). Emparejado con **handbook ADR
0008**, que define el ambiente `demo` a nivel de proceso/negocio.
