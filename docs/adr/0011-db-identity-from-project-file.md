# ADR 0011: La identidad de la base vive en el archivo de proyecto, no en el env file

**Status:** Proposed (2026-08-04)
**Acompaña a:** ADR 0010 (destino de despliegue). Ambos entran en la release `6.0.0`.

## Context

ADR 0010 ordenó el **destino** de un despliegue: dónde se despliega sale del env file gitignored,
porque un alias SSH o una IP son *binding* y cambian por entorno. Al aplicarlo a los cmdlets de base
de datos apareció que `DB_NAME` está del lado equivocado de esa misma frontera.

### El dato: `DB_NAME` no varía por entorno

Medición sobre los repos de base de datos de la organización:

| `.sqlproj` `<Name>` | `DB_NAME` en `.env` | `DB_NAME` en `.env.production` |
|---|---|---|
| `chatbot` | `chatbot` | `chatbot` |
| `CONTRATOS` | `CONTRATOS` | `CONTRATOS` |
| `dispersion_ligo` | `dispersion_ligo` | — |
| `encuestas` | `encuestas` | — |
| `feature_flags` | `feature_flags` | `feature_flags` |
| `contratos` | `CONTRATOS` | `CONTRATOS` |

**En ningún repo `DB_NAME` difiere entre entornos.** Lo que cambia es `DB_SERVER`. Un valor idéntico
en dos archivos que solo existen para expresar diferencias es identidad duplicada, no configuración
— y duplicar identidad en archivos gitignored es un riesgo de sincronización sin contrapartida.

### El dato ya está en la mano

`Invoke-SqlPackage` **localiza y exige el `.sqlproj`** antes de compilar: el archivo que declara
`<Name>` ya está abierto. Y `sqlpackage`, si no recibe `/TargetDatabaseName`, lo toma del dacpac.
Derivar el nombre no es introducir un mecanismo: es dejar de sobrescribir el comportamiento nativo
de la herramienta con un valor copiado a mano.

### PostgreSQL tiene el mismo archivo, aunque no tenga dacpac

`pgschema` no produce un artefacto compilado que cargue identidad. Pero la identidad no necesita un
binario: necesita un **lugar versionado**. `Invoke-PgSchema` ya lee `pgschema.yaml`, versionado, que
hoy declara la lista de schemas. Es el análogo exacto del `.sqlproj`.

Dejar `PGDATABASE` en el `.env` haría que los dos cmdlets de base de datos tuvieran formas distintas
sin una razón técnica detrás — la clase de divergencia que obliga a recordar excepciones.

## Decision

### 1. La frontera es identidad contra binding

| | Identidad — archivo versionado | Binding — env file gitignored |
|---|---|---|
| SQL Server | `.sqlproj` → `<Name>` | `DB_SERVER`, usuario, contraseña |
| PostgreSQL | `pgschema.yaml` → `database:` | `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` |

El nombre de la base no es *dónde* despliegas: es *qué* despliegas. El env file de un proyecto de
base de datos queda conteniendo solo conexión y credenciales, que es lo que un archivo de secretos
debe contener.

### 2. SQL Server: derivar del `.sqlproj`, con override explícito

El nombre objetivo sale de `<Name>` del `.sqlproj`. `DB_NAME` en el env pasa a ser un **override
explícito**, no la fuente:

| Estado de `DB_NAME` | Comportamiento |
|---|---|
| ausente | se usa `<Name>` del `.sqlproj` |
| presente y **distinto** | se honra como override, y el plan lo muestra **marcado como override** |
| presente e **igual** (ignorando mayúsculas) | **falla**: es duplicación muerta, pide borrarla |
| presente y **difiere solo en mayúsculas** | **falla** pidiendo desambiguar (ver §3) |

El override existe por un caso real: las **DB Tier-1** desechables (`dev_<nombre>`), donde el mismo
dacpac se publica a una base con otro nombre. Derivar a secas eliminaría ese flujo.

Que el override **nunca sea silencioso** es parte de la decisión: aparece en el plan, porque
publicar sobre una base distinta de la que el proyecto declara es exactamente el momento en que
alguien quiere estar seguro de lo que está haciendo.

### 3. El caso ambiguo se resuelve con una persona, no con una regla

`contrato/contratos_db/contratos.sqlproj` declara `<Name>contratos</Name>` y publica hoy sobre
`CONTRATOS`. En una collation case-insensitive da igual; en una case-sensitive, no.

El cmdlet **no elige**. Falla pidiendo desambiguar: si el nombre real de la base es `CONTRATOS`,
corregir `<Name>` en el `.sqlproj`; si no, borrar `DB_NAME`. Adivinar aquí sería cambiar el objetivo
de un despliegue de producción en silencio, que es la clase de cambio que nadie descubre hasta que
duele.

### 4. PostgreSQL: `database:` en `pgschema.yaml`

`pgschema.yaml` gana una clave `database:` junto a la lista de schemas. `PGDATABASE` en el env
**falla** con la instrucción de moverlo, siguiendo el modelo de compatibilidad de ADR 0010 §5.

No hay override aquí: si aparece un caso Tier-1 en PostgreSQL se decidirá entonces, con el caso
delante. Inventar el mecanismo antes que el caso es cómo se acumulan opciones que nadie usa.

### 5. Entra en `6.0.0`, con ADR 0010

No por afinidad conceptual, sino por costo de migración: ADR 0010 ya obliga a recorrer los env files
de cada repo, en cada estación y en cada servidor. Hacer las dos cosas en la misma pasada convierte
dos migraciones manuales en una.

## Testable requirements

**U** = Pester unit, **C** = container, **S** = suite.

- **REQ-1 (U)** `Invoke-SqlPackage` toma el nombre objetivo de `<Name>` del `.sqlproj` cuando el env
  no declara `DB_NAME`.
- **REQ-2 (U)** Un `DB_NAME` distinto se honra como override y queda marcado como tal en el plan.
- **REQ-3 (U)** Un `DB_NAME` igual al derivado **falla**, con un mensaje que pide borrarlo y nombra
  el `.sqlproj` del que se lee.
- **REQ-4 (U)** Un `DB_NAME` que difiere **solo en mayúsculas** falla pidiendo desambiguar, y nombra
  las dos grafías.
- **REQ-5 (U)** `Invoke-PgSchema` toma el nombre de `database:` de `pgschema.yaml`.
- **REQ-6 (U)** `PGDATABASE` en el env **falla** con la instrucción de moverlo a `pgschema.yaml`.
- **REQ-7 (U)** Falla con mensaje accionable si no hay `<Name>` en el `.sqlproj` o falta `database:`
  en `pgschema.yaml`.
- **REQ-8 (U)** `-Init` de `Invoke-PgSchema` genera `pgschema.yaml` con `database:` y **no** escribe
  `PGDATABASE` en el `.env`.
- **REQ-9 (C)** End-to-end: el despliegue alcanza la base nombrada por el archivo de proyecto.
- **REQ-10 (S)** Suite en verde; CHANGELOG con el procedimiento de migración de ambos ADR.

## Consequences

- **Una sola fuente de verdad por proyecto**, en la línea de `package.json` para `Publish-NodeApi`.
- **Los dos cmdlets de base de datos quedan con la misma forma.** La divergencia entre SQL Server y
  PostgreSQL se reduce a lo que la tecnología impone, no a cómo se configuró cada uno.
- **El `.env` de un proyecto de base queda siendo solo credenciales y host.**
- **Un repo queda bloqueado hasta que un humano decida:** `contratos`, por el conflicto de
  mayúsculas. Es deliberado.
- **Coste de migración concentrado:** entra en la misma pasada que ADR 0010.
- **Riesgo asumido:** derivar del `.sqlproj` significa que renombrar `<Name>` cambia el destino del
  despliegue. Antes era inerte. El plan muestra siempre el nombre objetivo, así que el cambio es
  visible antes de confirmar.
