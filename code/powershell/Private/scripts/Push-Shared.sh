#!/bin/bash
# Push-Shared.sh — server-side de `Publish-NodeApi -PushShared`.
# Reemplazo LIMPIO e idempotente de los sharedPaths (secretos/archivos runtime NO
# versionados: claves RSA, certs) en $REMOTE_ROOT/$NAME/shared/<path>, a partir de un
# tarball subido con el contenido LOCAL. Deja el shared/ del servidor idéntico al local.
#
# El contenido llega en /tmp/${NAME}-shared.tar.gz (lo sube PowerShell vía scp) con la
# estructura de los sharedPaths (ej. key/privatekey.pem). Este script NO decide crear vs
# reemplazar (eso lo reporta PowerShell antes de confirmar); aquí solo se aplica.
#
# Variables reemplazadas por PowerShell:
#   __NAME__         : nombre del proyecto (de package.json)
#   __REMOTE_ROOT__  : directorio base (ej: /opt/app)
#   __SHARED_PATHS__ : lista separada por espacios de los sharedPaths (ej: "key")
#   __USE_SUDO__     : "1" usa sudo; "0" (default) rootless
set -e

NAME="__NAME__"
REMOTE_ROOT="__REMOTE_ROOT__"
SHARED_PATHS="__SHARED_PATHS__"
USE_SUDO="__USE_SUDO__"
case "$SHARED_PATHS" in __*__) SHARED_PATHS="";; esac
if [ "$USE_SUDO" = "1" ]; then SUDO="sudo"; else SUDO=""; fi

SHARED_DIR="$REMOTE_ROOT/$NAME/shared"
TARBALL="/tmp/${NAME}-shared.tar.gz"
STAGING="/tmp/${NAME}-shared-staging"

if [ -z "$SHARED_PATHS" ]; then
    echo "No hay sharedPaths declarados; nada que subir."
    exit 0
fi
if [ ! -f "$TARBALL" ]; then
    echo "ERROR: no se encontró el tarball de shared: $TARBALL" >&2
    exit 1
fi

# Extraer el contenido subido a un staging temporal
rm -rf "$STAGING"
mkdir -p "$STAGING"
tar -xzf "$TARBALL" -C "$STAGING"
rm -f "$TARBALL"

# "usable": mismo criterio que Install-NodeApi.sh (no vacío) — nunca reemplazar con vacío.
is_usable() {
    local path="$1"
    if [ -f "$path" ]; then
        [ -s "$path" ]
    elif [ -d "$path" ]; then
        [ -n "$(find "$path" -type f -size +0c -print -quit 2>/dev/null)" ]
    else
        return 1
    fi
}

for p in $SHARED_PATHS; do
    STAGE="$STAGING/$p"
    DEST="$SHARED_DIR/$p"

    # Defensa: si el contenido local está vacío, no se toca el remoto (exit 8).
    if ! is_usable "$STAGE"; then
        echo "ERROR: el contenido local de '$p' está vacío o falta; no se reemplaza el remoto." >&2
        rm -rf "$STAGING"
        exit 8
    fi

    if [ -e "$DEST" ]; then
        echo "  reemplazando (limpio): $p -> $DEST"
    else
        echo "  creando: $p -> $DEST"
    fi

    $SUDO mkdir -p "$(dirname "$DEST")"
    $SUDO rm -rf "$DEST"
    $SUDO mv "$STAGE" "$DEST"
done

rm -rf "$STAGING"
echo "PUSHED_SHARED:$SHARED_PATHS"
