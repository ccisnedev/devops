#!/bin/bash
# Install-NodeApi.sh
# Instala artefactos pre-compilados de un proyecto Node.js/TypeScript
# Extrae tarball (dist/ + node_modules/ + package.json), copia .env, crea symlink
# El build se realiza localmente; este script solo instala los artefactos.
#
# Variables reemplazadas por PowerShell:
#   __NAME__        : nombre del proyecto (de package.json)
#   __VERSION__     : versión (de package.json, ej: 1.2.3)
#   __REMOTE_ROOT__ : directorio base (ej: /opt/app)
#   __NODE_VERSION__: versión mínima requerida (ej: >=18)
#   __USER__        : usuario propietario de los archivos
#   __USE_SUDO__    : "1" usa sudo para las operaciones de archivos; "0" (default) rootless

set -e

# ─── Cargar nvm si existe ────────────────────────────────
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" 2>/dev/null || true

NAME="__NAME__"
VERSION="__VERSION__"
REMOTE_ROOT="__REMOTE_ROOT__"
NODE_VERSION_REQ="__NODE_VERSION__"
OWNER="__USER__"
USE_SUDO="__USE_SUDO__"

# sudo is opt-in. Default (rootless): the deploy user owns REMOTE_ROOT/$NAME,
# so no elevation is needed. Set useSudo:true in publish.yaml to deploy into a
# directory the user does not own.
if [ "$USE_SUDO" = "1" ]; then SUDO="sudo"; else SUDO=""; fi

RELEASE_DIR="$REMOTE_ROOT/$NAME/releases/v$VERSION"
TARBALL="/tmp/${NAME}-v${VERSION}.tar.gz"
ENV_FILE="/tmp/${NAME}.env.production"

# ─── 1. Verificar Node.js ───────────────────────────────
echo "Verificando Node.js..."
if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: Node.js no está instalado" >&2
    exit 1
fi

NODE_CURRENT=$(node -v | sed 's/^v//' | cut -d. -f1)
NODE_REQUIRED=$(echo "$NODE_VERSION_REQ" | sed 's/[^0-9]//g')

if [ "$NODE_CURRENT" -lt "$NODE_REQUIRED" ]; then
    echo "ERROR: Node.js v${NODE_CURRENT} instalado, se requiere $NODE_VERSION_REQ" >&2
    exit 1
fi
echo "  Node.js v$(node -v | sed 's/^v//') OK"

# ─── 2. Crear directorio del release ────────────────────
echo "Creando release directory: $RELEASE_DIR"
$SUDO mkdir -p "$RELEASE_DIR"

# ─── 3. Extraer tarball ─────────────────────────────────
if [ ! -f "$TARBALL" ]; then
    echo "ERROR: Tarball no encontrado: $TARBALL" >&2
    exit 1
fi

echo "Extrayendo tarball (artefactos pre-compilados)..."
$SUDO tar -xzf "$TARBALL" -C "$RELEASE_DIR"
$SUDO rm -f "$TARBALL"

# ─── 4. Copiar .env ─────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
    echo "Copiando .env al release..."
    $SUDO cp "$ENV_FILE" "$RELEASE_DIR/.env"
    $SUDO rm -f "$ENV_FILE"
else
    echo "WARNING: No se encontró $ENV_FILE" >&2
fi

# ─── 5. Verificar entrypoint ────────────────────────────
if [ ! -f "$RELEASE_DIR/dist/main.js" ]; then
    echo "ERROR: dist/main.js no encontrado en el tarball" >&2
    echo "Contenido de dist/:" >&2
    ls -la "$RELEASE_DIR/dist/" 2>&1 || echo "  (directorio dist/ no existe)"
    exit 1
fi
echo "  dist/main.js OK"

# ─── 6. Ajustar permisos (solo en modo sudo; en rootless el deploy user ya es dueño) ───
if [ "$USE_SUDO" = "1" ]; then
    sudo chown -R "$OWNER":"$OWNER" "$RELEASE_DIR"
fi

# ─── 7. Backup y actualizar symlink ─────────────────────
CURRENT_LINK="$REMOTE_ROOT/$NAME/current"

if [ -L "$CURRENT_LINK" ]; then
    PREV=$(readlink -f "$CURRENT_LINK")
    echo "Release anterior: $PREV"
fi

$SUDO ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"

echo "Symlink 'current' -> releases/v$VERSION"
echo "DEPLOYED:v$VERSION"
