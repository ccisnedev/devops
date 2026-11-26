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

# ─── Guard de handoff de puerto ──────────────────────────
# Antes de arrancar, esperar (acotado) a que el PORT quede libre. Un restart de nuestra propia
# app libera el puerto en <2s; pero si un proceso AJENO (p. ej. un git-clone/legacy en el mismo
# host) sigue reteniendolo, arrancar aqui provocaria un crash-loop EADDRINUSE hasta que se
# libere. En ese caso fallamos LIMPIO nombrando el puerto, en vez de reintentar en silencio.
# (Incidente 2026-07-22: cutover de micro -> 254 EADDRINUSE en :3020 -> ~1h de fotos caidas para
# los consumidores del file server servidos via ese puerto.)
# Timeout configurable con PORT_FREE_TIMEOUT (segundos, default 15).
wait_port_free() {
    local port="$1"
    case "$port" in ''|*[!0-9]*) return 0 ;; esac   # sin puerto numerico conocido, nada que verificar
    local tries=0 max="${PORT_FREE_TIMEOUT:-15}"
    # Probe TCP portable (bash /dev/tcp): subshell que conecta y cierra sin fugar fd. Exito =
    # puerto ocupado (alguien escucha); fallo = libre (connection refused).
    while (: < "/dev/tcp/127.0.0.1/$port") 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge "$max" ]; then
            echo "ERROR: el puerto :$port sigue ocupado tras ${max}s." >&2
            echo "  Un proceso ajeno retiene :$port (un legacy/git-clone sin detener?)." >&2
            echo "  Detenlo antes de desplegar para evitar un crash-loop EADDRINUSE en el arranque." >&2
            if command -v ss >/dev/null 2>&1; then ss -ltnp "sport = :$port" >&2 2>/dev/null || true; fi
            return 1
        fi
        sleep 1
    done
    return 0
}

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
        echo "ERROR: PM2 is not installed. Install with: npm install -g pm2" >&2
        exit 1
    fi

    cd "$WORKING_DIR"

    # Config-as-code file resolution (ADR 0005): prefer the generated JSON (pm2 loads it
    # natively — no CommonJS/ESM trap in a "type":"module" project), then .cjs (ESM-safe
    # escape hatch for computed configs), then legacy .js (CommonJS). First existing wins.
    ECOSYSTEM_FILE=""
    for _eco_cand in ecosystem.config.json ecosystem.config.cjs ecosystem.config.js; do
        if [ -f "$WORKING_DIR/$_eco_cand" ]; then
            ECOSYSTEM_FILE="$WORKING_DIR/$_eco_cand"
            break
        fi
    done

    if [ -n "$ECOSYSTEM_FILE" ]; then
        # Config-as-code path: declarative process topology (one or more apps).
        # Process names, cwd and env are owned by the config-as-code file, not by CLI flags.
        echo "Using config-as-code: $ECOSYSTEM_FILE"

        # Delete + start: el registro de pm2 se rehace en cada deploy con lo que declare el
        # ecosystem del release nuevo (nombres, cwd, env). pm2 solo sigue el symlink 'current'
        # en un restart/reload/resurrect si el app tiene cwd = .../current: sin cwd, pm2 lo
        # resuelve contra process.cwd() del CLI, que Node entrega ya resuelto (getcwd), y el
        # app queda anclado a releases/<release> (#110). El ecosystem.config.json generado
        # siempre declara cwd; para los escritos a mano se verifica abajo.
        pm2 delete "$ECOSYSTEM_FILE" >/dev/null 2>&1 || true
        wait_port_free "$PORT" || exit 1
        pm2 start "$ECOSYSTEM_FILE" --update-env

        # Persist the process list so 'pm2 startup' can resurrect it after a reboot.
        pm2 save

        # Aviso (no error, para no romper deploys existentes): apps anclados a un release fisico.
        # WORKING_DIR es <root>/<app>/current; un pm_cwd bajo <root>/<app>/releases/ delata el
        # ecosystem sin cwd. node siempre existe aqui: pm2 lo requiere.
        APP_ROOT="$(dirname "$WORKING_DIR")"
        PINNED="$(pm2 jlist 2>/dev/null | node -e '
            let raw = ""; process.stdin.on("data", d => raw += d).on("end", () => {
                let apps = []; try { apps = JSON.parse(raw.slice(raw.indexOf("["))); } catch (e) { return; }
                for (const p of apps) {
                    const c = (p.pm2_env && p.pm2_env.pm_cwd) || "";
                    if (c.startsWith(process.argv[1] + "/releases/")) console.log(p.name + " -> " + c);
                }
            });' "$APP_ROOT" || true)"
        if [ -n "$PINNED" ]; then
            echo "AVISO: pm2 registro estos apps con el directorio fisico del release, no con $WORKING_DIR:" >&2
            echo "$PINNED" | sed 's/^/  /' >&2
            echo "  Un 'pm2 restart' o un rollback cambiando el symlink 'current' seguiria corriendo ese release." >&2
            echo "  Declare cwd: '$WORKING_DIR' en $(basename "$ECOSYSTEM_FILE"), o migre a runtime.env /" >&2
            echo "  runtime.processes en publish.yaml (el ecosystem generado ya lo declara). Ver #110." >&2
        fi

        # The ecosystem file owns the app names, so verify the whole list instead of $NAME.
        # The authoritative liveness check is the healthcheck that runs after this script.
        sleep 2
        if pm2 jlist | grep -q '"status":"errored"'; then
            echo "ERROR: at least one PM2 app is in 'errored' state" >&2
            pm2 logs --nostream --lines 20
            exit 1
        fi
        echo "PM2 apps started from config-as-code"
    else
        # Direct path (backward compatible): a single process started imperatively.
        # Remove a previous process with the same name to force a clean start.
        if pm2 describe "$NAME" >/dev/null 2>&1; then
            echo "Removing existing PM2 process: $NAME"
            pm2 delete "$NAME" || true
        fi

        echo "Starting with PM2: $NAME"

        # Load environment variables from the .env file before starting.
        if [ -f "$ENV_FILE" ]; then
            set -a
            . "$ENV_FILE"
            set +a
        fi

        wait_port_free "$PORT" || exit 1

        pm2 start "$ENTRY_PATH" \
            --name "$NAME" \
            --cwd "$WORKING_DIR" \
            --update-env

        pm2 save

        sleep 2
        if pm2 describe "$NAME" | grep -q "online"; then
            echo "Process $NAME online (PM2)"
        else
            echo "ERROR: Process $NAME failed to start" >&2
            pm2 logs "$NAME" --nostream --lines 20
            exit 1
        fi
    fi

else
    echo "ERROR: Process manager no reconocido: $PROCESS_MANAGER (usar: systemd | pm2)" >&2
    exit 1
fi

echo "PROCESS:started"
