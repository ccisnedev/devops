<#
.SYNOPSIS
[DEPRECADO] Despliega la carpeta web generada al servidor remoto.

.DESCRIPTION
DEPRECADO — se eliminará en la próxima versión major. Use `Publish-FlutterWeb`
(-Init/-Plan/-Apply), que despliega con releases inmutables versionadas y rollback
vía el symlink `current`, en lugar de este flujo destructivo.

El cmdlet `Publish-FlutterWebLegacy` copia la carpeta web generada a un servidor remoto mediante SSH.
Lee la configuración del host desde ~/.ssh/config y utiliza SSH y SCP directamente
para transferir los archivos al servidor remoto.

Nota de riesgo: este cmdlet ejecuta `sudo rm -rf /var/www/<name>/*` en el servidor,
lo que borra por completo el contenido publicado (incluidas sub-apps y cualquier
release previa) antes de copiar. `Publish-FlutterWeb` nunca hace esto.

.PARAMETER server
El nombre del servidor al que se desea desplegar la carpeta web. Este parámetro es obligatorio.

.EXAMPLE
Publish-FlutterWebLegacy -server "demo-web"
Copia la carpeta web generada al servidor "demo-web".

.NOTES
Versión: 1.1.0
Autor: @ccisnedev
Estado: DEPRECADO — reemplazado por `Publish-FlutterWeb`. Ver CHANGELOG (5.6.0).
#>
function Publish-FlutterWebLegacy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$server
    )

    # ── Deprecación ──────────────────────────────────────────────────────────
    # Reemplazado por Publish-FlutterWeb (releases inmutables + rollback). Este
    # cmdlet sigue disponible por retrocompatibilidad y se elimina en el próximo major.
    Write-Warning "Publish-FlutterWebLegacy está DEPRECADO y se eliminará en la próxima versión major. Migre a 'Publish-FlutterWeb' (-Init/-Plan/-Apply): releases inmutables con rollback vía symlink 'current'. Legacy ejecuta 'sudo rm -rf /var/www/<name>/*', borrando sub-apps y releases previas."

    #version
    $version = "1.1.0"
    Write-Host "[$version] Publicando la carpeta web en el servidor '$server'..." -ForegroundColor Cyan

    # Obtener la versión y el nombre de la aplicación del pubspec.yaml
    $content = Get-Content -Path "./pubspec.yaml"
    # version
    $versionLine = $content | Where-Object { $_ -match "version:" }
    $version = ($versionLine -replace "version: ", "").Split('+')[0]
    # nombre
    $nameLine = $content | Where-Object { $_ -match "name:" }
    $name = $nameLine -replace "name: ", ""
    
    
        . "$PSScriptRoot/../Private/Read-SSHConfig.ps1"

        try {
            $sshConfig = Read-SSHConfig -HostAlias $server
        }
        catch {
        Write-Host "Servidor desconocido: $server" -ForegroundColor Red
        return
    }

        $username = $sshConfig.User
        $ip = $sshConfig.HostName
        $port = $sshConfig.Port
        $privateKeyPath = $sshConfig.IdentityFile
    
    # Variables de la carpeta de lanzamiento y el nombre de la carpeta web
    $webFolder = "app_${name}_v${version}_web"
    $localWebPath = "./release/$webFolder"
    # $destinationPath es temporal y específico para cada versión publicada
    $destinationPath = "/home/$username/frontend/$webFolder"
    #$remoteWebPath es la ruta fija donde siempre debe estar la web activa para el servidor.
    $remoteWebPath = "/home/$username/frontend/${name}_web"
    
    # Verificar si la carpeta web existe en local
    if (!(Test-Path -Path $localWebPath)) {
        Write-Host "La carpeta web '$localWebPath' no existe." -ForegroundColor Red
        return
    } else {
        Write-Host "La carpeta web '$localWebPath' encontrada." -ForegroundColor Green
    }
    
    Write-Host "Conectando al servidor '$server'..." -ForegroundColor Cyan

    # Comando SCP para copiar la carpeta web al servidor remoto
    $scpCommand = "scp -i ${privateKeyPath} -P ${port} -r ${localWebPath} ${username}@${ip}:${destinationPath}"
    Write-Host $scpCommand -ForegroundColor Cyan

    Write-Host "Desplegando la carpeta web '$localWebPath' al servidor '$server' en '$destinationPath'..." -ForegroundColor Cyan
    Invoke-Expression $scpCommand

    # Comando para conexion SSH al servidor
    $sshCommand = "ssh -i ${privateKeyPath} -p ${port} ${username}@${ip}"
    Write-Host "Script SSH: $sshCommand" -ForegroundColor Cyan
    
    # Los siguientes comandos están encerrados entre comillas simples para
    # asegurarse de que se pase correctamente al servidor remoto y no sean
    # evaluados localmente
    # "' comando '"

    # Cambiar los permisos de la carpeta en el servidor remoto
    $chmodCommand = "'chmod -R 775 ${destinationPath}'"
    Write-Host "Cambio de permisos: $chmodCommand" -ForegroundColor Cyan
    Invoke-Expression "$sshCommand $chmodCommand"

    # Verificar si ya existe la carpeta "web" y eliminarla si exite
    $checkAndRemoveCommand = "'if [ -d ${remoteWebPath} ]; then rm -rf ${remoteWebPath}; fi'"
    Write-Host "Verificar si existe y borrar $remoteWebPath" -ForegroundColor Cyan
    Invoke-Expression "$sshCommand $checkAndRemoveCommand"

    # Copia el contenido a la carpeta "${name}_web"
    $copyCommand = "'cp -r ${destinationPath} ${remoteWebPath}'"
    Write-Host "Copia: $copyCommand" -ForegroundColor Cyan
    Invoke-Expression "$sshCommand $copyCommand"

    # Enviar comando a la carpeta de nginx
    $rmCommand = "'sudo rm -rf /var/www/$name/*'"
    Write-Host "Borrando contenido de /var/www/$name" -ForegroundColor Cyan
    Invoke-Expression "$sshCommand $rmCommand"
    
    # Copiar el contenido de la carpeta web a la carpeta de nginx
    $copy2Command = "'sudo cp -r $remoteWebPath/. /var/www/$name/'"
    Write-Host "Copiando contenido de $remoteWebPath a /var/www/$name" -ForegroundColor Cyan
    Invoke-Expression "$sshCommand $copy2Command"

    Write-Host "Despliegue completado en el servidor '$server'." -ForegroundColor Green
}