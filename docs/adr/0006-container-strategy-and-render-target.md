# ADR 0006: Estrategia de contenedores y target de render multi-plataforma

**Estado:** Propuesto (2026-07-22)

## Contexto

El fleet creció por dos caminos que hoy duelen:

1. **Una VM con muchas APIs pm2** (tigre, impulsa, micro, pyme, y una docena más):
   runtime compartido → conflictos de dependencias y de versión de Node, sin aislamiento
   ("noisy neighbor"), y colisiones de puerto/nombre que exigen coreografías manuales de
   cutover (el rename `micro` → `micro-legacy` es un síntoma).
2. **Una VM nueva por cada API nueva**: aislamiento a costa de peso operativo — aprovisionar
   una VM entera, un usuario de servicio, el base dir con sudo (ADR-adyacente), SSH, systemd/
   pm2 — por cada workload. Lento, costoso y difícil de manejar. El sprawl VM-por-API es el
   dolor concreto.

Los contenedores son el estándar de la industria justamente porque resuelven esta tensión:
**aislamiento (deps/runtime por app) sin necesitar una VM por app**. Un host puede correr
muchos contenedores aislados con densidad alta. La imagen es el release inmutable y
reproducible.

Además, el módulo ya está posicionado para esto sin reescritura: **ADR 0003** hizo el build
opcional y **ADR 0005** volvió `publish.yaml` **agnóstico al supervisor** (topología de
procesos como datos, intersección systemd ∩ pm2) — que es un **subconjunto del modelo de
Kubernetes**. El mismo manifiesto declarativo puede renderizar a otro target.

## Decisión

### 1. Adoptar el contenedor como artefacto de despliegue (imagen = release), por etapas

### 2. Consolidar en menos hosts: muchos contenedores aislados por VM

Reemplaza **ambos** anti-patrones: el VM-pm2-compartido (sin aislamiento) y el sprawl
VM-por-API (desperdicio). Una VM (o un cluster chico) hospeda la mayoría de los workloads,
cada uno aislado en su contenedor. Es el objetivo que planteó el negocio: "una sola VM donde
estén todos o la mayoría de mis contenedores".

### 3. Hoja de ruta escalonada (bajo riesgo, cada etapa aporta valor por sí sola)

- **Etapa 0 — Contenerizar.** Un `Dockerfile` por API; la imagen hornea la versión de Node y
  las dependencias nativas (p. ej. el Oracle Instant Client) → **elimina el dolor de
  `LD_LIBRARY_PATH` y el drift de versiones entre hosts**. Fundacional y agnóstico al
  orquestador.
- **Etapa 1 — Un host, muchos contenedores.** `docker compose` (introducción) o
  **Podman + Quadlet** (contenedores rootless, sin daemon, gestionados por systemd — el mejor
  encaje dado el estado actual del fleet). Resuelve el sprawl VM-por-API y los conflictos de
  puerto/cutover **dentro de un host**.
- **Etapa 2 — k3s (+ GitOps).** Cuando se necesite multi-nodo, auto-heal, rolling updates
  entre hosts y despliegue declarativo (ArgoCD/Flux). k3s = Kubernetes conforme, liviano,
  pensado para on-prem/edge.
- **Etapa 3 — k8s (condicional, no inevitable).** Solo si aparece nube gestionada
  (EKS/GKE/AKS), escala grande, o requisitos de compliance/CSI/CNI. Los manifiestos
  transfieren desde k3s, así que es de baja fricción *si* llega. Para un fleet on-prem
  chico/mediano, k3s puede ser el destino final.

GitOps (ArgoCD/Flux) es un **método de despliegue ortogonal** al orquestador; entra en la
Etapa 2, no es una etapa aparte.

### 4. `macss-devops` evoluciona a emisor multi-target

`publish.yaml` (declarativo, ADR 0005) es el **invariante**. `Publish-NodeApi -Target
<pm2|systemd|compose|podman|k3s>` renderiza el artefacto correspondiente (config pm2 /
unit systemd / compose file / Quadlet / manifiesto K8s) y hace build&push de la imagen. El
núcleo — la topología de procesos como datos — no cambia; cambia el **emisor**. "Qué
supervisor" pasa a ser "qué target de render".

## Cómo mapean los conceptos (VM → contenedor/K8s)

| Concepto VM | Equivalente contenedor/K8s | Destino |
|---|---|---|
| Release inmutable + symlink `current` | Tag de imagen en registry; Deployment rota | Transforma |
| pm2/systemd supervisando | kubelet + Deployment controller | Desaparece (1 proceso/contenedor) |
| ecosystem multi-app (api+worker) | Deployments separados (escalan independiente) | `runtime.processes` mapea 1:1 |
| Usuario rootless + base dir `/opt/app` sudo-provisionado | `securityContext runAsNonRoot`, sin FS de host | **Se disuelve** |
| Bootstrap privilegiado (sudo, base dir) | No existe path de host que provisionar | **El problema desaparece** |
| `.env` con secretos | Secrets/ConfigMaps (RBAC) | Transforma |
| `LD_LIBRARY_PATH` / deps nativas | Horneadas en la imagen | Transforma |
| Healthcheck del deploy | liveness/readiness/startupProbe | Transforma (gatea tráfico) |
| Puerto compartido, proxies, rename manual de cutover | Service + Ingress + rolling update | **Se disuelve** |
| Deploy = scp + install + pm2 | build+push imagen → `kubectl apply` / GitOps | Transforma |

## Consecuencias

- **Positivas:** aislamiento y reproducibilidad; densidad (mata el sprawl VM-por-API);
  portabilidad; rolling update y rollback nativos; secretos como objetos de API; y **toda la
  clase de problemas de aprovisionamiento/sudo/base-dir se disuelve**.
- **Costos y riesgos:** Dockerfiles que mantener; un **registry** de imágenes (on-prem o
  gestionado); pipeline de build; curva de aprendizaje; nuevos modos de fallo (image pull,
  disponibilidad del registry); cambio del modelo de red. La complejidad **no se evapora,
  sube de capa** (RBAC, cluster, registry) y se vuelve declarativa/API en vez de ssh+sudo.
- **No es preventivo:** contenerizar cuando el dolor lo justifique (infierno de dependencias,
  sprawl, escala). Workloads estables y simples pueden permanecer en VM + releases inmutables;
  ese camino sigue siendo válido.

## Alternativas consideradas

- **k8s upstream desde el inicio** — descartado: operativamente pesado para la escala; k3s da
  la misma API más liviana.
- **Docker Swarm** — simple pero con ecosistema en declive.
- **Nomad** — punto medio viable, pero diverge del camino de skills/manifiestos de K8s que
  queremos capitalizar.
- **Quedarse en VMs** — descartado como default por el dolor real del sprawl y por ser el
  estándar de la industria; válido aún para workloads estables/simples.

## Relación con otros ADR

Se apoya en **ADR 0003** (build opcional) y **ADR 0005** (topología de procesos declarativa).
El `publish.yaml` agnóstico al supervisor de ADR 0005 es el habilitador de este multi-target.
