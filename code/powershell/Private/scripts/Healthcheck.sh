#!/bin/bash
# Healthcheck.sh
# Verifica que el servidor HTTP responde correctamente en el endpoint de health
#
# Variables reemplazadas por PowerShell:
#   __HEALTHURL__ : URL completa del healthcheck (ej: http://127.0.0.1:4321/health)

set -e

tries=0
max_tries=6
sleep_time=2

echo "Verificando health endpoint: __HEALTHURL__"

until [ $tries -ge $max_tries ]
do
    if curl -fsS '__HEALTHURL__' >/dev/null 2>&1; then
        echo "OK - Servidor respondiendo correctamente"
        exit 0
    fi
    
    tries=$((tries+1))
    
    if [ $tries -lt $max_tries ]; then
        echo "Intento $tries/$max_tries falló. Reintentando en ${sleep_time}s..."
        sleep $sleep_time
    fi
done

echo "ERROR: Healthcheck falló después de $max_tries intentos" >&2
exit 1
