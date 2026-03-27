#!/bin/bash
# Install-FlutterWeb.sh
# Instala artefactos pre-compilados de una app Flutter Web
# Extrae zip, crea release versionado, actualiza symlink current
# El build se realiza localmente; este script solo instala los artefactos.
#
# Variables reemplazadas por PowerShell:
#   __NAME__     : nombre del proyecto (de pubspec.yaml)
#   __VERSION__  : versión (de pubspec.yaml, ej: 1.2.3)
#   __WEB_ROOT__ : directorio base web (ej: /var/www)

set -e

NAME="__NAME__"
VERSION="__VERSION__"
WEB_ROOT="__WEB_ROOT__"

RELEASE_DIR="$WEB_ROOT/$NAME/releases/v$VERSION"
CURRENT_LINK="$WEB_ROOT/$NAME/current"
ZIP_FILE="/tmp/${NAME}_web_v${VERSION}.zip"

# ─── 1. Verificar zip ───────────────────────────────────
if [ ! -f "$ZIP_FILE" ]; then
    echo "ERROR: Zip no encontrado: $ZIP_FILE" >&2
    exit 1
fi

# ─── 2. Crear directorio del release ────────────────────
echo "Creando release directory: $RELEASE_DIR"
sudo mkdir -p "$RELEASE_DIR"

# Si la misma versión ya existe, limpiar contenido previo
if [ "$(ls -A "$RELEASE_DIR" 2>/dev/null)" ]; then
    echo "Release v$VERSION ya existe, reemplazando contenido..."
    sudo rm -rf "$RELEASE_DIR"/*
fi

# ─── 3. Extraer zip ─────────────────────────────────────
echo "Extrayendo artefactos web..."
sudo unzip -q -o "$ZIP_FILE" -d "$RELEASE_DIR" 2>&1 | grep -v "backslashes as path separators" || true
sudo rm -f "$ZIP_FILE"

# ─── 4. Verificar index.html ────────────────────────────
if [ ! -f "$RELEASE_DIR/index.html" ]; then
    echo "ERROR: index.html no encontrado en el release" >&2
    echo "Contenido de $RELEASE_DIR:" >&2
    ls -la "$RELEASE_DIR" 2>&1 || echo "  (directorio vacío)"
    exit 1
fi
echo "  index.html OK"

# ─── 5. Ajustar permisos ────────────────────────────────
sudo chown -R www-data:www-data "$RELEASE_DIR"
sudo chmod -R 755 "$RELEASE_DIR"

# ─── 6. Actualizar symlink current ──────────────────────
if [ -L "$CURRENT_LINK" ]; then
    PREV=$(readlink -f "$CURRENT_LINK")
    echo "Release anterior: $PREV"
fi

sudo ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"

echo "Symlink 'current' -> releases/v$VERSION"
echo "DEPLOYED:v$VERSION"
sudo chmod -R 755 "$RELEASE_DIR"

# ─── 6. Actualizar symlink current ──────────────────────
if [ -L "$CURRENT_LINK" ]; then
    PREV=$(readlink -f "$CURRENT_LINK")
    echo "Release anterior: $PREV"
fi

sudo ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"

echo "Symlink 'current' -> releases/v$VERSION"
echo "DEPLOYED:v$VERSION"
