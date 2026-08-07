# La configuración de entorno no existe fuera de la máquina del operador

**Estado:** propuesta · **Abierto:** 2026-08-07
**Afecta a:** toda la familia de deploy. Bloquea `deploy.api.yml` y `deploy.web.yml`
de `cacsi-dev/.github`, que hoy no son ejecutables.

## Estado actual

El env file gitignored (`.env` / `.env.production`) hace **dos trabajos distintos**:

1. **Nombra el destino** — `MACSS_DEPLOY_SSH_ALIAS`, que `Resolve-DeployTargetFromEnv`
   lee para saber a qué servidor ir.
2. **Es la configuración de runtime de la app** — todo lo demás, que `Publish-NodeApi`
   sube al servidor como el `.env` del release.

Los dos trabajos viven en el mismo archivo, y el despliegue separa uno del otro justo
antes de subirlo (`Publish-NodeApi.ps1:471`):

```powershell
$envContent = (Remove-DeployOnlyEnvKeys -Lines @(Get-Content $envProdPath)) -join "`n"
# → "  .env.production subido como .env (LF, sin MACSS_DEPLOY_*)"
```

`Remove-DeployOnlyEnvKeys` filtra por el prefijo `MACSS_DEPLOY_`: lo que queda es la
config de la app, y es lo que corre en producción.

### El archivo está gitignored, así que en CI no existe

Tras `actions/checkout` no hay `.env` ni `.env.production`. Y la resolución del destino
no cae a variables de proceso (`Private/PublishHelpers.ps1`):

```powershell
$vars = @{}
if (Test-Path -LiteralPath $envPath) { $vars = (Read-DotEnv -Path $envPath).Env }
$alias = if ($vars['MACSS_DEPLOY_SSH_ALIAS']) { ... } else { '' }

if (-not $alias) {
    throw "${Cmdlet}: no hay destino de despliegue. Falta 'MACSS_DEPLOY_SSH_ALIAS' en '$EnvFile'."
}
```

Las plantillas de workflow no tienen ningún paso que cree ese archivo. El resultado es
que un job de deploy falla en la primera línea útil, con el mismo error que produjo el
runner al sobrescribir su `.env`.

Esto no se había manifestado porque **ningún repositorio ejecuta esas plantillas**. De
los 104 repos activos de la organización, el único workflow de deploy vivo
(`fintechgabinete_client`) es `scp`/`ssh` a mano y no usa el módulo.

### Reparto por cmdlet

| Cmdlet | Necesita el destino | Necesita subir config de runtime |
|---|---|---|
| `Publish-FlutterWeb` | sí | **no** — sirve archivos estáticos |
| `Publish-NodeApi` | sí | **sí** — siempre sube el env como `.env` del release |
| `Invoke-SqlPackage` | no usa alias SSH | credenciales, hoy vía variables de proceso |
| `Publish-DockerStack` | sí | sí — el `.env` del stack |

Flutter Web solo necesita el trabajo 1. Por eso una app web parece un caso fácil y una
API no lo es.

## Lo que la ADR 0004 ya había decidido

El contexto de la ADR previó explícitamente este escenario:

> *"El alias SSH es machine-local, no portable. `server: pre-prod` en el `publish.yaml`
> versionado nombra un alias que existe solo en el `~/.ssh/config` de un desarrollador.
> En otra máquina **(o en el runner de CI)** ese mismo entorno se alcanza con un alias
> distinto."*

Dos consecuencias:

- Que el runner llame `app-server` a lo que una laptop llama `prod` **no es un defecto**:
  es el diseño. Cada ejecutor nombra el destino a su manera, y por eso el repo no puede
  cargarlo.
- Pero los análogos que la propia ADR eligió —`kubectl --context prod`,
  `docker --context`, `cap production deploy`, `terraform -var-file`— toman el entorno
  como **argumento explícito de invocación**. Aquí el entorno se expresa como una *ruta
  de archivo* (`-EnvFile .env.production`). El archivo es a la vez el selector del
  entorno y el contenido de la config.

La ADR resolvió dónde **no** debía estar el destino. No resolvió de dónde lo toma un
ejecutor que no es una persona con su `~/.ssh/config`.

## Los dos problemas, que son distintos

### 1. El destino — pequeño y reversible

Tres formas de que un job sepa a dónde va:

| | Qué implica | Coste |
|---|---|---|
| El workflow escribe el env file | El paso crea `.env` desde una variable de Actions | 3 líneas. Contradice el 12-Factor que la ADR cita: materializa un archivo para leerlo de vuelta |
| Fallback a variable de proceso | `$env:MACSS_DEPLOY_SSH_ALIAS` cuando no hay archivo | Release menor + enmienda a la ADR. Es la semántica dotenv habitual |
| Entorno como argumento explícito | `-Environment prod`, y la conexión sale del registro local | Cambia la firma de toda la familia. Es lo que hacen los análogos citados por la ADR |

### 2. La configuración de runtime — el problema real

La config con la que corre producción vive **solo** en la máquina del operador que
desplegó por última vez. De ahí se derivan cuatro cosas, y ninguna es sobre CI:

- Nadie puede decir con qué configuración corre producción hoy.
- No es recuperable si esa máquina se pierde.
- No es auditable: no hay registro de qué cambió, cuándo ni quién.
- Contradice lo que el handbook afirma sobre no divergir entre lo validado y lo
  desplegado: no hay forma de comparar.

El segundo problema existe con o sin pipeline. La automatización no lo causa; solo lo
hace imposible de ignorar.

## Opciones para la config de runtime

No se propone una aquí; se registran para decidir con el contexto completo.

- **Secrets de GitHub Environments.** Nativo. `environment: production` aporta además
  los gates de aprobación que R05 y R23 ya piden y un historial de despliegues por
  entorno. El límite es el tamaño y el número de secretos, y que editar config de
  producción pasa a ser editar secretos de repo.
- **Gestor de secretos externo.** La respuesta a escala, con rotación y auditoría reales.
  Es infraestructura nueva que hoy no existe.
- **Alcance reducido.** Automatizar `db` y `web` —que no necesitan subir config— y dejar
  las APIs en despliegue manual hasta resolverlo. Preserva el orden R01 solo si la capa
  manual no queda en medio.

## Preguntas abiertas

1. ¿El entorno pasa a ser argumento explícito (`-Environment prod`) o sigue siendo una
   ruta (`-EnvFile .env.production`)?
2. Si no hay env file, ¿es error o fallback? La ADR 0012 pide fallar fuerte y con
   mensaje; un fallback silencioso puede redirigir un despliegue local sin que nadie lo
   note.
3. ¿Dónde vive la config de runtime de producción, y quién puede leerla?
4. ¿Se adoptan GitHub Environments como mecanismo de los gates R05 y R23?

## Criterio de aceptación

Independiente de qué opción gane:

- [ ] Un job de deploy en CI resuelve su destino sin depender de un archivo ausente
- [ ] `deploy.web.yml` despliega una app real desde el pipeline, de principio a fin
- [ ] `deploy.api.yml` sube una config de runtime que **no** proviene de una laptop
- [ ] La config de producción es consultable sin acceso a la máquina del operador
- [ ] Un destino ausente o ambiguo sigue fallando con mensaje explícito, nunca en silencio
- [ ] El destino resuelto se imprime siempre antes de aplicar (ya se cumple desde 6.2.1)
- [ ] Cubierto por tests: env file presente, ausente, y ambos orígenes en conflicto

## Consecuencias

- **`deploy.api.yml` y `deploy.web.yml` dejan de ser plantillas teóricas.** Hoy están
  publicadas y documentadas como listas para copiar, y no funcionan; el primer equipo que
  las use se encuentra con el fallo.
- La decisión sobre el destino condiciona poco: las tres opciones son baratas y se pueden
  cambiar después. La de la config de runtime condiciona mucho, porque define dónde vive
  el secreto de producción.
- **Afecta al piloto de `impulsa`.** El despliegue ordenado DB → API → UI de la ADR 0010
  del handbook necesita las tres capas automatizadas; la capa API es justamente la que
  depende de esto.
- La documentación de `Publish-NodeApi` sigue diciendo *"Lee publish.yaml para el servidor
  destino"* (`Publish-NodeApi.ps1:26`), que dejó de ser cierto con la ADR 0004. Corregirlo
  es independiente de esta decisión.
