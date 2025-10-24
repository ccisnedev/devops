# PublishHelpers.ps1
# Funciones helper para simplificar Publish-ShelfApi.ps1

<#
.SYNOPSIS
Extrae un valor de un archivo YAML simple.

.DESCRIPTION
Busca una clave en formato "key: value" y retorna el valor sin comillas.
No es un parser YAML completo, solo para casos simples.

.PARAMETER Content
Array de líneas del archivo YAML.

.PARAMETER Key
Nombre de la clave a buscar.

.EXAMPLE
Get-YamlValue $content 'name'
#>
function Get-YamlValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$Content,
        
        [Parameter(Mandatory=$true)]
        [string]$Key
    )
    
    $line = $Content | Where-Object { $_ -match "^\s*$Key\s*:" } | Select-Object -First 1
    if (-not $line) { return $null }
    
    $value = ($line -replace "^\s*$Key\s*:\s*", '').Trim()
    $value = $value -replace '^["'']|["'']$', ''  # Remover comillas
    return $value
}

<#
.SYNOPSIS
Lee un archivo .env y extrae todas las variables de entorno.

.DESCRIPTION
Parsea un archivo .env ignorando comentarios y líneas vacías.
Retorna un hashtable con las variables y extrae PORT si existe.

.PARAMETER Path
Ruta al archivo .env.

.PARAMETER DefaultPort
Puerto por defecto si no se encuentra PORT en .env (default: 8080).

.EXAMPLE
$config = Read-DotEnv "D:\proyecto\.env"
$envVars = $config.Env
$port = $config.Port
#>
function Read-DotEnv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        
        [Parameter()]
        [int]$DefaultPort = 8080
    )
    
    $env = @{}
    $port = $DefaultPort
    
    if (-not (Test-Path $Path)) {
        return @{ Env = $env; Port = $port }
    }
    
    Get-Content $Path | Where-Object { $_ -and ($_ -notmatch '^\s*#') } | ForEach-Object {
        if ($_ -match '^\s*([^=]+)\s*=\s*(.*)$') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            
            # Remover comillas exteriores
            if ($value -match '^["''](.+)["'']$') {
                $value = $Matches[1]
            }
            
            $env[$key] = $value
            
            # Extraer PORT si es numérico
            if ($key -eq 'PORT' -and $value -match '^\d+$') {
                $port = [int]$value
            }
        }
    }
    
    return @{ 
        Env = $env
        Port = $port
    }
}

<#
.SYNOPSIS
Valida y obtiene una distribución WSL disponible.

.DESCRIPTION
Verifica que WSL esté instalado, busca la distro preferida o hace fallback
a la primera distro Ubuntu disponible.

.PARAMETER Preferred
Nombre de la distro preferida (default: "Ubuntu").

.EXAMPLE
$distro = Get-ValidWSLDistro -Preferred "Ubuntu"
#>
function Get-ValidWSLDistro {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Preferred = "Ubuntu"
    )
    
    # Verificar que wsl.exe existe
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw "wsl.exe no está disponible en PATH. Habilita WSL en Windows. Ejecuta 'wsl -l -v' para comprobar."
    }
    
    # Obtener listado de distros instaladas
    $wslListRaw = & wsl.exe --list --quiet 2>&1
    $distros = $wslListRaw -replace '\p{C}', '' -split '\r?\n' | 
               ForEach-Object { $_.Trim() } |
               Where-Object { $_ -ne '' }
    
    if (-not $distros -or $distros.Count -eq 0) {
        throw "No hay distribuciones WSL instaladas. Instala una con: wsl --install -d $Preferred"
    }
    
    # Verificar si la preferida existe
    if ($distros -contains $Preferred) {
        return $Preferred
    }
    
    # Fallback a cualquier Ubuntu
    $ubuntu = $distros | Where-Object { $_ -like 'Ubuntu*' } | Select-Object -First 1
    if ($ubuntu) {
        Write-Host "Advertencia: distro '$Preferred' no encontrada. Usando '$ubuntu' (fallback)." -ForegroundColor Yellow
        return $ubuntu
    }
    
    # Si no hay Ubuntu, fallar con información útil
    $available = $distros -join ', '
    throw "Distro '$Preferred' no encontrada. Distros instaladas: $available. Instala la correcta con: wsl --install -d $Preferred"
}

<#
.SYNOPSIS
Construye el string de variables de entorno para PM2.

.DESCRIPTION
Convierte un hashtable de variables de entorno en una cadena de parámetros
--env KEY='VALUE' para PM2, escapando comillas correctamente.

.PARAMETER EnvVars
Hashtable con las variables de entorno.

.EXAMPLE
$envString = New-PM2EnvString $EnvVars
# Resultado: "--env PORT='4321' --env DB_HOST='localhost' ..."
#>
function New-PM2EnvString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$EnvVars
    )
    
    if ($EnvVars.Count -eq 0) {
        return ""
    }
    
    $parts = @()
    foreach ($key in $EnvVars.Keys) {
        $value = $EnvVars[$key]
        # Escapar comillas simples para bash
        $escapedValue = $value -replace "'", "'\\''"
        $parts += "--env $key='$escapedValue'"
    }
    
    return $parts -join " "
}

<#
.SYNOPSIS
Crea un archivo temporal con contenido UTF-8 sin BOM y line endings Unix.

.DESCRIPTION
Helper para crear scripts bash temporales desde PowerShell asegurando
la codificación correcta (UTF-8 sin BOM, LF line endings).

.PARAMETER Content
Contenido del archivo.

.PARAMETER Prefix
Prefijo para el nombre del archivo temporal (default: "psdevops_").

.EXAMPLE
$tmpFile = New-UnixTempFile -Content $scriptContent -Prefix "build_"
#>
function New-UnixTempFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Content,
        
        [Parameter()]
        [string]$Prefix = "psdevops_"
    )
    
    # Normalizar a LF
    $unixContent = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    
    # Crear archivo temporal
    $tmpPath = [IO.Path]::Combine($env:TEMP, "${Prefix}{0}.sh" -f ([guid]::NewGuid().ToString()))
    
    # Escribir como UTF-8 sin BOM
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmpPath, $unixContent, $utf8NoBom)
    
    return $tmpPath
}

<#
.SYNOPSIS
Ejecuta un script bash en el servidor remoto vía SSH.

.DESCRIPTION
Sube un script temporal al servidor remoto, lo ejecuta y lo elimina.
Maneja correctamente la codificación y limpieza de archivos temporales.

.PARAMETER ScriptContent
Contenido del script bash a ejecutar.

.PARAMETER User
Usuario SSH.

.PARAMETER IP
IP del servidor.

.PARAMETER Port
Puerto SSH.

.PARAMETER KeyPath
Ruta a la clave privada SSH.

.PARAMETER ScriptPrefix
Prefijo para el archivo temporal (default: "psdevops_remote_").

.EXAMPLE
Invoke-RemoteScript -ScriptContent $installScript -User "user" -IP "192.168.1.1" -Port 22 -KeyPath "~/.ssh/id_rsa"
#>
function Invoke-RemoteScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ScriptContent,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$IP,
        
        [Parameter(Mandatory=$true)]
        [int]$Port,
        
        [Parameter(Mandatory=$true)]
        [string]$KeyPath,
        
        [Parameter()]
        [string]$ScriptPrefix = "psdevops_remote_"
    )
    
    $tmpLocal = New-UnixTempFile -Content $ScriptContent -Prefix $ScriptPrefix
    
    try {
        $remoteName = [IO.Path]::GetFileName($tmpLocal)
        $remotePath = "/tmp/$remoteName"
        
        # Subir script (suprimir salida)
        & scp -i $KeyPath -P $Port $tmpLocal "$($User)@$($IP):$remotePath" 2>&1 | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            throw "Error al subir script al servidor remoto (scp exit code: $LASTEXITCODE)"
        }
        
        # Ejecutar y eliminar (capturar salida completa)
        # IMPORTANTE: stderr (warnings) no son errores, solo el exit code != 0
        $remoteCmd = "bash $remotePath ; rc=`$?; rm -f $remotePath; exit `$rc"
        $ErrorActionPreference = 'Continue'  # Permitir stderr sin detener
        $output = & ssh -i $KeyPath -p $Port "$($User)@$($IP)" $remoteCmd 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'  # Restaurar
        
        # Siempre mostrar salida (incluye warnings y mensajes informativos)
        if ($output) {
            $output | ForEach-Object { 
                $line = $_.ToString()
                # Colorear warnings en amarillo, errores en rojo, resto normal
                if ($line -match '^WARNING:') {
                    Write-Host $line -ForegroundColor Yellow
                } elseif ($line -match '^ERROR:') {
                    Write-Host $line -ForegroundColor Red
                } else {
                    Write-Host $line
                }
            }
        }
        
        return $exitCode
    }
    finally {
        Remove-Item -LiteralPath $tmpLocal -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
Carga un script bash externo y reemplaza placeholders.

.DESCRIPTION
Lee un archivo .sh desde el directorio scripts/, reemplaza variables
tipo __PLACEHOLDER__ con valores reales, y retorna el contenido procesado.

.PARAMETER ScriptName
Nombre del archivo de script (ej: "Build-DartBinary.sh").

.PARAMETER Placeholders
Hashtable con los valores a reemplazar. Keys deben incluir __ antes y después.

.EXAMPLE
$script = Get-BashScript -ScriptName "Build-DartBinary.sh" -Placeholders @{
    '__WSLPROJECT__' = '/mnt/d/myproject'
    '__WSLWINOUT__' = '/mnt/c/temp/output'
}
#>
function Get-BashScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ScriptName,
        
        [Parameter(Mandatory=$true)]
        [hashtable]$Placeholders
    )
    
    # Construir ruta al script
    $scriptPath = Join-Path $PSScriptRoot "scripts\$ScriptName"
    
    if (-not (Test-Path $scriptPath)) {
        throw "Script no encontrado: $scriptPath"
    }
    
    # Leer contenido
    $content = Get-Content $scriptPath -Raw
    
    # Reemplazar cada placeholder
    foreach ($key in $Placeholders.Keys) {
        $value = $Placeholders[$key]
        $content = $content -replace [regex]::Escape($key), $value
    }
    
    return $content
}
