# ADR 0015: El env file llega a CI como secret del environment, no moviendo la configuración

**Status:** Accepted (2026-08-12)

**Relacionada con:** ADR 0014 (la configuración de runtime en el servidor), ADR 0004 y ADR 0011
del handbook (el destino), ADR 0002 (taxonomía Plan/Apply).

## Context

Un runner no tiene el env file: está gitignoreado, así que tras `actions/checkout` no existe.
Pero `Publish-NodeApi -Apply` necesita su contenido, porque lo sube como el `.env` del release.

La ADR 0014 resolvió eso moviendo la configuración al servidor: `.env` como `sharedPath`, y el
release la enlaza. Funciona y está probado. **Pero cuesta una propiedad que ya existía y que se
usa.**

### Lo que se pierde, medido

En producción, cada release tiene hoy su propio archivo:

```
v1.5.1+2d339572  .env propio (67 lineas)
v1.5.1+a85990d0  .env propio (67 lineas)
v1.5.1+df72cee9  .env propio (67 lineas)   <- current
```

Mover el symlink `current` a un release anterior devuelve ese código **con la configuración con
la que se desplegó**. Es un rollback real.

Con un `shared/.env` cada release tendría un *symlink* al mismo archivo: el rollback devolvería
el código viejo con la configuración de hoy. Y `-PushShared` reemplaza ese único archivo, así
que un cambio de configuración afecta hacia atrás a todas las versiones a la vez.

La ADR 0014 anotaba esa pérdida en sus consecuencias, pero igualmente presentaba el sharedPath
como el camino para desbloquear CI. Ese es el error que esta ADR corrige: **se trató un problema
de aprovisionamiento como si fuera un problema de arquitectura de la configuración.**

## Decision

**La configuración sigue viajando en el paquete. Lo único que cambia es de dónde la toma el
ejecutor.**

Cuando quien despliega es una persona, del archivo en su máquina. Cuando es un runner, de un
**secret del GitHub Environment**: el job lo materializa en un archivo temporal y lo pasa con
`-EnvFile`, que es exactamente para lo que existe ese parámetro. El `.env` que acaba en el
release es **idéntico** al de un despliegue manual.

Se publica con `Publish-EnvSecret`, que sigue la taxonomía de la familia (`-Plan` / `-Apply` /
`-AutoApprove`).

### Un secret por componente

`db`, `api` y `app` se despliegan por separado y cada uno tiene su propio env file —credenciales
de SqlPackage, configuración de runtime, destino—. Los secrets son `ENV_FILE_DB`,
`ENV_FILE_API`, `ENV_FILE_APP`. Uno solo los mezclaría y el despliegue de un componente se
llevaría la configuración de otro.

### El environment, no el repositorio

El secret cuelga de un GitHub Environment (`production`) y no del repositorio, porque el
environment es lo que permite exigir **aprobación antes de desplegar** —los gates que R05 y R23
ya piden— y deja historial de despliegues por entorno. Un secret de repositorio no tiene esa
puerta.

### La huella

Un secret no se puede leer de vuelta: sin nada más, nadie puede saber si el publicado
corresponde al archivo actual o a uno de hace tres meses. Junto al secret se publica una huella
SHA-256 del contenido como **variable** del environment, y `-Plan` la compara. El hash de un
archivo de decenas de líneas no revela su contenido.

### Lo que se sube

El archivo **tal cual**, sin filtrar. El módulo ya quita las claves `MACSS_DEPLOY_*` al instalar
el release; filtrarlas al publicar crearía dos configuraciones distintas para el mismo entorno.

## Consequences

- **CI puede desplegar las tres capas sin perder el rollback.** Es el objetivo original, y era
  el único que había.
- **Actualizar la configuración de producción pasa a ser un acto deliberado y registrado:**
  editas tu archivo, corres `Publish-EnvSecret -Apply`, y queda en el historial del environment.
  Antes se colaba dentro de un despliegue cualquiera.
- **Hay una tercera copia del secreto** (máquina, servidor, GitHub). El runner es propio, así
  que el archivo temporal se materializa en infraestructura de la organización, pero la copia en
  GitHub es real y hay que contarla al evaluar el riesgo.
- **La configuración sigue sin ser auditable en contenido.** Se sabe *cuándo* cambió y *quién* lo
  publicó, no *qué* cambió. Versionar configuración cifrada es otro problema.
- **La ADR 0014 no se revierte.** `.env` como `sharedPath` sigue disponible y probado, y es
  razonable donde cambiar configuración sin release importe más que el rollback por versión. Deja
  de ser lo recomendado para componentes con rollback, que hoy son todos los de `impulsa`.
