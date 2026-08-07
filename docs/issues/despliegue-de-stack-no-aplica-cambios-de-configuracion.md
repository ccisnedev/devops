# Un despliegue de stack reporta exito sin aplicar los cambios de configuracion

**Estado:** resuelto en 6.2.2 · **Abierto:** 2026-08-07 · **Detectado en:** produccion
**Afecta a:** `Publish-DockerStack`, y a su procedimiento de rollback.

## Sintoma

El 2026-08-07 se desplego el stack `observability` a la VM `obs` con una regla de alerta de
Prometheus corregida. La salida fue esta:

```
  Verificando salud (url -> http://127.0.0.1:9090/-/healthy)...
OK - http://127.0.0.1:9090/-/healthy responde
  Deploy completado: observability v0.1.0+cef4a6e
```

Exito, healthcheck en verde. Y Prometheus seguia evaluando la regla vieja.

## Evidencia

El release nuevo estaba bien instalado y `current` bien apuntado:

```
$ ssh obs "readlink -f /opt/stacks/observability/current"
/opt/stacks/observability/releases/v0.1.0+cef4a6e

$ ssh obs "grep -m1 'expr:' /opt/stacks/observability/releases/v0.1.0+cef4a6e/prometheus/rules/fotos.yml"
        expr: >-                       # <- la regla nueva, en su lugar
```

Pero el contenedor no era nuevo:

```
$ ssh obs "docker inspect prometheus --format '{{.Created}}'"
2026-08-07T01:58:52Z                   # <- de un despliegue anterior, ~20 h antes
```

La prueba definitiva es el inode, que no admite interpretacion:

| Que | inode |
|---|---|
| Lo que el contenedor monta en `/etc/prometheus/rules/fotos.yml` | **672146** |
| El archivo en el release **anterior** (`v0.1.0+909ba6b`) | **672146** |
| El archivo en el release **nuevo** (`v0.1.0+cef4a6e`) | 672181 |

Y `docker inspect` mostraba la fuente del mount **sin resolver el symlink**, que es el dato que
explica el mecanismo completo:

```
/opt/stacks/observability/current/prometheus/rules -> /etc/prometheus/rules
```

## Causa raiz

`Deploy-DockerStack.sh` hacia `cd` al symlink antes de invocar a Compose:

```bash
ln -sfn "$RELEASE_DIR" "$CURRENT"
cd "$CURRENT"                                    # <- aqui
docker compose -p "$NAME" --env-file .env -f "$COMPOSE_FILE" up -d ...
```

Compose usa el directorio del proyecto como raiz de los bind mounts relativos y **guarda la ruta
tal cual, sin resolver symlinks**. Parado en `current`, un `./prometheus/rules` del compose
resuelve siempre a `/opt/stacks/observability/current/prometheus/rules`.

Esa cadena es **identica en todos los releases**. Compose decide si recrear un contenedor
comparando imagen, variables de entorno y la configuracion declarada de los mounts; como nada de
eso cambio, concluye —correctamente, dada la informacion que tiene— que no hay nada que hacer.

Mover el symlink despues no alcanza: el kernel lo resolvio **al crear el contenedor**, y un mount
ya establecido no sigue al symlink. El contenedor queda atado al directorio del release viejo.

De ahi la combinacion peor posible: el release se instala, el symlink apunta bien, el healthcheck
responde —porque el proceso viejo esta perfectamente vivo— y nada de lo desplegado esta corriendo.

## Alcance

Afecta a **todo despliegue cuyo unico cambio sea configuracion montada por bind mount**: reglas
de alerta, `alertmanager.yml`, datasources, dashboards, cualquier archivo de `include:`. Es decir,
el caso mas frecuente una vez que un stack esta estable y solo se ajusta su configuracion.

No afecta a los despliegues que cambian la imagen o las variables de entorno: ahi Compose si ve
una diferencia y recrea.

**El rollback documentado tenia el mismo defecto.** El mensaje final del cmdlet indicaba:

```
ssh obs 'ln -sfn <release-anterior> .../current && cd .../current && docker compose -p ... up -d'
```

Por identica razon, un rollback de un cambio de configuracion habria terminado en verde sin
revertir nada — en el momento en que uno menos puede permitirse una falsa confirmacion.

## Decision

Compose corre desde el **directorio real del release**, nunca desde el symlink:

```diff
- cd "$CURRENT"
+ cd "$RELEASE_DIR"
```

La ruta del mount pasa a cambiar en cada release, Compose ve la diferencia y recrea **solo los
servicios afectados**. `current` se conserva como puntero para el operador (logs, inspeccion,
referencia del rollback), pero los contenedores dejan de depender de el.

### Alternativa descartada: `--force-recreate`

Tambien resuelve el sintoma, y de forma inmune a como esten escritas las rutas. Se descarto como
arreglo principal por dos motivos:

1. Recrea **todos** los servicios en cada despliegue, incluidos los que no cambiaron.
2. Sobre todo, **tapa** el caso de un compose con rutas absolutas a `current` en vez de
   exponerlo. Seguiria funcionando por fuerza bruta y nadie se enteraria de que la declaracion
   esta mal.

## Verificacion

`test/DockerStackAplicaConfig.container.test.sh` fija el invariante con dos casos, y se comprobo
que falla antes del arreglo:

1. Compose se invoca desde el directorio del release, no desde el symlink.
2. Dos releases distintas producen **dos rutas distintas** — que es exactamente lo que Compose
   compara, y lo que el defecto hacia imposible.

El test observa el directorio de trabajo con el que se llama a Compose, mediante un `docker` de
mentira en el PATH. Se eligio verificar la causa raiz y no el contenido del contenedor para no
exigir un docker dentro de docker en CI.

## Leccion pendiente

El healthcheck pregunta *"¿el servicio responde?"*. Nunca pregunto *"¿esta corriendo el release
que acabo de instalar?"*, y esas son dos cosas distintas: el servicio viejo respondia perfecto.

Una verificacion post-despliegue que falle si algun contenedor monta rutas de un release anterior
cerraria la clase entera de este problema, cualquiera sea la causa. Queda como trabajo aparte por
ser mas invasivo que el arreglo.
