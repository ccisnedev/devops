# ADR 0013: El despliegue de base de datos no administra las cuentas de la instancia

**Status:** Proposed (2026-08-05)

## Context

`Invoke-SqlPackage -Init` genera un `sqlpackage.yaml` con tres propiedades pensadas para que el
repositorio sea la fuente de verdad del esquema:

```yaml
DropObjectsNotInSource: true
DropPermissionsNotInSource: true
DropRoleMembersNotInSource: true
```

La intención es correcta para tablas, vistas y procedimientos. El problema es el alcance: para
SqlPackage, los **usuarios de base de datos, sus membresías de rol y sus permisos** son objetos
como cualquier otro. Si no están en el modelo, se eliminan.

Y no están en el modelo casi nunca. Un proyecto de base de datos declara las cuentas de servicio
que la aplicación necesita; las cuentas nominales de personas y las de otras integraciones las crea
el DBA directamente en el servidor. Esa asimetría convierte una configuración razonable en una
trampa.

### El dato

Al agregar tres columnas a una tabla en el repositorio `fotos` (2026-08-05), el plan contra
**producción** contenía esto:

```
Alter  → [metadata].[Archivo]              <- el cambio buscado
Drop   → [uu_tigre]  [MCP_SQL]  [EBECERRA]
Drop   → [CACSI\72008307]  [CACSI\74499889]  [CACSI\75554913]  [CACSI\promero]
Drop   → db_datareader / db_datawriter de esas cuentas (12)
Drop   → 8 permisos
```

Siete usuarios, de los cuales **dos eran cuentas de servicio en uso**: `uu_tigre` (el acceso de un
consumidor) y `MCP_SQL` (con la que una API lee una base histórica). El proyecto llevaba meses con
esa configuración; sólo no había explotado porque no se había desplegado desde que esas cuentas
existen.

El fallo es especialmente traicionero porque **el plan lo declaraba**. No estaba oculto: estaba
mezclado entre los cambios esperados, en una lista que se lee por encima buscando el `Alter` que uno
fue a buscar. Un aviso que aparece junto a diecinueve líneas de ruido no es un aviso.

De cinco repositorios auditados, cuatro tenían la exposición y ninguno la había advertido.

### Lo que ya estaba a mano

La plantilla exceptuaba `Logins` en algún proyecto (`DoNotDropObjectTypes: Logins`), señal de que
el problema se había encontrado antes —a nivel de servidor— y se había resuelto sólo para ese tipo,
sin generalizar la regla al resto de las cuentas.

## Decision

**El despliegue administra el esquema de la aplicación; las cuentas de la instancia las administra
el DBA.** La plantilla de `-Init` pasa a generar:

```yaml
DropObjectsNotInSource: true
DropPermissionsNotInSource: false
DropRoleMembersNotInSource: false
DoNotDropObjectTypes: "Logins;Users"
```

Las tres líneas son una sola decisión y se aplican juntas. Proteger al usuario sin proteger sus
permisos y sus roles lo deja sin acceso igual: la cuenta sobrevive vacía. Cualquier subconjunto de
las tres da una falsa sensación de seguridad.

Esto **sólo bloquea el `DROP`**. El proyecto sigue creando y actualizando las cuentas de servicio
que sí declara en su modelo; el patrón de crear el login y el usuario de la aplicación desde el
repositorio, con su contraseña inyectada por variable SqlCmd, no cambia.

Un proyecto que sí modele sus cuentas y quiera que el despliegue las administre puede quitar las
tres líneas, deliberadamente y dejando constancia. La plantilla fija el default seguro, no la
única opción.

### Dos restricciones de sqlpackage que la plantilla debe respetar

Ambas se descubrieron aplicando la decisión, y ambas fallan el despliegue entero:

1. `DoNotDropObjectTypes` **sólo es válida si `DropObjectsNotInSource` es `true`**. Con `false`:
   *"The property DoNotDropObjectTypes may only be set when DropObjectsNotInSource is set to true"*.
   Un proyecto que no borre objetos expresa la política sólo con las dos primeras propiedades.
2. `RoleMembership` **no puede ir en `DoNotDropObjectTypes`** mientras `DropRoleMembersNotInSource`
   sea `true`: *"DropRoleMembersNotInSource conflicts with the selected DoNotDropObjectType
   RoleMembership"*. Son dos formas de expresar lo mismo; se usa el switch dedicado.

Hay un test que impide que la plantilla vuelva a generar cualquiera de esas dos combinaciones.

## Consequences

- Un `-Init` nuevo nace protegido. La corrección no depende de que alguien lea el plan con cuidado.
- Los repositorios existentes **no** se corrigen solos: la plantilla sólo aplica a proyectos
  nuevos. Hay que revisar los `sqlpackage.yaml` ya versionados uno por uno.
- El proyecto pierde la capacidad de revocar permisos de forma declarativa. Es una pérdida real y
  es el precio de la decisión: revocar un permiso pasa a ser una tarea del DBA. A cambio, ningún
  despliegue de esquema puede cortar un acceso de producción.
- La frontera queda explícita en un archivo versionado, que es donde un DBA la puede leer sin
  preguntar.

## Cómo verificarlo en un repositorio existente

`-Plan` alcanza: si aparece cualquier `Drop` de un usuario, un rol o un permiso, el proyecto tiene
la exposición.

```powershell
Invoke-SqlPackage -Plan                           # contra .env
Invoke-SqlPackage -Plan -EnvFile .env.production  # contra produccion
```

Conviene hacerlo contra **producción** además de desarrollo: las cuentas que existen en cada
servidor son distintas, y la de producción es la que duele.
