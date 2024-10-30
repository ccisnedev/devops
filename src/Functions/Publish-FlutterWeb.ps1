<#
.SYNOPSIS
Despliega la carpeta web generada al servidor remoto.

.DESCRIPTION
El cmdlet `Deploy-FlutterWeb` copia la carpeta web generada a un servidor remoto mediante SSH.
Reutiliza la función `Connect-Server` para conectar al servidor remoto sin contraseña y utiliza `scp` para transferir los archivos.

.PARAMETER server
El nombre del servidor al que se desea desplegar la carpeta web. Este parámetro es obligatorio.

.EXAMPLE
Deploy-FlutterWeb -server "isabel"
Copia la carpeta web generada al servidor "isabel".

.NOTES
Versión: 1.0.2
Autor: @ccisnedev
#>
function Publish-FlutterWeb {
    param(
        [Parameter(Mandatory=$true)]
        [string]$server
    )
    #version
    $version = "1.0.2"
    Write-Host "[$version] Publicando la carpeta web en el servidor '$server'..." -ForegroundColor Cyan

    # Obtener la versión y el nombre de la aplicación del pubspec.yaml
    $content = Get-Content -Path "./pubspec.yaml"
    # version
    $versionLine = $content | Where-Object { $_ -match "version:" }
    $version = ($versionLine -replace "version: ", "").Split('+')[0]
    # nombre
    $nameLine = $content | Where-Object { $_ -match "name:" }
    $name = $nameLine -replace "name: ", ""
    
    # Variables de la carpeta de lanzamiento y el nombre de la carpeta web
    $releasePath = "./release"
    $webFolder = "app_${name}_v${version}_web"
    $localWebPath = "$releasePath/$webFolder"
    $remoteWebPath = "/home/cacsiadmin/frontend/${name}_web_test"

    # Verificar si la carpeta web existe
    if (!(Test-Path -Path $localWebPath)) {
        Write-Host "La carpeta web '$localWebPath' no existe." -ForegroundColor Red
        return
    } else {
        Write-Host "La carpeta web '$localWebPath' existe." -ForegroundColor Green
    }

    # Importar el archivo de configuración
    . "$PSScriptRoot/../Private/SSHConfig.ps1"

    # Verificar si el servidor existe en la configuración
    if ($servers.ContainsKey($server)) {
        $serverInfo = $servers[$server]
        $username = $serverInfo["username"]
        $ip = $serverInfo["ip"]
        $port = $serverInfo["port"]

    } else {
        Write-Host "Servidor desconocido: $server" -ForegroundColor Red
        return
    }

    # Si el servidor existe continua con el despliegue
    Write-Host "Conectando al servidor '$server'..." -ForegroundColor Cyan
    
    # Comando SCP para copiar la carpeta web al servidor remoto
    $destinationPath = "/home/cacsiadmin/frontend/$webFolder"
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
    Write-Host "Verificar si existe y borrar $checkAndRemoveCommand" -ForegroundColor Cyan
    Invoke-Expression "$sshCommand $checkAndRemoveCommand"

    # Renombrar la carpeta a "web"
    $renameCommand = "'mv ${destinationPath} ${remoteWebPath}'"
    Write-Host "Renombrar: $renameCommand" -ForegroundColor Cyan
    Invoke-Expression "$sshCommand $renameCommand"

    # Enviar comando a la carpeta de nginx
    # sudo rm -rf "/var/www/$name/*"
    # sudo cp -r "$HOME/frontend/${name}_web/." "/var/www/$name/"

    Write-Host "Despliegue completado en el servidor '$server'." -ForegroundColor Green
}