#!/bin/bash
# Manage-PM2.sh
# Gestiona el proceso PM2 para una aplicación Dart compilada
#
# Variables reemplazadas por PowerShell:
#   __APP_BIN__     : Ruta del binario ejecutable
#   __APP_NAME__    : Nombre de la app en PM2
#   __ENV_VARS__    : String de variables de entorno para PM2 (--env KEY='value' ...)

set -e

APP_BIN="__APP_BIN__"
APP_NAME="__APP_NAME__"

# Si existe proceso anterior, borrarlo para forzar un arranque limpio
# (evita problemas con opciones antiguas como --interpreter)
if pm2 describe "$APP_NAME" >/dev/null 2>&1; then
    echo "Eliminando proceso PM2 existente: $APP_NAME"
    pm2 delete "$APP_NAME" || true
fi

# Verificar que el binario es un ejecutable ELF nativo (no script)
if ! command -v file >/dev/null 2>&1; then
    echo "WARNING: Comando 'file' no está instalado en el servidor. Se omite verificación de tipo de archivo." >&2
    echo "  Para instalar: sudo apt-get install -y file" >&2
else
    ft=$(file -b "$APP_BIN" || true)
    echo "Tipo de archivo: $ft"
    
    # Verificar que contiene "ELF" (ejecutable Linux)
    echo "$ft" | grep -q ELF >/dev/null 2>&1 || {
        echo "ERROR: El binario no parece ser un ejecutable ELF: $APP_BIN" >&2
        echo "Información del archivo:" >&2
        ls -lh "$APP_BIN" || true
        echo "Primeros bytes (hex dump):" >&2
        head -c 4096 "$APP_BIN" | xxd | head -n 20 || true
        exit 3
    }
fi

# Iniciar proceso PM2 con:
#   --interpreter none : ejecutar como binario nativo (no Node.js/Python)
#   --update-env       : actualizar variables de entorno si ya existe
#   --env KEY='value'  : pasar variables de entorno individuales
echo "Iniciando PM2: $APP_NAME"

# Construir comando PM2 con las variables de entorno
# Las variables se pasan solo al subshell de PM2, sin contaminar el entorno global
ENV_VARS_STRING="__ENV_VARS__"
if [ -n "$ENV_VARS_STRING" ]; then
    # Extraer las variables del string y crear comando con env vars en subshell
    # Formato esperado: --env KEY='value' --env KEY2='value2'
    # Convertimos a: KEY='value' KEY2='value2' pm2 start ...
    ENV_PREFIX=$(echo "$ENV_VARS_STRING" | sed "s/--env //g")
    eval $ENV_PREFIX pm2 start '"$APP_BIN"' --name '"$APP_NAME"' --interpreter none --update-env
else
    pm2 start "$APP_BIN" --name "$APP_NAME" --interpreter none --update-env
fi

# Guardar configuración de PM2 para auto-inicio
pm2 save

echo "PM2 configurado exitosamente para: $APP_NAME"
