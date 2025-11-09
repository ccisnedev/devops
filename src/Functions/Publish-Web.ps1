<#
.SYNOPSIS
Despliega contenido web estático directamente a /var/www/<nombre> en el servidor remoto.

.DESCRIPTION
El cmdlet `Publish-Web` lee la configuración del proyecto desde deploy.yaml (name, version, server),
comprime la carpeta de build/web, la sube al servidor remoto mediante SSH/SCP y la despliega 
directamente en /var/www/<nombre> para servir con nginx/apache.

Se debe ejecutar desde la raíz del proyecto donde existe deploy.yaml con:
- name: nombre del proyecto
- version: versión de la aplicación
- server: alias del servidor configurado en ~/.ssh/config

.EXAMPLE
Publish-Web
Lee deploy.yaml, detecta el servidor y despliega el contenido web.

.NOTES
Versión: 1.0.0
Autor: @ccisnedev
Requiere: Configuración del host en ~/.ssh/config con Host, HostName, User, Port e IdentityFile.
#>
function Publish-Web {
    [CmdletBinding()]
    param()
    
    # Detener ejecución al primer error
    $ErrorActionPreference = 'Stop'

    # ====== CONFIGURABLES ======
    $RemoteWebRoot = "/var/www"       # Raíz web en el servidor
    # ===========================

    # 0) Validar que estamos en un proyecto con deploy.yaml
    $cwd = (Get-Location).Path
    $deployYaml = Join-Path $cwd "deploy.yaml"
    
    if (!(Test-Path $deployYaml)) {
        # Crear archivo deploy.yaml de ejemplo
        $exampleContent = @"
name: my_web_app
version: 1.0.0
server: web-server
"@
        
        Set-Content -Path $deployYaml -Value $exampleContent -Encoding UTF8
        
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host "  ⚠ ERROR: No se encontró deploy.yaml" -ForegroundColor Yellow
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Se ha creado un archivo 'deploy.yaml' de ejemplo en:" -ForegroundColor White
        Write-Host "  $deployYaml" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Por favor, edita este archivo con la siguiente información:" -ForegroundColor White
        Write-Host ""
        Write-Host "  name: my_web_app" -ForegroundColor Gray
        Write-Host "    └─ Nombre con el que se configurará en nginx (será la URL)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  version: x.y.z" -ForegroundColor Gray
        Write-Host "    └─ Versión del proyecto" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  server: example-server" -ForegroundColor Gray
        Write-Host "    └─ Nombre del servidor que debe estar en ~/.ssh/config" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host ""
        
        throw "Configura deploy.yaml y vuelve a ejecutar Publish-Web"
    }

    # 1) Cargar helpers
    . "$PSScriptRoot/../Private/PublishHelpers.ps1"
    . "$PSScriptRoot/../Private/Read-SSHConfig.ps1"
    
    # 2) Leer deploy.yaml (name, version, server)
    $deployContent = Get-Content $deployYaml -Raw
    if (-not $deployContent) { 
        throw "No se pudo leer deploy.yaml en '$deployYaml'. Verifica que el archivo existe y no está vacío." 
    }
    
    $deployLines = $deployContent -split "`r?`n" | Where-Object { $_ }
    if (-not $deployLines -or $deployLines.Count -eq 0) {
        throw "deploy.yaml está vacío o solo contiene líneas en blanco en '$deployYaml'"
    }
    
    $AppName = Get-YamlValue -Content $deployLines -Key 'name'
    $versionRaw = Get-YamlValue -Content $deployLines -Key 'version'
    $Server = Get-YamlValue -Content $deployLines -Key 'server'
    
    if (-not $AppName) { throw "No se encontró 'name:' en deploy.yaml" }
    if (-not $versionRaw) { throw "No se encontró 'version:' en deploy.yaml" }
    if (-not $Server) { throw "No se encontró 'server:' en deploy.yaml. Especifica el alias del servidor." }
    
    # Validar que no sean los valores de ejemplo
    if ($AppName -eq 'my_web_app' -and $versionRaw -eq '1.0.0' -and $Server -eq 'web-server') {
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host "  ⚠ ERROR: deploy.yaml contiene valores de ejemplo" -ForegroundColor Yellow
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host ""
        Write-Host "  El archivo deploy.yaml no ha sido modificado." -ForegroundColor White
        Write-Host "  Por favor, edita el archivo con valores reales:" -ForegroundColor White
        Write-Host ""
        Write-Host "  name: my_web_app" -ForegroundColor Gray
        Write-Host "    └─ Cambia 'my_web_app' por el nombre de tu proyecto" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  version: x.y.z" -ForegroundColor Gray
        Write-Host "    └─ Cambia 'x.y.z' por la versión actual" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  server: example-server" -ForegroundColor Gray
        Write-Host "    └─ Verifica que el servidor existe en ~/.ssh/config" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host ""
        throw "Configura deploy.yaml con valores reales y vuelve a ejecutar Publish-Web"
    }
    
    $Version = $versionRaw.Split('+')[0]  # sin build metadata
    
    Write-Host "Publicando $AppName v$Version al servidor '$Server'..." -ForegroundColor Cyan
    
    # 3) Leer configuración SSH desde ~/.ssh/config
    $sshConfig = Read-SSHConfig -HostAlias $Server
    $user = $sshConfig.User
    $ip = $sshConfig.HostName
    $sshPort = $sshConfig.Port
    $privateKeyPath = $sshConfig.IdentityFile
    
    # 4) Validar que existe index.html en la raíz del proyecto
    $indexHtml = Join-Path $cwd "index.html"
    if (!(Test-Path $indexHtml)) {
        throw "No se encontró 'index.html' en $cwd. Asegúrate de tener los archivos web en la raíz del proyecto."
    }
    
    Write-Host "Archivos web encontrados en: $cwd" -ForegroundColor Green
    
    # 5) Preparar rutas remotas
    $RemoteProjectPath = "$RemoteWebRoot/$AppName"
    $RemoteTempPath = "/tmp/${AppName}_web_v${Version}"
    
    # 6) Crear archivo temporal con lista de archivos web a subir
    # Excluir deploy.yaml, README.md y otros archivos de configuración
    Write-Host "Preparando archivos para subir..." -ForegroundColor Cyan
    $excludePatterns = @('deploy.yaml', 'README.md', '.git*', '*.ps1', '*.md', '*.conf')
    $tempDir = Join-Path $env:TEMP "psdevops_web_staging_$([guid]::NewGuid().ToString())"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    
    # Copiar TODO el contenido (archivos y carpetas) excluyendo patrones
    Get-ChildItem -Path $cwd | Where-Object {
        $itemName = $_.Name
        $shouldExclude = $false
        foreach ($pattern in $excludePatterns) {
            if ($itemName -like $pattern) {
                $shouldExclude = $true
                break
            }
        }
        -not $shouldExclude
    } | ForEach-Object {
        if ($_.PSIsContainer) {
            # Es una carpeta, copiar recursivamente
            Copy-Item -Path $_.FullName -Destination $tempDir -Recurse -Force
        } else {
            # Es un archivo, copiar directamente
            Copy-Item -Path $_.FullName -Destination $tempDir -Force
        }
    }
    
    # Verificar que hay archivos para subir
    $webFiles = Get-ChildItem -Path $tempDir -File -Recurse
    if ($webFiles.Count -eq 0) {
        Remove-Item -Path $tempDir -Recurse -Force
        throw "No se encontraron archivos web para subir. Asegúrate de tener index.html, css, js, etc."
    }
    
    Write-Host "Archivos totales a subir: $($webFiles.Count)" -ForegroundColor Green
    
    # Mostrar estructura de carpetas
    $folders = Get-ChildItem -Path $tempDir -Directory
    if ($folders.Count -gt 0) {
        Write-Host "Carpetas: $($folders.Count)" -ForegroundColor Cyan
        $folders | ForEach-Object { Write-Host "  📁 $($_.Name)/" -ForegroundColor DarkCyan }
    }
    
    # Mostrar archivos raíz
    $rootFiles = Get-ChildItem -Path $tempDir -File
    Write-Host "Archivos raíz: $($rootFiles.Count)" -ForegroundColor Cyan
    $rootFiles | ForEach-Object { Write-Host "  📄 $($_.Name)" -ForegroundColor DarkGray }
    
    # 7) Comprimir carpeta web para transferencia eficiente
    Write-Host "Comprimiendo carpeta web..." -ForegroundColor Cyan
    $zipFileName = "${AppName}_web_v${Version}.zip"
    $zipPath = Join-Path $env:TEMP $zipFileName
    
    # Eliminar zip previo si existe
    if (Test-Path $zipPath) {
        Remove-Item $zipPath -Force
    }
    
    # Usar Compress-Archive que maneja correctamente las rutas para Linux
    Compress-Archive -Path "$tempDir\*" -DestinationPath $zipPath -CompressionLevel Optimal -Force
    
    # Limpiar directorio temporal
    Remove-Item -Path $tempDir -Recurse -Force
    
    Write-Host "Archivo comprimido: $zipPath" -ForegroundColor Green
    
    # 8) Subir zip al servidor
    Write-Host "Subiendo archivo al servidor $ip..." -ForegroundColor Cyan
    $remoteZipPath = "/tmp/$zipFileName"
    $scpArgs = @('-i', $privateKeyPath, '-P', $sshPort, $zipPath, "$($user)@$($ip):$remoteZipPath")
    
    & scp @scpArgs 2>&1 | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        throw "Error al subir archivo al servidor (scp exit code: $LASTEXITCODE)"
    }
    
    Write-Host "Archivo subido correctamente." -ForegroundColor Green
    
    # 9) Desplegar en el servidor remoto
    Write-Host "Desplegando en $RemoteProjectPath..." -ForegroundColor Cyan
    
    # Script de despliegue remoto
    $deployScript = @"
#!/bin/bash

# Variables
REMOTE_ZIP='$remoteZipPath'
REMOTE_TEMP='$RemoteTempPath'
REMOTE_PROJECT='$RemoteProjectPath'

echo "Descomprimiendo archivo..."
mkdir -p "`$REMOTE_TEMP"
unzip -q -o "`$REMOTE_ZIP" -d "`$REMOTE_TEMP" 2>&1 | grep -v "backslashes as path separators" || true

echo "Creando carpeta de destino si no existe..."
sudo mkdir -p "`$REMOTE_PROJECT"

echo "Limpiando carpeta de destino..."
sudo rm -rf "`$REMOTE_PROJECT"/*

echo "Copiando contenido a `$REMOTE_PROJECT..."
sudo cp -r "`$REMOTE_TEMP"/. "`$REMOTE_PROJECT"/

echo "Ajustando permisos..."
sudo chown -R www-data:www-data "`$REMOTE_PROJECT"
sudo chmod -R 755 "`$REMOTE_PROJECT"

echo "Limpiando archivos temporales..."
rm -rf "`$REMOTE_TEMP"
rm -f "`$REMOTE_ZIP"

echo "Despliegue completado exitosamente."
"@
    
    # Ejecutar script remoto
    $exitCode = Invoke-RemoteScript -ScriptContent $deployScript `
                                    -User $user -IP $ip -Port $sshPort `
                                    -KeyPath $privateKeyPath `
                                    -ScriptPrefix "psdevops_publish_web_"
    
    if ($exitCode -ne 0) {
        throw "El despliegue en el servidor falló con código $exitCode"
    }
    
    # 10) Configurar nginx si es necesario
    Write-Host "Verificando configuración de nginx..." -ForegroundColor Cyan
    
    # Crear script temporal para verificar configuración
    $nginxCheckScript = @"
#!/bin/bash
APP_NAME='$AppName'
NGINX_DEFAULT='/etc/nginx/sites-available/default'

if grep -q "location /`${APP_NAME}/" "`$NGINX_DEFAULT" 2>/dev/null; then
    echo "CONFIGURED"
else
    echo "NOT_CONFIGURED"
fi
"@
    
    $checkTmpFile = New-UnixTempFile -Content $nginxCheckScript -Prefix "psdevops_nginx_check_"
    
    try {
        $remoteName = [IO.Path]::GetFileName($checkTmpFile)
        $remotePath = "/tmp/$remoteName"
        
        # Subir y ejecutar script de verificación
        & scp -i $privateKeyPath -P $sshPort $checkTmpFile "$($user)@$($ip):$remotePath" 2>&1 | Out-Null
        $checkResult = & ssh -i $privateKeyPath -p $sshPort "$($user)@$($ip)" "bash $remotePath; rm -f $remotePath" 2>&1 | Select-Object -Last 1
        
        if ($checkResult -like "*NOT_CONFIGURED*") {
            Write-Host "⚠ Configuración de nginx no encontrada. Creando..." -ForegroundColor Yellow
        
        $nginxConfigScript = @"
#!/bin/bash
set -e

APP_NAME='$AppName'
NGINX_DEFAULT='/etc/nginx/sites-available/default'
BACKUP_FILE="/tmp/nginx_default_backup_`$(date +%s).conf"

echo "Creando backup de nginx default..."
sudo cp "`$NGINX_DEFAULT" "`$BACKUP_FILE"

echo "Verificando que existe el server block..."
if ! grep -q "listen 80 default_server" "`$NGINX_DEFAULT"; then
    echo "ERROR: No se encuentra el server block principal en `$NGINX_DEFAULT"
    exit 1
fi

echo "Agregando configuración para `$APP_NAME..."

# Crear configuración temporal
cat > /tmp/nginx_location_$AppName.conf <<'ENDCONFIG'

	# ==========================================
	# APLICACIÓN: $AppName
	# ==========================================
	# Redirección: /app -> /app/
	location = /$AppName {
		return 301 /$AppName/;
	}
	
	location /$AppName/ {
		alias /var/www/$AppName/;
		index index.html index.htm;
		
		# Reescribir base href dinámicamente para Flutter/SPA
		sub_filter '<base href="/">' '<base href="/$AppName/">';
		sub_filter_once on;
		
		# Para aplicaciones SPA: servir index.html para rutas no encontradas
		try_files `$uri `$uri/ /$AppName/index.html;
		
		access_log /var/log/nginx/$AppName.access.log;
		error_log  /var/log/nginx/$AppName.error.log;
	}
ENDCONFIG

# Usar awk para insertar antes de la sección DEFAULT
sudo awk '
    /# DEFAULT:/ || (/^[[:space:]]*location \/ \{/ && !seen_app_location) {
        if (!inserted) {
            while ((getline line < "/tmp/nginx_location_$AppName.conf") > 0) {
                print line
            }
            close("/tmp/nginx_location_$AppName.conf")
            inserted = 1
        }
    }
    { print }
' "`$NGINX_DEFAULT" > /tmp/nginx_default_new.conf

# Reemplazar el archivo original
sudo mv /tmp/nginx_default_new.conf "`$NGINX_DEFAULT"

# Limpiar archivo temporal
rm -f /tmp/nginx_location_$AppName.conf

echo "Validando configuración de nginx..."
if ! sudo nginx -t; then
    echo "ERROR: Configuración de nginx inválida. Restaurando backup..."
    sudo cp "`$BACKUP_FILE" "`$NGINX_DEFAULT"
    sudo nginx -t
    exit 1
fi

echo "Recargando nginx..."
sudo systemctl reload nginx

echo "Configuración de nginx completada exitosamente."
"@
        
        $exitCode = Invoke-RemoteScript -ScriptContent $nginxConfigScript `
                                        -User $user -IP $ip -Port $sshPort `
                                        -KeyPath $privateKeyPath `
                                        -ScriptPrefix "psdevops_nginx_config_"
        
        if ($exitCode -ne 0) {
            Write-Host "⚠ Advertencia: No se pudo configurar nginx automáticamente." -ForegroundColor Yellow
            Write-Host "  Configura manualmente agregando este bloque a /etc/nginx/sites-available/default:" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  location /$AppName/ {" -ForegroundColor Gray
            Write-Host "      alias /var/www/$AppName/;" -ForegroundColor Gray
            Write-Host "      index index.html index.htm;" -ForegroundColor Gray
            Write-Host "      try_files `$uri `$uri/ =404;" -ForegroundColor Gray
            Write-Host "  }" -ForegroundColor Gray
            Write-Host ""
        } else {
            Write-Host "✓ Nginx configurado correctamente" -ForegroundColor Green
        }
    } else {
        Write-Host "✓ Nginx ya está configurado para $AppName" -ForegroundColor Green
    }
    } finally {
        Remove-Item -LiteralPath $checkTmpFile -ErrorAction SilentlyContinue
    }
    
    # 11) Limpiar archivo local
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    
    Write-Host ""
    Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  ✓ Despliegue completado: $AppName v$Version" -ForegroundColor Green
    Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  📂 Ubicación: $RemoteProjectPath" -ForegroundColor White
    Write-Host "  🌐 URL: http://$ip/$AppName/" -ForegroundColor White
    Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}
