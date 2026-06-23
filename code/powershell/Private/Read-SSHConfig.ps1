<#
.SYNOPSIS
Lee y parsea el archivo SSH config estándar (~/.ssh/config)

.DESCRIPTION
Extrae la configuración de un host específico desde el archivo SSH config,
incluyendo HostName, User, Port, e IdentityFile.

.PARAMETER HostAlias
El alias del host a buscar en el archivo SSH config

.PARAMETER ConfigPath
Ruta al archivo SSH config. Por defecto usa ~/.ssh/config
Soporta Windows ($env:USERPROFILE) y Linux ($env:HOME).

.EXAMPLE
$config = Read-SSHConfig -HostAlias "demo-web"
# Retorna: @{ HostName = "web.example.test"; User = "deploy"; Port = 22; IdentityFile = "~/.ssh/id_ed25519" }

.NOTES
Autor: @ccisnedev
#>
function Read-SSHConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$HostAlias,
        
        [Parameter(Mandatory=$false)]
        [string]$ConfigPath = (Join-Path $(if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }) ".ssh/config")
    )
    
    if (!(Test-Path $ConfigPath)) {
        throw "No se encontró el archivo SSH config en: $ConfigPath"
    }
    
    $content = Get-Content $ConfigPath -Raw
    $lines = $content -split "`r?`n"
    
    $currentHost = $null
    $config = @{}
    $found = $false
    
    foreach ($line in $lines) {
        # Ignorar comentarios y líneas vacías
        if ($line -match '^\s*#' -or $line -match '^\s*$') {
            continue
        }
        
        # Detectar inicio de bloque Host
        if ($line -match '^\s*Host\s+(.+)$') {
            $hostName = $matches[1].Trim()
            
            # Si ya encontramos el host que buscamos, salir
            if ($found) {
                break
            }
            
            # Si es el host que buscamos, empezar a capturar
            if ($hostName -eq $HostAlias) {
                $currentHost = $hostName
                $found = $true
                $config = @{
                    Host = $hostName
                    HostName = $null
                    User = $null
                    Port = 22  # Puerto por defecto
                    IdentityFile = $null
                }
            }
            continue
        }
        
        # Si estamos capturando el host correcto, extraer propiedades
        if ($found -and $currentHost -eq $HostAlias) {
            if ($line -match '^\s*HostName\s+(.+)$') {
                $config.HostName = $matches[1].Trim()
            }
            elseif ($line -match '^\s*User\s+(.+)$') {
                $config.User = $matches[1].Trim()
            }
            elseif ($line -match '^\s*Port\s+(.+)$') {
                $config.Port = [int]($matches[1].Trim())
            }
            elseif ($line -match '^\s*IdentityFile\s+(.+)$') {
                $config.IdentityFile = $matches[1].Trim()
            }
        }
    }
    
    if (-not $found) {
        throw "No se encontró el host '$HostAlias' en el archivo SSH config: $ConfigPath"
    }
    
    # Validar campos obligatorios
    if (-not $config.HostName) {
        throw "El host '$HostAlias' no tiene configurado 'HostName' en SSH config"
    }
    if (-not $config.User) {
        throw "El host '$HostAlias' no tiene configurado 'User' en SSH config"
    }
    if (-not $config.IdentityFile) {
        throw "El host '$HostAlias' no tiene configurado 'IdentityFile' en SSH config"
    }
    
    return $config
}
