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
