# ADR 0012: Una deprecación falla con instrucciones; no avisa y continúa

**Status:** Proposed (2026-08-04)
**Alcance:** política del módulo. Aplica a toda deprecación existente y futura.
**Relacionado:** ADR 0010 §5 fijó este criterio para el destino de despliegue; este ADR lo
generaliza. Supersede el mecanismo de aviso de ADR 0002 y de la deprecación de
`Publish-FlutterWebLegacy` (5.6.0).

## Context

El módulo tiene cuatro deprecaciones blandas: emiten un aviso y siguen funcionando.

| # | Qué está deprecado | Desde | Reemplazo | Cómo avisa |
|---|---|---|---|---|
| D1 | `-Publish` / `-DeployReport` | ADR 0002 | `-Apply` / `-Plan` | `Write-Warning` en `Publish-NodeApi`, `Publish-FlutterWeb`, `Invoke-SqlPackage` |
| D2 | `deploy.yaml` | — | `publish.yaml` | `Write-Host` amarillo, en cuatro sitios |
| D3 | `Publish-FlutterWebLegacy` | 5.6.0 | `Publish-FlutterWeb` | `Write-Warning` |
| D4 | `MACSS_DEPLOY_SERVER`, `server:` | ADR 0010 | `MACSS_DEPLOY_SSH_ALIAS` | falla (ya bajo esta política) |

**La evidencia de que el aviso no funciona está en la propia suite.** Correr los tests imprime el
warning de D1 decenas de veces. Un mensaje que aparece constantemente deja de leerse: es
indistinguible del ruido de fondo, y el consumidor aprende a filtrarlo antes que a migrar.

D2 es peor todavía: usa `Write-Host`, así que ni siquiera se captura con `-WarningVariable` ni
aparece como advertencia en un log de CI. Es un aviso que solo existe si alguien está mirando la
pantalla en ese momento.

El resultado es predecible: nadie migra lo que no le impide trabajar. La deprecación blanda no
retrasa la ruptura, la vuelve permanente — y además obliga a mantener dos caminos de código
indefinidamente, que es el costo que la deprecación pretendía evitar.

## Decision

### 1. Una deprecación falla

Cuando el módulo detecta un uso deprecado, **lanza**. No avisa, no continúa, no degrada. El mensaje
debe bastar para migrar sin abrir la documentación: qué se usó, desde cuándo está retirado, qué usar
en su lugar, y dónde está la decisión.

```
Publish-NodeApi: '-Publish' se retiró en 6.0.0.
  Use '-Apply' en su lugar.
  Ver ADR 0002.
```

La forma la produce un único helper, `Deny-DeprecatedUsage`, para que ningún mensaje quede a
criterio de quien escribe el `throw`.

### 2. Si quedan llamadores se falla; si no quedan, se borra

El fallo instructivo existe para **quien todavía usa lo deprecado**. Si nadie lo usa, mantener el
andamiaje solo para explicarle algo a nadie es la deuda que este ADR combate, con otro disfraz.

La regla es por evidencia, no por calendario: **se busca el uso real antes de decidir.**

| Mecanismo | Llamadores encontrados | Decisión en `6.0.0` |
|---|---|---|
| `Publish-FlutterWebLegacy` | ninguno | **borrar** |
| `-Publish` / `-DeployReport` | 4, ya migrados | **borrar** |
| `deploy.yaml` | fixtures de test y repos consumidores | fallar con instrucciones |
| `MACSS_DEPLOY_SERVER`, `server:` | 16 env files en 8 repos | fallar con instrucciones |

Para los dos primeros, la búsqueda encontró exactamente cuatro sitios —tres plantillas de
organización y el workflow de `retiro`— y se migraron a `-Apply -AutoApprove` **antes** de tocar el
módulo. Un quinto sitio aparente resultó ser un repositorio archivado, que no ejecuta workflows.

Migrar primero y borrar después es lo que permite el borrado limpio: sin llamadores, el
*"A parameter cannot be found that matches parameter name 'Publish'"* que produciría PowerShell no
le llega a nadie.

**Corolario para el futuro:** antes de retirar algo deprecado se busca su uso. Si aparece, se falla
con instrucciones y se migra a los llamadores; el borrado espera. Si no aparece, se borra.

### 3. `deploy.yaml` deja de ser un fallback

`Resolve-PublishConfigPath` seguirá detectando `deploy.yaml` para poder nombrarlo en el mensaje,
pero los cmdlets **fallan** en lugar de leerlo. El aviso pasa de `Write-Host` a excepción, con lo
que además se vuelve visible en CI.

### 4. Dos releases, como ADR 0010 y ADR 0011

| Release | Qué hace |
|---|---|
| **6.0.0** | Se borra lo que no tiene llamadores (`Publish-FlutterWebLegacy`, alias `-Publish`/`-DeployReport`). Lo que sí los tiene pasa a fallar con instrucciones. |
| **6.1.0** | Se borra el andamiaje restante: detección de `deploy.yaml`, de `MACSS_DEPLOY_SERVER` y de `server:`, con sus mensajes y sus tests. |

Registrado en `docs/roadmap.md`. El riesgo de esta política es dejar el andamiaje puesto para
siempre, que sería la misma deuda con otro disfraz.

### 5. Toda deprecación futura nace bajo esta regla

No se introduce una deprecación blanda "por ahora". Si algo se deprecia, se deprecia fallando desde
la primera versión que lo declare, y se agenda su retiro en el roadmap en el mismo commit.

## Testable requirements

**U** = Pester unit, **S** = suite.

- **REQ-1 (U)** `Deny-DeprecatedUsage` produce un mensaje que contiene: el cmdlet, el elemento
  deprecado, el reemplazo y la versión de retiro.
- **REQ-2 (U)** Los alias `-Publish` y `-DeployReport` **ya no están declarados** en
  `Publish-NodeApi`, `Publish-FlutterWeb` ni `Invoke-SqlPackage`.
- **REQ-3 (U)** `-Plan` y `-Apply` siguen siendo los modos vigentes, con `-AutoApprove` sobre
  `-Apply`: el borrado del alias no altera la taxonomía de ADR 0002.
- **REQ-4 (U)** Un proyecto con `deploy.yaml` y sin `publish.yaml` **falla**; el mensaje nombra
  ambos archivos.
- **REQ-5 (U)** `Publish-FlutterWebLegacy` no existe: ni como función exportada, ni en el manifiesto,
  ni como archivo en `Functions/`.
- **REQ-6 (U)** Ningún `Write-Warning` ni `Write-Host` de deprecación queda en `Functions/` ni en
  `Private/`: la única vía es la excepción.
- **REQ-7 (S)** La salida de la suite deja de contener avisos de deprecación repetidos.

## Consequences

- **La migración ocurre.** El costo se paga una vez, con instrucciones en pantalla, en lugar de
  arrastrarse indefinidamente.
- **Un solo camino de código por decisión.** Desaparece el mantenimiento del camino viejo.
- **`6.0.0` acumula cuatro rupturas** (ADR 0010, 0011 y esta). Es deliberado: quien tenga que tocar
  sus invocaciones y sus env files, que los toque una sola vez.
- **Se modifican tests que hoy pasan.** `PublishNodeApi.Taxonomy`, `PublishFlutterWeb.Taxonomy`,
  `InvokeSqlPackage.Taxonomy` y `Publish-FlutterWeb.Tests` afirman el contrato blando; codifican la
  decisión anterior y se reescriben con la nueva. Queda dicho aquí para que el cambio de un test
  verde sea trazable a una decisión y no parezca un ajuste para que pase la suite.
- **Riesgo asumido:** un consumidor con un script desatendido verá el fallo en ejecución, no antes.
  Es el precio de que el aviso previo no se leyera; el mensaje lleva la corrección exacta.
