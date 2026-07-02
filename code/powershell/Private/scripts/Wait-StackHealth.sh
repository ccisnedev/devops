#!/bin/bash
# Wait-StackHealth.sh
# Espera a que el stack quede sano: contenedor 'healthy'/'running' o una URL que responde.
#
# Variables reemplazadas por PowerShell:
#   __MODE__     : container | url
#   __NAME__     : nombre del proyecto compose (-p)   (modo container)
#   __TARGET__   : servicio (modo container) | URL (modo url)
#   __RETRIES__  : número de intentos
#   __INTERVAL__ : segundos entre intentos

set -e

MODE="__MODE__"
NAME="__NAME__"
TARGET="__TARGET__"
RETRIES=__RETRIES__
INTERVAL=__INTERVAL__

echo "Healthcheck ($MODE): $TARGET (hasta $((RETRIES * INTERVAL))s)"

i=0
while [ $i -lt $RETRIES ]; do
    i=$((i + 1))

    if [ "$MODE" = "url" ]; then
        if curl -fsS "$TARGET" >/dev/null 2>&1; then
            echo "OK - $TARGET responde"
            exit 0
        fi
        echo "  [$i/$RETRIES] $TARGET aún no responde"
    else
        cid=$(docker compose -p "$NAME" ps -q "$TARGET" 2>/dev/null | head -1)
        if [ -n "$cid" ]; then
            has_hc=$(docker inspect -f '{{if .State.Health}}yes{{else}}no{{end}}' "$cid" 2>/dev/null || echo no)
            st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo unknown)
            echo "  [$i/$RETRIES] $TARGET: $st"
            if [ "$has_hc" = "yes" ]; then
                [ "$st" = "healthy" ] && { echo "OK - $TARGET healthy"; exit 0; }
            else
                [ "$st" = "running" ] && { echo "OK - $TARGET running (sin healthcheck)"; exit 0; }
            fi
        else
            echo "  [$i/$RETRIES] $TARGET: sin contenedor aún"
        fi
    fi

    sleep $INTERVAL
done

echo "ERROR: healthcheck falló ($MODE $TARGET) tras $((RETRIES * INTERVAL))s" >&2
exit 1
