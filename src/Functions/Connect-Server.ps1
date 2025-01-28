<#
.SYNOPSIS
Se conecta a un servidor específico mediante SSH usando una clave privada.

.DESCRIPTION
El cmdlet `Connect-Server` permite conectarse a un servidor específico mediante SSH. Utiliza una clave privada para la autenticación y se conecta a la dirección IP y puerto especificados para el servidor. La información de los servidores está predefinida en un hash table dentro del script.

.PARAMETER server
El nombre del servidor al que se desea conectar. Este parámetro es obligatorio.

.EXAMPLE
Connect-Server -server "isabel"
Se conecta al servidor "isabel" usando SSH con la clave privada especificada.

.NOTES
Versión: 1.0.0
Autor: @ccisnedev
#>
function Connect-Server {
    param(
        [Parameter(Mandatory=$true)]
        [string]$server
    )
    
    # Importar el archivo de configuración
    . "$PSScriptRoot/../Private/SSHConfig.ps1"
    
    if ($servers.ContainsKey($server)) {
        $serverInfo = $servers[$server]
        $username = $serverInfo["username"]
        $ip = $serverInfo["ip"]
        $port = $serverInfo["port"]
        
        try {
            ssh -i $privateKeyPath -p $port "$username@$ip"
            return $true  # Conexión exitosa
        } catch {
            Write-Host "Error al conectar al servidor: $_" -ForegroundColor Red
            return $false  # Error al conectar
        }
    } else {
        throw [System.Management.Automation.ErrorRecord]::new(
          "Unknown server: $server", # Mensaje
          "UnknownServer", # Error ID
          [System.Management.Automation.ErrorCategory]::InvalidArgument, # Categoria del error
          $server # target Object
        )
    }
}


<#
.SYNOPSIS
Llama al cmdlet `Connect-Server` con el parámetro especificado.

.DESCRIPTION
La función `server` actúa como un envoltorio para el cmdlet `Connect-Server`.
Toma un parámetro `$server` y lo pasa al cmdlet `Connect-Server`
para establecer una conexión SSH con el servidor especificado.

.PARAMETER server
El nombre del servidor al que se desea conectar. Este parámetro es obligatorio.

.EXAMPLE
server "isabel"
Llama al cmdlet `Connect-Server` para conectarse al servidor "isabel" usando
SSH con la clave privada especificada.

.NOTES
Versión: 1.0.0
Autor: @ccisnedev
#>
# function server { param($server); & Connect-Server -server $server }
New-Alias -Name server -Value Connect-Server