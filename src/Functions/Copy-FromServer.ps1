<#
.SYNOPSIS
Copia un archivo desde un servidor remoto al equipo local usando scp.

.DESCRIPTION
El cmdlet `Copy-FromServer` permite copiar un archivo desde un servidor remoto configurado en SSHConfig.ps1 al equipo local.

.PARAMETER server
El nombre del servidor desde el cual se copiará el archivo. Este parámetro es obligatorio.

.PARAMETER RemotePath
Ruta completa del archivo en el servidor remoto. Este parámetro es obligatorio.

.PARAMETER LocalPath
Ruta de destino en el equipo local. Este parámetro es obligatorio.

.EXAMPLE
Copy-FromServer isabel '/home/cacsiadmin/archivo.txt' './descargas/archivo.txt'
Copia el archivo 'archivo.txt' desde el servidor 'isabel' a la carpeta local './descargas/'.

.NOTES
Versión: 1.0.0
Autor: @ccisnedev
#>
function Copy-FromServer {
    param(
        [Parameter(Mandatory=$true)]
        [string]$server,
        [Parameter(Mandatory=$true)]
        [string]$RemotePath,
        [Parameter(Mandatory=$true)]
        [string]$LocalPath
    )
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

    # Comando SCP para copiar el archivo desde el servidor remoto
    $scpCommand = "scp -i ${privateKeyPath} -P ${port} ${username}@${ip}:${RemotePath} ${LocalPath}"
    Write-Host "Ejecutando: $scpCommand" -ForegroundColor Cyan
    Invoke-Expression $scpCommand
    Write-Host "Archivo copiado desde '${server}:${RemotePath}' a '${LocalPath}'." -ForegroundColor Green
}
