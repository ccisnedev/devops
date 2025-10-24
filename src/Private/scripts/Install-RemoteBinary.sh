#!/bin/bash
# Install-RemoteBinary.sh
# Instala un binario en el servidor remoto y actualiza el symlink 'current'
#
# Variables reemplazadas por PowerShell:
#   __REMOTE_RELEASE__ : Ruta del release (ej: /opt/app/myapp_api/releases/v1.0.0)
#   __APP_SERVER_ROOT__ : Ruta raíz de la app (ej: /opt/app/myapp_api)
#   __REMOTE_TMP__     : Ruta temporal donde está el binario subido
#   __USER__           : Usuario propietario de los archivos

set -e

# Crear estructura de directorios del release
sudo mkdir -p '__REMOTE_RELEASE__'/bin

# Backup del binario actual si existe (para rollback)
if [ -f '__APP_SERVER_ROOT__/current/bin/server' ]; then
    ts=$(date +%Y%m%d%H%M%S)
    echo "Creando backup: server.bak.$ts"
    sudo cp -v '__APP_SERVER_ROOT__/current/bin/server' '__APP_SERVER_ROOT__/current/bin/server.bak.$ts' || true
fi

# Mover binario desde /tmp al release
sudo mv '__REMOTE_TMP__' '__REMOTE_RELEASE__'/bin/server

# Establecer permisos de ejecución
sudo chmod +x '__REMOTE_RELEASE__'/bin/server

# Cambiar propietario al usuario correcto
sudo chown -R __USER__:__USER__ '__REMOTE_RELEASE__'

# Actualizar symlink 'current' al nuevo release
sudo ln -sfn '__REMOTE_RELEASE__' '__APP_SERVER_ROOT__/current'

echo "Instalación completada. Symlink 'current' actualizado."
