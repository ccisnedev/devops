# ADR 0016: El despliegue de base de datos no administra las opciones de la instancia

**Status:** Accepted (2026-08-18)

## Context

La [ADR 0013](0013-deploy-does-not-manage-instance-accounts.md) trazó una frontera: el despliegue
administra el esquema de la aplicación, las **cuentas** de la instancia las administra el DBA. La
frontera era correcta y estaba incompleta. Faltaba la otra mitad de lo que pertenece a la
instancia: sus **opciones de base de datos**.

`sqlpackage` trae `ScriptDatabaseOptions` **activo por omisión**. Con esa opción, antes de tocar
una sola tabla, compara las opciones de base de datos del modelo contra las del servidor y emite un
`ALTER DATABASE` por cada diferencia: modelo de recuperación, nivel de compatibilidad, collation,
`AUTO_CLOSE`, `AUTO_SHRINK`, y el resto del conjunto.

Un proyecto de base de datos casi nunca declara esas opciones. No las declara porque no son suyas.
Pero el `.dacpac` no distingue entre "no lo declaro" y "no me importa": emite el **default de
DacFx**. Para el modelo de recuperación, ese default es `FULL`.

### El dato

El DBA reportó el 2026-08-17:

> El miércoles coloqué esas BD en modo SIMPLE, y hoy reviso que se cambiaron a FULL.
> `ALTER DATABASE [TIGRE] SET RECOVERY FULL WITH ROLLBACK IMMEDIATE`

Apuntaba al usuario con el que corren nuestros despliegues. Tenía razón. El script generado por
nuestro propio proyecto (`pyme`, 2026-06-14) lo declara en su primera sentencia útil, antes de
cualquier cambio de esquema:

```sql
IF EXISTS (SELECT 1 FROM [master].[dbo].[sysdatabases] WHERE [name] = N'$(DatabaseName)')
    BEGIN
        ALTER DATABASE [$(DatabaseName)]
            SET RECOVERY FULL
            WITH ROLLBACK IMMEDIATE;
    END
```

Son dos daños, no uno:

1. **Revierte la política de respaldo del DBA.** Quien dimensiona los backups de log, el disco y la
   ventana de recuperación es él. Un despliegue de esquema se la deshacía cada vez.
2. **`WITH ROLLBACK IMMEDIATE` corta las transacciones abiertas de la aplicación.** No es un efecto
   secundario del cambio de opción: es su forma de aplicarse. El despliegue empezaba matando
   sesiones de producción.

### Por qué pasaron meses sin que nadie lo viera

Éste es el punto que separa esta ADR de la 0013, y la razón por la que merece una propia.

En la 0013 el fallo **estaba en el plan**: el `Drop` de siete usuarios se declaraba, mezclado entre
diecinueve líneas de cambios esperados. La conclusión de entonces fue que un aviso junto a mucho
ruido no es un aviso.

Acá es peor. El `DeployReport` —nuestro dry-run, el artefacto que una persona revisa antes de
confirmar— **no lo declara en absoluto**. El reporte de `tigre` del 2026-08-14, generado contra
producción, es íntegramente esto:

```xml
<DeploymentReport xmlns="..."><Alerts /></DeploymentReport>
```

Vacío. El `ALTER DATABASE` sólo aparece si se pide el `.sql` con `-Script`, que no es el paso que
la gente da antes de aprobar. Durante meses la compuerta de revisión mostró un plan limpio de un
despliegue que empezaba cambiando la política de respaldo y matando transacciones.

**Una compuerta sólo protege de lo que muestra.** El `DeployReport` no es una descripción completa
de lo que el despliegue hace, y tratarlo como si lo fuera fue el error de fondo.

### Lo que ya estaba a mano

Varios `.sqlproj` declaran `DefaultCollation` con un comentario que explica que sin esa línea el
`.dacpac` emite el default de DacFx, que no es la collation de la base. Es el mismo mecanismo,
encontrado antes, y resuelto declarando el valor correcto en vez de apagar la comparación. La
solución local funcionaba y no generalizaba la regla: cada opción de base de datos había que
descubrirla, una por una, cuando explotara.

Los perfiles `.publish.xml` heredados traen listas largas de `ExcludeAudits`, `ExcludeCredentials`,
`ExcludeEndpoints`, `ExcludeLogins`, `ExcludeLinkedServers`, `ExcludeServerRoles`. Alguien ya había
trazado esta frontera antes; la migración a `sqlpackage.yaml` la perdió.

## Decision

**El despliegue administra el esquema de la aplicación; la configuración de la instancia la
administra el DBA.** Las cuentas (ADR 0013) y las opciones de base de datos (ésta) son dos caras de
la misma regla.

La plantilla de `-Init` pasa a generar:

```yaml
ScriptDatabaseOptions: false
```

Con `false`, `sqlpackage` no emite ningún `ALTER DATABASE` y despliega sólo esquema. El modelo de
recuperación, el nivel de compatibilidad, la collation y el resto de opciones quedan donde
corresponde.

No es una mitigación parcial: es la propiedad que gobierna el conjunto entero. No hace falta
enumerar qué opciones proteger ni descubrirlas de a una.

Un proyecto que **sí** sea dueño de su instancia —una base que el repositorio crea y administra de
punta a punta— puede quitar la línea deliberadamente y dejar constancia. La plantilla fija el
default seguro, no la única opción.

### Efecto sobre `DefaultCollation`

La línea `DefaultCollation` de los `.sqlproj` deja de ser lo que sostiene esa protección: con
`ScriptDatabaseOptions: false` no hay comparación de collation que emitir. Se mantiene porque sigue
siendo el valor correcto del modelo y porque afecta cómo DacFx resuelve el esquema, pero ya no es
un parche contra un `ALTER DATABASE`.

## Consequences

- Un `-Init` nuevo nace protegido. Igual que en la 0013, la corrección no depende de que alguien
  lea el plan con cuidado —y acá no podría, porque el plan no lo muestra.
- Los repositorios existentes **no** se corrigen solos. Al 2026-08-18 se corrigieron cuatro
  (`impulsa`, `micro`, `pyme`, `tigre`); quedan 16 `sqlpackage.yaml` versionados sin la propiedad.
- El proyecto pierde la capacidad de fijar opciones de base de datos de forma declarativa. Es una
  pérdida real y es el precio: cambiar el modelo de recuperación pasa a ser una tarea del DBA. A
  cambio, ningún despliegue de esquema puede alterar la política de respaldo ni cortar sesiones.
- Queda pendiente un problema que esta ADR **no** resuelve: el `DeployReport` no describe todo lo
  que el despliegue hace. Apagar `ScriptDatabaseOptions` quita esta omisión concreta, no la clase
  entera. Cualquier propiedad futura que actúe fuera del esquema volverá a ser invisible en la
  compuerta.

## Cómo verificarlo en un repositorio existente

El `-Plan` **no** sirve acá: es precisamente lo que no lo muestra. Hay que pedir el script.

```powershell
Invoke-SqlPackage -Script -EnvFile .env.production
```

Y buscar en el `.sql` generado:

```
ALTER DATABASE [...] SET RECOVERY
```

Si aparece, el proyecto tiene la exposición.

La verificación del lado del servidor, que es la que cierra el caso con el DBA, la corre él porque
requiere `sysadmin`:

```sql
EXEC xp_readerrorlog 0, 1, N'Setting database option RECOVERY';
```

SQL Server registra cada cambio de modelo de recuperación con su hora. Si no hay ninguno con la
hora de un despliegue, la frontera se está respetando.
