#!/bin/bash
# Configure-NginxSite.sh
# Crea una configuración nginx dedicada para una app web en un puerto específico.
# Solo actúa si la config no existe — nunca sobreescribe configuraciones existentes.
#
# Variables reemplazadas por PowerShell:
#   __NAME__ : nombre del proyecto (usado como nombre de archivo y root)
#   __PORT__ : puerto donde nginx escuchará para esta app

set -e

NAME="__NAME__"
PORT="__PORT__"

SITES_AVAILABLE="/etc/nginx/sites-available/$NAME"
SITES_ENABLED="/etc/nginx/sites-enabled/$NAME"
WEB_ROOT="/var/www/$NAME/current"

# ─── 1. Verificar si ya existe ──────────────────────────
if [ -f "$SITES_AVAILABLE" ]; then
    echo "Config nginx ya existe: $SITES_AVAILABLE — no se modifica."
    echo "NGINX:EXISTS"
    exit 0
fi

# ─── 2. Crear configuración ─────────────────────────────
echo "Creando configuración nginx: $SITES_AVAILABLE"

sudo tee "$SITES_AVAILABLE" > /dev/null <<EOF
# $NAME - Flutter Web (puerto $PORT)
# Generado por: Publish-FlutterWeb -Deploy (PSDevOps)
server {
    listen $PORT;
    server_name _;

    root $WEB_ROOT;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

# ─── 3. Crear symlink en sites-enabled ──────────────────
if [ ! -L "$SITES_ENABLED" ]; then
    echo "Creando symlink en sites-enabled..."
    sudo ln -s "$SITES_AVAILABLE" "$SITES_ENABLED"
else
    echo "Symlink ya existe en sites-enabled."
fi

# ─── 4. Validar configuración ───────────────────────────
echo "Validando configuración nginx..."
if ! sudo nginx -t 2>&1; then
    echo "ERROR: Configuración nginx inválida. Eliminando config creada..." >&2
    sudo rm -f "$SITES_AVAILABLE" "$SITES_ENABLED"
    exit 1
fi

# ─── 5. Recargar nginx ──────────────────────────────────
echo "Recargando nginx..."
sudo systemctl reload nginx

echo "Nginx configurado: puerto $PORT -> $WEB_ROOT"
echo "NGINX:CREATED"
