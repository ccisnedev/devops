#!/bin/bash
# Manage-NodeProcess.sh
# Gestiona el proceso Node.js con systemd o PM2
#
# Variables reemplazadas por PowerShell:
#   __NAME__             : nombre del proyecto
#   __PROCESS_MANAGER__  : systemd | pm2
#   __ENTRY_PATH__       : ruta absoluta al entrypoint (ej: /opt/app/myapi/current/dist/main.js)
#   __WORKING_DIR__      : directorio de trabajo (ej: /opt/app/myapi/current)
#   __ENV_FILE__         : ruta absoluta al .env (ej: /opt/app/myapi/current/.env)
#   __PORT__             : puerto de la aplicación
#   __USER__             : usuario que ejecuta el proceso

set -e

# ─── Cargar nvm si existe ────────────────────────────────
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" 2>/dev/null || true

# Obtener ruta absoluta a node (para systemd unit file)
NODE_BIN=$(command -v node 2>/dev/null || echo "/usr/bin/node")

NAME="__NAME__"
PROCESS_MANAGER="__PROCESS_MANAGER__"
ENTRY_PATH="__ENTRY_PATH__"
WORKING_DIR="__WORKING_DIR__"
ENV_FILE="__ENV_FILE__"
PORT="__PORT__"
OWNER="__USER__"

echo "Configurando process manager: $PROCESS_MANAGER"

# ═══════════════════════════════════════════════════════
# SYSTEMD
# ═══════════════════════════════════════════════════════
if [ "$PROCESS_MANAGER" = "systemd" ]; then

    SERVICE_FILE="/etc/systemd/system/${NAME}.service"

    echo "Generando unit file: $SERVICE_FILE"

    sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=$NAME Node.js API
After=network.target

[Service]
Type=simple
User=$OWNER
WorkingDirectory=$WORKING_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$NODE_BIN $ENTRY_PATH
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$NAME

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$WORKING_DIR
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    echo "Recargando systemd..."
    sudo systemctl daemon-reload

    echo "Reiniciando servicio $NAME..."
    sudo systemctl restart "$NAME"

    echo "Habilitando auto-inicio..."
    sudo systemctl enable "$NAME" 2>/dev/null

    # Verificar estado
    sleep 2
    if systemctl is-active --quiet "$NAME"; then
        echo "Servicio $NAME activo (systemd)"
    else
        echo "ERROR: Servicio $NAME no pudo iniciar" >&2
        sudo journalctl -u "$NAME" --no-pager -n 20
        exit 1
    fi

# ═══════════════════════════════════════════════════════
# PM2
# ═══════════════════════════════════════════════════════
elif [ "$PROCESS_MANAGER" = "pm2" ]; then

    if ! command -v pm2 >/dev/null 2>&1; then
        echo "ERROR: PM2 no está instalado. Instalar con: npm install -g pm2" >&2
        exit 1
    fi

    # Eliminar proceso anterior si existe
    if pm2 describe "$NAME" >/dev/null 2>&1; then
        echo "Eliminando proceso PM2 existente: $NAME"
        pm2 delete "$NAME" || true
    fi

    echo "Iniciando con PM2: $NAME"
    cd "$WORKING_DIR"

    # Cargar variables de entorno del .env e iniciar
    if [ -f "$ENV_FILE" ]; then
        # Exportar variables del .env y luego iniciar PM2
        set -a
        . "$ENV_FILE"
        set +a
    fi

    pm2 start "$ENTRY_PATH" \
        --name "$NAME" \
        --cwd "$WORKING_DIR" \
        --update-env

    pm2 save

    # Verificar estado
    sleep 2
    if pm2 describe "$NAME" | grep -q "online"; then
        echo "Proceso $NAME activo (PM2)"
    else
        echo "ERROR: Proceso $NAME no pudo iniciar" >&2
        pm2 logs "$NAME" --nostream --lines 20
        exit 1
    fi

else
    echo "ERROR: Process manager no reconocido: $PROCESS_MANAGER (usar: systemd | pm2)" >&2
    exit 1
fi

echo "PROCESS:started"
