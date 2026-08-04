# Roadmap

## Dirección

El proyecto evoluciona desde un módulo PowerShell utilitario hacia un pequeño
ecosistema documental y operativo alrededor de una filosofía práctica de
DevOps.
La prioridad es avanzar en capas:

1. consolidar el núcleo operativo actual;
2. ordenar y fortalecer la documentación existente;
3. agregar nuevos artefactos solo cuando aporten valor real.

## Fase 1 — Consolidación del núcleo PowerShell

Objetivo: estabilizar y endurecer el artefacto actual antes de expandir el
ecosistema.

- [ ] Completar la revisión de cmdlets públicos y definir su nivel de soporte.
- [ ] Normalizar ayuda, ejemplos y contratos de entrada y salida de los cmdlets.
- [ ] Completar cobertura mínima de tests Pester para los flujos críticos.
- [ ] Formalizar recursos y templates canónicos por comando.
- [ ] Definir una política clara para versionado y publicación del módulo.
- [ ] Alinear README, CHANGELOG y manifiesto con la identidad macss-devops.
- [ ] Garantizar soporte multiplataforma: los cmdlets deben funcionar de forma
	equivalente en Windows, Linux y macOS sobre PowerShell 7+ (Core). Evitar rutas
	y binarios específicos de Windows; preferir separadores neutrales
	(`Join-Path`) y herramientas multiplataforma (p. ej. la herramienta dotnet
	`microsoft.sqlpackage`, `pgschema`, Docker, `ssh`).
- [ ] Ejecutar la suite Pester en CI en Windows, Linux y macOS para validar la
	paridad multiplataforma.

## Fase 2 — Documentación y gobierno del proyecto

Objetivo: convertir la documentación existente en una base clara, pública y
coherente, sin crear superficies nuevas por anticipación.

- [ ] Consolidar filosofía, motivación y propuesta de valor en docs/ y README.
- [ ] Documentar instalación del módulo desde PowerShell Gallery y uso local.
- [ ] Publicar guías de inicio rápido por casos de uso dentro de la estructura actual.
- [ ] Exponer arquitectura, ADR, roadmap y research de forma accesible.
- [ ] Integrar mejor enlaces entre README, docs/, changelog y recursos del módulo.

## Fase 3 — Expansión bajo demanda

Objetivo: evaluar nuevos artefactos solo cuando exista una necesidad sostenida
que el módulo y la documentación actual no resuelvan bien.

- [ ] Identificar necesidades recurrentes que justifiquen un nuevo subárbol en code/.
- [ ] Definir criterios de entrada para nuevos artefactos del repositorio.
- [ ] Diseñar cualquier artefacto nuevo desde contratos compartidos y no desde duplicación.
- [ ] Mantener la lógica de negocio en componentes reutilizables y no en la superficie nueva.

## Fase 4 — Experiencia interactiva opcional

Objetivo: explorar una capa de producto solo si la CLI y la documentación dejan
de ser suficientes.

- [ ] Identificar workflows que se beneficien de una experiencia guiada.
- [ ] Decidir formato de interfaz solo cuando exista un caso de uso validado.
- [ ] Prototipar catálogo de repos, health checks o generación asistida.
- [ ] Mantener la lógica de negocio en contratos reutilizables, no en la UI.

## Capacidades transversales

Estas líneas avanzan en paralelo y afectan a más de un artefacto.

### Calidad y release engineering

- [ ] CI para tests, validación documental y empaquetado.
- [ ] Pipeline de publicación para el módulo y validación de documentación.
- [ ] Checks de consistencia entre artefactos compartidos.

### Observabilidad y feedback

- [ ] Definir métricas de adopción y uso del proyecto.
- [ ] Incorporar observabilidad básica en flujos automatizados cuando aplique.
- [ ] Medir fricción de onboarding y tiempo hasta primera automatización útil.

### Gobierno y contratos

- [ ] Definir metadatos compartidos entre módulo, docs/ y futuros artefactos.
- [ ] Formalizar convenciones de carpetas dentro de code/.
- [ ] Registrar decisiones relevantes mediante ADR.

### Migración de claves de despliegue (ADR 0010)

El destino de despliegue pasa a nombrarse por lo que es: `MACSS_DEPLOY_SSH_ALIAS` para los cmdlets
que saltan a una máquina (app, api, stack), y las variables de conexión propias para los que hablan
con un endpoint (`DB_SERVER` en SQL Server, `PG*` en PostgreSQL).

La compatibilidad **no** consiste en seguir aceptando la clave vieja: eso perpetúa la deuda, porque
nadie migra lo que no le impide trabajar. Consiste en **fallar con el nombre correcto a colocar**.
Obliga a migrar y entrega la información para hacerlo.

Eso deja andamiaje de deprecación en el código, y el andamiaje que no tiene fecha de retiro se
queda para siempre. De ahí las dos releases:

**6.0.0 — corte con instrucciones**

- [ ] `MACSS_DEPLOY_SSH_ALIAS` y `-EnvFile` en `Publish-NodeApi`, `Publish-FlutterWeb` y `Publish-DockerStack`.
- [ ] `-EnvFile` en `Invoke-PgSchema` (paridad con `Invoke-SqlPackage`; sin alias SSH).
- [ ] Fallo detectivo ante `MACSS_DEPLOY_SERVER`, ante `server:` en `publish.yaml`/`stack.yaml`, y
      ante la coexistencia de clave nueva y vieja.
- [ ] CHANGELOG con la sección de ruptura y el procedimiento de migración.
- [ ] Migrar los env files de los repos consumidores. **Parte es un commit y parte no:** `micro`,
      `pyme` y `tigre` declaran la clave en su `.env.example` versionado; el resto son archivos
      gitignored, en cada estación y en cada servidor.

**6.0.0 — identidad de la base fuera del env (ADR 0011)**

Va en la misma release por costo de migración: ADR 0010 ya obliga a recorrer cada env file en cada
estación y cada servidor. Hacer las dos cosas en una pasada evita repetir el recorrido.

- [ ] `Invoke-SqlPackage` deriva el nombre de `<Name>` del `.sqlproj`; `DB_NAME` pasa a ser override
      explícito y se muestra marcado como tal en el plan.
- [ ] `Invoke-PgSchema` lee `database:` de `pgschema.yaml`; `PGDATABASE` en el env falla con la
      instrucción de moverlo.
- [ ] Retirar `DB_NAME` de los env files donde solo duplica el nombre del proyecto.
- [ ] **Desambiguar `contrato/contratos_db`**: el `.sqlproj` declara `contratos` y se publica sobre
      `CONTRATOS`. Requiere decisión humana — corregir `<Name>` o conservar el override — y bloquea
      el despliegue de ese repo hasta resolverse.

**6.1.0 — retirar el andamiaje**

- [ ] Borrar la detección de `MACSS_DEPLOY_SERVER` y de `server:` en los archivos versionados, con
      sus mensajes de deprecación y sus tests.
- [ ] Borrar la detección de `PGDATABASE` en el env y la de `DB_NAME` redundante (ADR 0011), con sus
      mensajes y sus tests. El override legítimo de `DB_NAME` **se conserva**: no es deprecación,
      es la vía para las DB Tier-1.
- [ ] Retirar de los templates y de la documentación toda mención a las claves deprecadas.
- [ ] Confirmar que ningún repo consumidor sigue declarándolas antes de borrar la detección: una
      vez retirada, una clave vieja pasa a ser una clave desconocida y el error deja de ser
      explicativo.

> **No cerrar 6.0.0 sin haber abierto el issue de 6.1.0.** El fallo instructivo solo es una buena
> decisión si la instrucción se retira cuando ya nadie la necesita.

`MACSS_DEPLOY_KUBE_CONTEXT` queda reservado para el render a k3s (ADR 0006, ADR 0008). No se
implementa en esta línea.

### Estrategia de despliegue: contenedores y target de render (ADR 0006)

Objetivo: migrar del modelo VM (sprawl de VM-por-API + VM-pm2-compartida) hacia
contenedores — aislamiento sin una VM por app, muchos contenedores por host — y
evolucionar `Publish-NodeApi` a un emisor multi-target sobre el `publish.yaml`
declarativo de ADR 0005 (el invariante).

Hoja de ruta escalonada (cada etapa aporta valor por sí sola):

- [ ] **Etapa 0 — Contenerizar**: `Dockerfile` por API; la imagen hornea Node y las
	dependencias nativas (p. ej. Oracle Instant Client) → elimina el dolor de
	`LD_LIBRARY_PATH` y el drift de versiones. Imagen = release. Agnóstico al orquestador.
- [ ] **Etapa 1 — Un host, muchos contenedores**: `docker compose` (intro) o
	**Podman + Quadlet** (rootless, sin daemon, integrado a systemd — mejor encaje actual).
	Resuelve el sprawl VM-por-API y los conflictos de puerto/cutover dentro de un host.
- [ ] **Etapa 2 — k3s (+ GitOps)**: multi-nodo, auto-heal, rolling updates y despliegue
	declarativo (ArgoCD/Flux). k3s = Kubernetes conforme y liviano, on-prem.
- [ ] **Etapa 3 — k8s (condicional)**: solo si nube gestionada, escala grande o
	compliance/CSI/CNI lo exigen; los manifiestos transfieren desde k3s.
- [ ] **Emisor multi-target de `Publish-NodeApi`**: `-Target <pm2|systemd|compose|podman|k3s>`
	renderiza el artefacto y hace build&push de la imagen; el núcleo (topología como datos) no
	cambia.
- [ ] **Aprovisionamiento vs deploy rootless**: formalizar que el bootstrap privilegiado
	(base dir/usuario) es una fase aparte, de una sola vez; el deploy no requiere sudo. En el
	mundo contenedor este problema se disuelve (ver ADR 0006).

### Ambiente `demo` como primer disparador de contenedores (ADR 0008)

El nuevo ambiente `demo` (capacitación) es el **caso de negocio concreto** que ejecuta la
Etapa 2 (k3s) y fija el engine de la Etapa 1 en **Podman** — ver ADR 0008 de este repositorio
(«Podman como engine y k3s como render target») y ADR 0008 del handbook («Ambiente demo:
réplica autocontenida…»). `demo` es una réplica autocontenida del release de producción, con
datos sintéticos, aislada de prod y reseteable por cohorte. Su elegancia operativa: la misma
imagen se despliega con `Publish-NodeApi -Apply -Target k3s -EnvFile .env.demo`, y cuando
producción migre a contenedores el cambio es solo `-EnvFile .env.production` — mismo `-Target`,
mismo artefacto.

- [ ] Adoptar **Podman** como engine (build / local / CI), cerrando el o-inclusivo de la Etapa 1.
- [ ] Provisionar la VM de `demo` (Ubuntu 24.04 LTS, k3s single-node, CPU en `host-passthrough`)
	y un **registry** de imágenes on-prem.
- [ ] Implementar el emisor **`-Target k3s` mínimo**: build&push + render desde `publish.yaml`
	+ `kubectl apply`, para una sola API (impulsa) como "hola mundo" del clúster.
- [ ] Cerrar la convergencia a env-file (**issue #44**): `Publish-DockerStack` e `Invoke-PgSchema`
	adoptan `-EnvFile` + `MACSS_DEPLOY_SERVER` → un solo mecanismo de destino en todo el toolkit.
- [ ] Extender a los cuatro productos (micro, impulsa, pyme, tigre) + complementarias
	imprescindibles; bases (SQL Server / Oracle) como `StatefulSet` con `PVC`.
- [ ] **Stubs / sandbox** para las APIs con efectos reales (Sentinel → buró, LIGO → banca)
	dentro de `demo`: contenerizarlas no las aísla; deben apuntar aguas abajo a un simulador.

> Dependencia externa (no vive en este repo): el refactor de configuración por ambiente en cada
> app/API — mover endpoints y credenciales a `.env` / `--dart-define` — es prerrequisito para que
> "seleccionar `demo`" sea config y no edición de código.

## Hitos sugeridos

### Hito A

Arquitectura y roadmap actualizados, identidad del proyecto consolidada y núcleo
PowerShell documentado.

### Hito B

Base documental pública ordenada, con instalación, filosofía y quickstarts.

### Hito C

Criterios para nuevos artefactos definidos y validados contra necesidades reales.

### Hito D

Experiencia interactiva evaluada con un primer prototipo, si la necesidad se
confirma.

## No hacer por ahora

- No crear subárboles nuevos dentro de code/ solo por anticipación.
- No crear una interfaz nueva sin un caso de uso que la CLI no resuelva bien.
- No dispersar la documentación canónica mientras no exista un artefacto documental real.
- No forzar una arquitectura genérica de aplicación donde el proyecto todavía es
	un ecosistema centrado en artefactos.
