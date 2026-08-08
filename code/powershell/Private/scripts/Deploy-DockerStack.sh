#!/bin/bash
# Deploy-DockerStack.sh
# Instala un release del stack en el servidor y levanta docker compose.
#
# Variables reemplazadas por PowerShell:
#   __NAME__         : nombre del proyecto compose (-p) y carpeta en /opt/stacks
#   __STACK_DIR__    : /opt/stacks/<name>
#   __RELEASE_DIR__  : /opt/stacks/<name>/releases/<release>
#   __CURRENT_LINK__ : /opt/stacks/<name>/current
#   __TARBALL__      : ruta del tar.gz subido (compose + include)
#   __REMOTE_ENV__   : ruta del .env subido
#   __COMPOSE_FILE__ : ruta del compose relativa al release (ej: docker-compose.yml)
#   __BUILD_FLAG__   : --build | --no-build | (vacío)
#   __RELEASE_ID__   : identificador del release

set -euo pipefail

NAME="__NAME__"
STACK_DIR="__STACK_DIR__"
RELEASE_DIR="__RELEASE_DIR__"
CURRENT="__CURRENT_LINK__"
TARBALL="__TARBALL__"
REMOTE_ENV="__REMOTE_ENV__"
COMPOSE_FILE="__COMPOSE_FILE__"
BUILD_FLAG="__BUILD_FLAG__"

echo "Instalando release __RELEASE_ID__ (proyecto $NAME)"

mkdir -p "$RELEASE_DIR"
tar -xzf "$TARBALL" -C "$RELEASE_DIR"

# Colocar .env dentro del release (docker compose lo lee del directorio del proyecto)
cp "$REMOTE_ENV" "$RELEASE_DIR/.env"
chmod 600 "$RELEASE_DIR/.env"
rm -f "$TARBALL" "$REMOTE_ENV"

# Apuntar 'current' al nuevo release. Es un puntero para el operador (logs, inspeccion): los
# contenedores NO dependen de el, por lo que sigue mas abajo.
ln -sfn "$RELEASE_DIR" "$CURRENT"

# Compose corre desde el directorio REAL del release, nunca desde el symlink.
#
# Compose toma el directorio del proyecto como raiz de los bind mounts relativos y guarda la
# ruta tal cual, sin resolver symlinks. Parado en "$CURRENT", un `./conf` del compose resuelve
# siempre a ".../current/conf": una cadena identica en todos los releases. Compose compara
# imagen, variables y esa cadena, no encuentra diferencia y no recrea el contenedor; el mount
# vivo sigue apuntando al release anterior, porque el kernel resolvio el symlink al crearlo.
# El despliegue termina en verde con la configuracion vieja corriendo.
#
# Parado en "$RELEASE_DIR" la ruta cambia en cada release, Compose ve la diferencia y recrea
# solo los servicios afectados. Fijado en test/DockerStackAplicaConfig.container.test.sh.
cd "$RELEASE_DIR"

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: no se encontró el compose '$COMPOSE_FILE' en el release" >&2
    exit 1
fi

echo "docker compose -p $NAME up -d $BUILD_FLAG --remove-orphans"
# shellcheck disable=SC2086
docker compose -p "$NAME" --env-file .env -f "$COMPOSE_FILE" up -d $BUILD_FLAG --remove-orphans

docker compose -p "$NAME" -f "$COMPOSE_FILE" ps

# ── Verificar que lo que corre sea lo que se acaba de instalar ────────────────────────────────
# El healthcheck pregunta si el servicio responde, y el servicio ANTERIOR responde igual de bien:
# por eso un despliegue pudo terminar en verde con la configuracion vieja corriendo. Esto
# pregunta otra cosa: si algun contenedor del proyecto quedo montando un directorio de release
# que no es este. Se mira la ruta de los mounts y no la fecha de creacion, para no depender de
# relojes ni de heuristicas, y para detectar el problema sea cual sea su causa.
# Se distinguen dos causas porque el remedio NO es el mismo:
#   VIA_SYMLINK  el compose declara una ruta a 'current'. Recrear no arregla nada: volveria a
#                montar el symlink. Hay que corregir la declaracion.
#   OTRO_RELEASE el contenedor no se recreo y quedo atado a un release anterior. Recrearlo basta.
VIA_SYMLINK=""
OTRO_RELEASE=""
for ID in $(docker ps -q --filter "label=com.docker.compose.project=$NAME"); do
    for SRC in $(docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$ID"); do
        case "$SRC" in
            "$RELEASE_DIR"|"$RELEASE_DIR"/*) ;;                       # de este release: correcto
            "$CURRENT"|"$CURRENT"/*) VIA_SYMLINK="$VIA_SYMLINK  $ID  $SRC\n" ;;
            "$STACK_DIR"/*)          OTRO_RELEASE="$OTRO_RELEASE  $ID  $SRC\n" ;;
            *) ;;                                                     # volumenes y rutas del host: ajenos
        esac
    done
done

if [ -n "$VIA_SYMLINK$OTRO_RELEASE" ]; then
    {
        echo "ERROR: el stack no quedo corriendo la configuracion de este release."
        if [ -n "$OTRO_RELEASE" ]; then
            echo
            echo "Contenedores atados a un release anterior (no se recrearon):"
            printf "%b" "$OTRO_RELEASE"
            echo "Recrearlos alcanza:"
            echo "  cd $RELEASE_DIR && docker compose -p $NAME up -d --force-recreate"
        fi
        if [ -n "$VIA_SYMLINK" ]; then
            echo
            echo "Mounts declarados contra el symlink 'current':"
            printf "%b" "$VIA_SYMLINK"
            echo "Aca recrear NO alcanza: volveria a montar el symlink, y el kernel lo resuelve"
            echo "una sola vez, al crear el contenedor. Corrija el compose para que la ruta sea"
            echo "relativa al proyecto ('./conf') en vez de apuntar a '$CURRENT'."
        fi
    } >&2
    exit 1
fi

echo "Stack '$NAME' levantado."
