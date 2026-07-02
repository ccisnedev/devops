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

# Apuntar 'current' al nuevo release (rollback = repuntar este symlink)
ln -sfn "$RELEASE_DIR" "$CURRENT"

cd "$CURRENT"

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: no se encontró el compose '$COMPOSE_FILE' en el release" >&2
    exit 1
fi

echo "docker compose -p $NAME up -d $BUILD_FLAG --remove-orphans"
# shellcheck disable=SC2086
docker compose -p "$NAME" --env-file .env -f "$COMPOSE_FILE" up -d $BUILD_FLAG --remove-orphans

docker compose -p "$NAME" -f "$COMPOSE_FILE" ps
echo "Stack '$NAME' levantado."
