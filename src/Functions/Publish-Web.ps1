<#
.SYNOPSIS
Despliega contenido web estático directamente a /var/www/<nombre> en el servidor remoto.

.DESCRIPTION
El cmdlet `Publish-Web` lee la configuración del proyecto desde pubspec.yaml (name, version, server),
comprime la carpeta de build/web, la sube al servidor remoto mediante SSH/SCP y la despliega 
directamente en /var/www/<nombre> para servir con nginx/apache.

Se debe ejecutar desde la raíz del proyecto donde existe pubspec.yaml con:
- name: nombre del proyecto
- version: versión de la aplicación
- server: alias del servidor configurado en ~/.ssh/config

.EXAMPLE
Publish-Web
Lee pubspec.yaml, detecta el servidor y despliega el contenido web.

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

    # 0) Validar que estamos en un proyecto con pubspec.yaml
    $cwd = (Get-Location).Path
    $pubspec = Join-Path $cwd "pubspec.yaml"
    
    if (!(Test-Path $pubspec)) { 
        throw "No se encontró pubspec.yaml en $cwd. Ejecuta este cmdlet dentro del proyecto web." 
    }

    # 1) Cargar helpers
    . "$PSScriptRoot/../Private/PublishHelpers.ps1"
    . "$PSScriptRoot/../Private/Read-SSHConfig.ps1"
    
    # 2) Leer pubspec.yaml (name, version, server)
    $pubspecContent = Get-Content $pubspec -Raw
    if (-not $pubspecContent) { 
        throw "No se pudo leer pubspec.yaml en '$pubspec'. Verifica que el archivo existe y no está vacío." 
    }
    
    $pubspecLines = $pubspecContent -split "`r?`n" | Where-Object { $_ }
    if (-not $pubspecLines -or $pubspecLines.Count -eq 0) {
        throw "pubspec.yaml está vacío o solo contiene líneas en blanco en '$pubspec'"
    }
    
    $AppName = Get-YamlValue -Content $pubspecLines -Key 'name'
    $versionRaw = Get-YamlValue -Content $pubspecLines -Key 'version'
    $Server = Get-YamlValue -Content $pubspecLines -Key 'server'
    
    if (-not $AppName) { throw "No se encontró 'name:' en pubspec.yaml" }
    if (-not $versionRaw) { throw "No se encontró 'version:' en pubspec.yaml" }
    if (-not $Server) { throw "No se encontró 'server:' en pubspec.yaml. Especifica el alias del servidor." }
    
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
    # Excluir pubspec.yaml, README.md y otros archivos de configuración
    Write-Host "Preparando archivos para subir..." -ForegroundColor Cyan
    $excludePatterns = @('pubspec.yaml', 'README.md', '.git*', '*.ps1', '*.md', '*.conf')
    $tempDir = Join-Path $env:TEMP "psdevops_web_staging_$([guid]::NewGuid().ToString())"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    
    # Copiar archivos web al directorio temporal (excluyendo patrones)
    Get-ChildItem -Path $cwd -File | Where-Object {
        $fileName = $_.Name
        $shouldExclude = $false
        foreach ($pattern in $excludePatterns) {
            if ($fileName -like $pattern) {
                $shouldExclude = $true
                break
            }
        }
        -not $shouldExclude
    } | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $tempDir -Force
    }
    
    # Verificar que hay archivos para subir
    $webFiles = Get-ChildItem -Path $tempDir -File
    if ($webFiles.Count -eq 0) {
        Remove-Item -Path $tempDir -Recurse -Force
        throw "No se encontraron archivos web para subir. Asegúrate de tener index.html, css, js, etc."
    }
    
    Write-Host "Archivos a subir: $($webFiles.Count)" -ForegroundColor Green
    $webFiles | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor DarkGray }
    
    # 7) Comprimir carpeta web para transferencia eficiente
    Write-Host "Comprimiendo carpeta web..." -ForegroundColor Cyan
    $zipFileName = "${AppName}_web_v${Version}.zip"
    $zipPath = Join-Path $env:TEMP $zipFileName
    
    # Eliminar zip previo si existe
    if (Test-Path $zipPath) {
        Remove-Item $zipPath -Force
    }
    
    # Comprimir usando .NET (más rápido y confiable que Compress-Archive para muchos archivos)
    Add-Type -Assembly System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $zipPath, 'Optimal', $false)
    
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
set -e

# Variables
REMOTE_ZIP='$remoteZipPath'
REMOTE_TEMP='$RemoteTempPath'
REMOTE_PROJECT='$RemoteProjectPath'

echo "Descomprimiendo archivo..."
mkdir -p "`$REMOTE_TEMP"
unzip -q -o "`$REMOTE_ZIP" -d "`$REMOTE_TEMP"

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
		try_files `$uri `$uri/ =404;
		
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
