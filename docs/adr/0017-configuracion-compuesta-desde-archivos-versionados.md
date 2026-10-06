# ADR 0017: El `.env` se compone desde un archivo versionado y un archivo de secretos

**Status:** Accepted (2026-09-20)

**Acota:** la [ADR 0004](0004-deploy-target-from-env-file.md) en dos consecuencias y resuelve sus
dos puntos diferidos.
**Relacionada con:** [ADR 0015](0015-env-file-reaches-ci-as-an-environment-secret.md) (el env file
llega a CI como secret del environment), [ADR 0014](0014-runtime-config-lives-on-the-server.md)
(el contrato de claves), [ADR 0012](0012-deprecations-fail-loudly.md) (deprecar en voz alta),
[ADR 0009](0009-deploy-plan-artifact-and-apply-parity.md) (el plan y el apply dicen lo mismo), ADR
0013 del handbook (la norma: qué se versiona y qué no) y ADR 0009 de `macss` (*a default may
derive, but never invent*).

Esta ADR registra la **mecánica**. La norma —qué cuenta como secreto, qué archivos existen y qué
se versiona— vive en la ADR 0013 del handbook.

## Contexto

El env file gitignoreado hace tres trabajos con ciclos de vida distintos: nombra el destino del
despliegue, lleva la configuración de runtime de la aplicación, y lleva los secretos. Al vivir
juntos, el archivo hereda la restricción más dura de los tres y queda fuera de git.

Medido sobre el componente piloto, 44 claves: **33 valen lo mismo en los tres entornos** y solo 11
varían. Nueve son secretos. Es decir, la mayor parte de lo que está fuera de git no es secreto ni
personal: es configuración del producto que existe únicamente en portátiles.

El coste concreto tiene dos caras. Una es la que la ADR 0015 dejó anotada como hueco abierto: «la
configuración sigue sin ser auditable en contenido». La otra es peor y menos visible: **el secreto
tiene hoy el ciclo de vida de la configuración**. Cambiar un número de reintentos obliga a
republicar con `Publish-EnvSecret` un blob que contiene ocho contraseñas, desde una máquina que las
tiene todas en claro.

La ADR 0004 dejó diferido el *layering* de archivos «à la dotenv-flow». Se descarta esa mecánica
concreta —no la separación— por una razón que la ADR 0011 del handbook ya había hecho explícita:
la precedencia entre archivos obliga a contestar «¿de qué archivo salió este valor?» en cada
incidente, y esa ADR exige imprimir el origen de cada valor resuelto precisamente porque la
precedencia silenciosa es el riesgo real. Cuatro archivos que pueden definir la misma clave son
cuatro respuestas posibles.

## Decisión

### 1. Dos archivos por entorno, en dos carpetas

```
env/                      versionado
  base.env                contrato de claves
  <entorno>.env           configuración completa del entorno + MACSS_DEPLOY_*
secret/                   ignorado (/secret/ y *.secret en .gitignore)
  <entorno>.secret        solo las claves declaradas @secret
.env                      ignorado, generado, derivado. Nunca una fuente.
```

El entorno va **delante** del sufijo. No es estética: el `.gitignore` habitual de estos proyectos
contiene `.env.*` con `!.env.example`, y verificado con `git check-ignore -v`, un
`env/.env.production` quedaría ignorado por esa regla mientras que `env/production.env` no. Así la
adopción es aditiva: se añade `/secret/` y `*.secret`, y **no se modifica ninguna regla existente**.

### 2. La composición es completado, no precedencia

En el archivo versionado, una clave secreta se declara como un hueco explícito:

```ini
DB_PASSWORD=@secret
```

De ahí se sigue la propiedad que justifica toda la decisión: **el conjunto de claves con valor de
`env/` y el de `secret/` son disjuntos por construcción**. La pregunta «qué archivo gana» no llega a
plantearse, porque ningún archivo define una clave que el otro también defina. El `.env` es la suma
de dos mitades que no se solapan.

El centinela es `@secret` y no `${secret}` porque la ADR 0011 del handbook §1 prohíbe la
interpolación: usar la sintaxis prohibida como marca reservaría para esto la forma que un expansor
futuro se comería. Tampoco es la cadena vacía: en el componente piloto hay al menos una clave donde
el valor vacío **ya significa algo**, así que el vacío no está disponible como marca.

La única precedencia que se conserva es la de la ADR 0011 del handbook §2: **el entorno del proceso
gana sobre el archivo**, y el valor resuelto se imprime siempre con su origen.

### 3. `-Environment <nombre>` es obligatorio y selecciona los dos archivos

```powershell
Publish-NodeApi -Environment uat -Plan
Publish-NodeApi -Environment production -Apply
```

Resuelve `env/<nombre>.env` + `secret/<nombre>.secret` y compone el `.env` que se despliega.

**No hay entorno por defecto.** Un `-Apply` sin `-Environment` no elige uno: falla nombrando los
entornos disponibles, que son los archivos presentes en `env/`. Es la ADR 0009 de `macss` aplicada
literalmente — «nada — lo elige él» es la casilla prohibida — y conserva la propiedad que la ADR
0004 llamaba *safer default*: producción nunca se alcanza sin nombrarla.

El **destino sigue declarado dentro** de `env/<nombre>.env`, en `MACSS_DEPLOY_SSH_ALIAS`. El nombre
del entorno **no** se usa como alias SSH: medido en el proyecto piloto, las capas de un mismo
proyecto apuntan a destinos distintos, y una de ellas no usa SSH en absoluto. La correspondencia no
es 1:1, así que deducirla sería inventar el valor.

### 4. `-Materialize` compone en local, y no pisa lo que no escribió

El mismo mecanismo sirve a la máquina del desarrollador: compone `.env` desde
`env/development.env` + `secret/development.secret`. La paridad manual/CI —la propiedad más valorada
del módulo, y la que la ADR 0009 protege— se conserva porque no hay dos caminos, hay uno.

El `.env` generado lleva una **cabecera de procedencia**, y el composer **se niega a sobrescribir un
`.env` que no la tenga**: un archivo sin cabecera es el de alguien que lo escribió a mano, y
pisarlo silenciosamente destruiría la única copia. `-Force` lo permite explícitamente. Es el trato
de la ADR 0012: fallar en voz alta antes que actuar por suposición.

### 5. Lo que el plan imprime

`-Plan` no puede seguir diciendo solo el destino. Con dos archivos por entorno debe decir, sin
imprimir jamás un valor secreto:

| Qué | Por qué |
|---|---|
| El entorno, y los dos archivos resueltos por nombre | Es el selector; tiene que estar a la vista |
| El destino **y de qué archivo salió** | Ya lo exige la ADR 0011 del handbook §2 |
| Cuántas claves aporta cada mitad, y cuántas faltan | Detecta un `secret/` incompleto antes del apply |
| Estado del contrato contra `base.env` | Segunda etapa |

### 6. El secreto llega a CI como un secret aparte

`Publish-EnvSecret` gana un secret nuevo, `SECRET_FILE_<COMPONENTE>`, **junto al** `ENV_FILE_<COMPONENTE>`
que ya existe. No se renombra ni se reutiliza el existente: mientras la adopción esté en curso,
los dos caminos coexisten y el workflow actual sigue funcionando sin cambios.

El runner compone igual que una máquina: materializa `secret/<entorno>.secret` desde el secret del
environment e invoca el mismo cmdlet con el mismo `-Environment`. El servidor sigue recibiendo **un
solo `.env` completo por release**, así que el rollback por versión que la ADR 0015 protege queda
intacto.

**El orden de las claves del `.env` compuesto es determinista**, y la composición debe dar un
archivo byte a byte idéntico al que se desplegaba antes. Si no, la huella SHA-256 que la ADR 0015
publica como variable del environment cambiaría sin que la configuración haya cambiado, y dejaría de
significar lo que dice significar.

## Modos de fallo

Todos bloquean con mensaje accionable que nombra la clave o el archivo. Ninguno cae a un valor por
defecto.

| Situación | Resultado |
|---|---|
| Falta `-Environment` | Error, nombrando los entornos disponibles en `env/` |
| No existe `env/<nombre>.env` | Error, nombrando la ruta esperada |
| No existe `secret/<nombre>.secret` y hay claves `@secret` | Error, nombrando las claves sin completar |
| Una clave `@secret` no aparece en el archivo de secretos | Error, nombrando la clave |
| El archivo de secretos aporta una clave que nadie declaró | Error: o sobra, o falta declararla |
| No hay `MACSS_DEPLOY_SSH_ALIAS` y el cmdlet lo necesita | Error, como hoy |
| El `.env` existe sin cabecera de procedencia | Error; `-Force` lo permite |
| Un valor literal donde el contrato dice `@secret` | Segunda etapa, y el control va en CI |

Ese último caso merece una nota: el momento peligroso es el **commit**, no el despliegue. Un check
en el apply llegaría cuando el secreto ya está en la historia de git, que es el único error de toda
esta familia que no se puede deshacer. Su sitio es un workflow, no el cmdlet.

## Adopción

Aditiva hasta el último paso, y en este orden:

1. Añadir `env/` y añadir `/secret/` + `*.secret` al `.gitignore`. No rompe nada.
2. Partir el archivo actual en las dos mitades y verificar que la composición es **byte a byte** la
   de hoy, con orden determinista.
3. Componer en local con `-Materialize` y desplegar a un entorno que no sea producción por el camino
   nuevo. El secret existente no se toca.
4. Publicar `SECRET_FILE_<COMPONENTE>` junto al que ya existe.
5. **Solo entonces**, cambiar el workflow para que componga. Es el único paso no aditivo, y va al
   final, cuando 1–4 estén verdes.

Un componente piloto y un entorno no productivo primero. La degradación es limpia: un proyecto sin
`env/` se comporta como hoy, así que la migración es opt-in por proyecto.

## Consecuencias

- **Un entorno nuevo pasa a ser una PR.** La ADR 0004 contaba lo contrario como ventaja. Es un
  cambio de criterio deliberado: la fricción de una revisión se paga a cambio de que la
  configuración de cada entorno sea auditable. Lo que sigue sin necesitar PR es `secret/`.
- **Se cierra el hueco que la ADR 0015 dejó con nombre propio.** La configuración pasa a ser
  auditable en contenido, y el diff de una PR muestra qué cambió, cuándo y quién.
- **Se reduce de tres a dos el número de copias del secreto** que la ADR 0015 anotó (máquina,
  servidor, GitHub): la copia de la máquina pasa a contener solo secretos, y deja de republicarse
  cada vez que cambia una variable que no lo es.
- **El contrato de la ADR 0014 no se rompe, y de hecho empieza a servir.** Hoy está dormido: la
  verificación está guardada por `if ($envEsShared)` y ningún proyecto declara `.env` en
  `sharedPaths`. Un archivo versionado que lleva todas las claves lo deja funcionar sin
  modificarlo, porque compara **nombres**, no valores.
- **`Read-DotEnv` sigue siendo el único parser**, y la composición se implementa ahí. Los tres
  `Publish-*`, `Invoke-SqlPackage` e `Invoke-PgSchema` lo heredan sin tocarlos.
- **No hace falta un resolvedor por lenguaje.** La composición ocurre al desplegar, no en runtime,
  así que la aplicación sigue leyendo un solo `.env` con la librería dotenv estándar de su
  lenguaje. Tres implementaciones del mismo resolvedor serían tres oportunidades de divergir.
- **Queda fuera, para una segunda etapa:** la verificación bidireccional del contrato de
  `base.env` (que falte bloquea y que sobre también), el check de CI del valor literal, la
  abstracción de proveedor de secretos, y las apps Flutter con su relación entorno → *flavor*.
  Durante esa etapa `.env.example` convive con `base.env` como una tercera copia del conjunto de
  claves: deuda aceptada a sabiendas.
- **La exclusión de `MACSS_DEPLOY_*` del contrato pasa a ser una regla explícita.** Hoy funciona
  por coincidencia: el ejemplo omite la clave y el archivo del servidor la tiene filtrada, así que
  la diferencia no se nota. Al comparar el archivo del entorno contra el contrato, esa clave
  registraría como «sobra» y se bloquearía a sí misma. `Remove-DeployOnlyEnvKeys` ya sabe filtrar
  por ese prefijo; el contrato tiene que usar el mismo criterio.
