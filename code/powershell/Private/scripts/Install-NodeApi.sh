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
#   __ENTRYPOINT__  : (ADR 0003, opcional) ruta relativa del entrypoint a validar
#                     (default dist/main.js si no se reemplaza)
#   __RELEASE_ID__  : (ADR 0003, opcional) id de release v{version}+{sha}
#                     (default v$VERSION si no se reemplaza)
#   __GIT_SHA__     : (ADR 0003, opcional) sha corto del commit desplegado (provenance)

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

# Placeholders opcionales (ADR 0003 — runtime no-build). Si el caller no los
# reemplaza quedan como tokens __FOO__; el guard generico __*__ aplica un default
# retrocompatible (asi el flujo build:true / dist/main.js no requiere cambios).
ENTRYPOINT="__ENTRYPOINT__"
case "$ENTRYPOINT" in __*__) ENTRYPOINT="dist/main.js";; esac
RELEASE_ID="__RELEASE_ID__"
case "$RELEASE_ID" in __*__) RELEASE_ID="v$VERSION";; esac
GIT_SHA="__GIT_SHA__"
case "$GIT_SHA" in __*__) GIT_SHA="";; esac

RELEASE_DIR="$REMOTE_ROOT/$NAME/releases/$RELEASE_ID"
TARBALL="/tmp/${NAME}-${RELEASE_ID}.tar.gz"
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
# Si el .env es un sharedPath, no se sube: vive en shared/ y lo enlaza el paso 4b, igual que
# cualquier otro secreto (issue #79). Avisar de su ausencia convertiria lo normal en
# sospechoso, y el aviso dejaria de leerse justo donde importa.
#
# La lista se desarma igual que en el paso 4b: sin comillas para que se separe en palabras, y
# neutralizando el placeholder sin reemplazar. El 'if' en vez de '&&' porque un '&&' que no se
# cumple en la ultima vuelta deja el bucle en estado 1 y con 'set -e' eso aborta la instalacion.
ENV_SHARED_LIST="__SHARED_PATHS__"
case "$ENV_SHARED_LIST" in __*__) ENV_SHARED_LIST="";; esac
ENV_ES_SHARED=0
for p in $ENV_SHARED_LIST; do
    if [ "$p" = ".env" ]; then ENV_ES_SHARED=1; fi
done

if [ -f "$ENV_FILE" ]; then
    echo "Copiando .env al release..."
    $SUDO cp "$ENV_FILE" "$RELEASE_DIR/.env"
    $SUDO rm -f "$ENV_FILE"
elif [ "$ENV_ES_SHARED" = "1" ]; then
    echo "  .env: sharedPath, se enlaza desde shared/"
else
    echo "WARNING: No se encontró $ENV_FILE" >&2
fi

# ─── 4a. Copiar ecosystem.config.json generado (ADR 0005: config-as-data pm2) ───
# Publish-NodeApi lo renderiza desde publish.yaml (runtime.env/processes) y lo deja aquí.
# Idempotente: si no se generó (legacy o systemd), este bloque no hace nada.
ECOSYSTEM_STAGED="/tmp/${NAME}.ecosystem.json"
if [ -f "$ECOSYSTEM_STAGED" ]; then
    echo "Copiando ecosystem.config.json generado al release..."
    $SUDO cp "$ECOSYSTEM_STAGED" "$RELEASE_DIR/ecosystem.config.json"
    $SUDO rm -f "$ECOSYSTEM_STAGED"
fi

# ─── 4b. Enlazar shared paths (secretos/archivos runtime gitignoreados, ADR 0003) ───
# Archivos que la app lee en runtime pero que NO estan en git (claves RSA, certs) y
# por tanto no viajan en el tarball. Viven en $REMOTE_ROOT/$NAME/shared/<path> (los
# stagea el operador UNA vez) y se symlinkean dentro de cada release. Falla claro
# (exit 6) si un shared declarado no fue preparado -> evita un crash-loop por ENOENT.
SHARED_PATHS="__SHARED_PATHS__"
case "$SHARED_PATHS" in __*__) SHARED_PATHS="";; esac
if [ -n "$SHARED_PATHS" ]; then
    SHARED_DIR="$REMOTE_ROOT/$NAME/shared"
    for p in $SHARED_PATHS; do
        SRC="$SHARED_DIR/$p"
        # Debe existir Y tener contenido usable: un symlink a algo vacío no fallaría aquí
        # pero dejaría la crypto rota en runtime. Falla claro (exit 6) si el sharedPath:
        #   - no existe
        #   - es un archivo regular vacío (0 bytes)
        #   - es una carpeta sin ningún archivo regular no-vacío
        usable=0
        if [ -f "$SRC" ]; then
            [ -s "$SRC" ] && usable=1
        elif [ -d "$SRC" ]; then
            [ -n "$(find "$SRC" -type f -size +0c -print -quit 2>/dev/null)" ] && usable=1
        fi
        if [ "$usable" -ne 1 ]; then
            echo "ERROR: shared path '$p' (publish.yaml runtime.sharedPaths) falta o está vacío en el servidor:" >&2
            echo "         $SRC" >&2
            echo "       Es un archivo/carpeta runtime NO versionado (secreto/clave) sin contenido usable." >&2
            echo "       Suba su contenido con:  Publish-NodeApi -PushShared" >&2
            exit 6
        fi
        DEST="$RELEASE_DIR/$p"
        $SUDO mkdir -p "$(dirname "$DEST")"
        $SUDO rm -rf "$DEST"
        $SUDO ln -sfn "$SRC" "$DEST"
        echo "  shared enlazado: $p -> $SRC"
    done
fi

# ─── 5. Verificar entrypoint (configurable, ADR 0003) ───
if [ ! -f "$RELEASE_DIR/$ENTRYPOINT" ]; then
    echo "ERROR: entrypoint '$ENTRYPOINT' no encontrado en el release" >&2
    echo "Contenido de $(dirname "$RELEASE_DIR/$ENTRYPOINT"):" >&2
    ls -la "$(dirname "$RELEASE_DIR/$ENTRYPOINT")" 2>&1 || echo "  (directorio no existe)"
    exit 1
fi
echo "  entrypoint OK: $ENTRYPOINT"

# ─── 5b. Provenance: escribir archivo RELEASE ───────────
# Registra que commit corre en este release (anti-drift). En modo sudo el chown -R
# posterior lo incluye; en rootless el deploy user ya es dueno.
printf 'name=%s\nversion=%s\nrelease=%s\nsha=%s\ndeployed_at=%s\n' \
    "$NAME" "$VERSION" "$RELEASE_ID" "$GIT_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    | $SUDO tee "$RELEASE_DIR/RELEASE" >/dev/null
echo "  RELEASE escrito (sha=${GIT_SHA:-none})"

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

echo "Symlink 'current' -> releases/$RELEASE_ID"
echo "DEPLOYED:$RELEASE_ID"
