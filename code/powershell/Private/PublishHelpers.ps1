# PublishHelpers.ps1
# Funciones helper compartidas para despliegues y publicación remota

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
Normaliza el basePath de un API para construir URLs.

.DESCRIPTION
Garantiza slash inicial y elimina slashes finales. Una cadena vacia o "/"
retorna vacio (la URL resultante queda en la raiz, retrocompatible con
APIs que exponen /health sin basePath).

.PARAMETER BasePath
basePath declarado, p. ej. "api/v1" o "/api/v1/".

.EXAMPLE
Format-ApiBasePath -BasePath 'api/v1'   # => '/api/v1'
Format-ApiBasePath -BasePath '/api/v1/' # => '/api/v1'
Format-ApiBasePath -BasePath ''         # => ''
#>
function Format-ApiBasePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$BasePath = ''
    )

    $value = $BasePath.Trim().TrimEnd('/')
    if (-not $value) { return '' }
    if (-not $value.StartsWith('/')) { $value = "/$value" }
    return $value
}

<#
.SYNOPSIS
Resuelve el basePath efectivo del API segun la precedencia del ecosistema.

.DESCRIPTION
Precedencia (single source of truth primero):
  1. package.json -> "modularApi": { "basePath": "..." }  (convencion modular_api)
  2. publish.yaml -> api.basePath                          (override explicito)
  3. "" (raiz)                                             (retrocompatible)
El valor retornado ya viene normalizado por Format-ApiBasePath.

.PARAMETER PackageJson
Objeto de package.json ya parseado (ConvertFrom-Json).

.PARAMETER PublishConfig
Objeto de publish.yaml ya parseado (ConvertFrom-Yaml).

.EXAMPLE
$apiBasePath = Resolve-ApiBasePath -PackageJson $pkg -PublishConfig $deployConfig
#>
function Resolve-ApiBasePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        $PackageJson,

        [Parameter(Mandatory=$false)]
        $PublishConfig
    )

    $raw = ''
    if ($PackageJson -and $PackageJson.modularApi -and $PackageJson.modularApi.basePath) {
        $raw = [string]$PackageJson.modularApi.basePath
    }
    elseif ($PublishConfig -and $PublishConfig.api -and $PublishConfig.api.basePath) {
        $raw = [string]$PublishConfig.api.basePath
    }

    return Format-ApiBasePath -BasePath $raw
}

<#
.SYNOPSIS
Resuelve la ruta del archivo de configuracion de despliegue del proyecto.

.DESCRIPTION
Busca publish.yaml (nombre actual, coherente con el cmdlet Publish-NodeApi) y,
si no existe, cae al nombre anterior deploy.yaml marcandolo como legacy para
que el caller emita el aviso de deprecacion.

.PARAMETER ProjectRoot
Directorio raiz del proyecto.

.EXAMPLE
$cfg = Resolve-PublishConfigPath -ProjectRoot (Get-Location).Path
if (-not $cfg.Path) { throw "..." }
if ($cfg.IsLegacy) { Write-Host "deploy.yaml esta deprecado..." }
#>
function Resolve-PublishConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ProjectRoot
    )

    $publishPath = Join-Path $ProjectRoot 'publish.yaml'
    if (Test-Path $publishPath) {
        return @{ Path = $publishPath; IsLegacy = $false }
    }

    $legacyPath = Join-Path $ProjectRoot 'deploy.yaml'
    if (Test-Path $legacyPath) {
        return @{ Path = $legacyPath; IsLegacy = $true }
    }

    return @{ Path = $null; IsLegacy = $false }
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
    $tmpPath = [IO.Path]::Combine([IO.Path]::GetTempPath(), "${Prefix}{0}.sh" -f ([guid]::NewGuid().ToString()))
    
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

# ═══════════════════════════════════════════════════════════════════
# ADR 0003 — No-build runtime helpers (build:false / any Node API)
# ═══════════════════════════════════════════════════════════════════

<#
.SYNOPSIS
Resuelve el modo de runtime (build) y el entrypoint desde publish.yaml.

.DESCRIPTION
ADR 0003. Precedencia retrocompatible:
  - build:   runtime.build (si se declara) > $true (default, flujo TypeScript actual).
  - entrypoint: runtime.entrypoint (explicito) > 'dist/main.js' (build:true) > 'server.js' (build:false).
El entrypoint se normaliza quitando un './' inicial. Es la ruta relativa a la
release que ejecuta el proceso (current/<entrypoint>).

.PARAMETER PublishConfig
Objeto de publish.yaml ya parseado (ConvertFrom-Yaml) o hashtable equivalente.

.EXAMPLE
$rt = Resolve-NodeRuntime -PublishConfig $deployConfig
if (-not $rt.Build) { # saltar tsconfig/build, empaquetar fuente
}
#>
function Resolve-NodeRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $PublishConfig
    )

    $runtime = if ($PublishConfig) { $PublishConfig.runtime } else { $null }

    $build = $true
    if ($runtime -and ($null -ne $runtime.build)) {
        $build = [bool]$runtime.build
    }

    $entrypoint = $null
    if ($runtime -and $runtime.entrypoint) {
        $entrypoint = [string]$runtime.entrypoint
    }
    if (-not $entrypoint) {
        $entrypoint = if ($build) { 'dist/main.js' } else { 'server.js' }
    }

    # Normalizar: quitar './' inicial y backslashes -> '/'
    $entrypoint = ($entrypoint -replace '\\', '/') -replace '^\./', ''

    # sharedPaths (ADR 0003): archivos/directorios que la app necesita en runtime pero
    # que NO estan versionados en git (secretos, claves, certs) y por tanto NO viajan en
    # el tarball (git archive HEAD). Se stagean una vez en $REMOTE_ROOT/$NAME/shared/<path>
    # y el instalador los symlinkea dentro de cada release. Se normalizan como el entrypoint.
    $sharedPaths = @()
    if ($runtime -and $runtime.sharedPaths) {
        foreach ($p in @($runtime.sharedPaths)) {
            $norm = ((([string]$p) -replace '\\', '/') -replace '^\./', '').Trim().TrimEnd('/')
            if ($norm) { $sharedPaths += $norm }
        }
    }

    return @{
        Build       = $build
        Entrypoint  = $entrypoint
        SharedPaths = $sharedPaths
    }
}

<#
.SYNOPSIS
Resuelve el servidor destino del despliegue desde el env file elegido (ADR 0004).

.DESCRIPTION
El destino no es una propiedad del codigo sino config per-entorno/per-maquina: vive en el
env file gitignored (`.env`, `.env.production`, ...) bajo la clave namespaced
`MACSS_DEPLOY_SERVER` (un alias de ~/.ssh/config). El env file se elige con -EnvFile
(default `.env`), asi "que entorno" = "que archivo" y prod nunca es el default.
Falla claro si la clave no esta, en vez de desplegar a un destino silencioso/equivocado.

.PARAMETER EnvVars
Hashtable de variables ya parseadas del env file (Read-DotEnv .Env). Case-insensitive.

.PARAMETER EnvFilePath
Ruta del env file, solo para el mensaje de error (default '.env').

.EXAMPLE
$target = Resolve-DeployTarget -EnvVars $envConfig.Env -EnvFilePath $envFile
#>
function Resolve-DeployTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $EnvVars,

        [Parameter(Mandatory = $false)]
        [string]$EnvFilePath = '.env'
    )

    $target = ''
    if ($EnvVars -and $EnvVars['MACSS_DEPLOY_SERVER']) {
        $target = "$($EnvVars['MACSS_DEPLOY_SERVER'])".Trim()
    }

    if (-not $target) {
        throw "No hay destino de despliegue: falta 'MACSS_DEPLOY_SERVER' en '$EnvFilePath'. " +
              "Ejecute 'Publish-NodeApi -Init' o agregue 'MACSS_DEPLOY_SERVER=<alias de ~/.ssh/config>' al env file."
    }

    return $target
}

<#
.SYNOPSIS
Lanza un error de deprecación con la información necesaria para migrar (ADR 0012).

.DESCRIPTION
Una deprecación falla; no avisa y continúa. Un aviso que sigue funcionando perpetúa la deuda,
porque nadie migra lo que no le impide trabajar, y acaba leyéndose como ruido de fondo.

Este helper es la única vía de producir ese error, para que ningún mensaje quede a criterio de
quien escribe el `throw`. El mensaje debe bastar para migrar sin abrir la documentación: qué se
usó, desde cuándo está retirado, qué usar en su lugar y dónde corregirlo.

.PARAMETER Cmdlet
Nombre del cmdlet que rechaza el uso. Va primero para que el error diga de dónde salió.

.PARAMETER What
El elemento deprecado, tal como el usuario lo escribió ('-Publish', 'MACSS_DEPLOY_SERVER').

.PARAMETER UseInstead
El reemplazo exacto.

.PARAMETER Since
Versión en la que se retiró.

.PARAMETER Where
Archivo donde hay que hacer la corrección. Opcional.

.PARAMETER Detail
Una línea extra de contexto. Opcional.

.PARAMETER Reference
ADR u origen de la decisión. Opcional.

.EXAMPLE
Deny-DeprecatedUsage -Cmdlet 'Publish-NodeApi' -What 'MACSS_DEPLOY_SERVER' `
    -UseInstead 'MACSS_DEPLOY_SSH_ALIAS' -Since '6.0.0' -Where '.env.production' -Reference 'ADR 0010'
#>
function Deny-DeprecatedUsage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Cmdlet,

        [Parameter(Mandatory = $true)]
        [string]$What,

        [Parameter(Mandatory = $true)]
        [string]$UseInstead,

        [Parameter(Mandatory = $true)]
        [string]$Since,

        [Parameter()]
        [string]$Where,

        [Parameter()]
        [string]$Detail,

        [Parameter()]
        [string]$Reference
    )

    $lines = @("${Cmdlet}: '$What' se retiró en $Since.")
    if ($Where) {
        $lines += "  Use '$UseInstead' en su lugar, en '$Where'."
    } else {
        $lines += "  Use '$UseInstead' en su lugar."
    }
    if ($Detail)    { $lines += "  $Detail" }
    if ($Reference) { $lines += "  Ver $Reference." }

    throw ($lines -join [Environment]::NewLine)
}

<#
.SYNOPSIS
Resuelve el alias SSH de destino desde el env file (ADR 0004, ADR 0010).

.DESCRIPTION
Concentra el patrón que ADR 0004 fijó y que hasta 6.0.0 cada cmdlet resolvía por su cuenta: el
destino sale de `MACSS_DEPLOY_SSH_ALIAS` en el env file gitignored elegido con `-EnvFile`, nunca
de un archivo versionado. Un alias SSH es machine-local; versionarlo hace que el repo no sea
portable y obliga a editar un archivo del repo para cambiar de entorno.

Lo consumen los tres cmdlets cuyo destino es una máquina a la que se salta: `Publish-NodeApi`,
`Publish-FlutterWeb` y `Publish-DockerStack`. Los de base de datos no lo usan: su destino es un
endpoint de red, no un host al que saltar (ADR 0011).

Los mecanismos deprecados **fallan**, no se aceptan (ADR 0012). Y fallan también cuando coexisten
con la clave nueva: tener las dos es justo el estado ambiguo que hay que eliminar.

.PARAMETER ProjectRoot
Raíz del proyecto donde se busca el env file.

.PARAMETER EnvFile
Env file que selecciona el entorno. Por defecto '.env': producción siempre es explícita.

.PARAMETER LegacyServer
Valor de 'server:' leído del archivo versionado, si lo hubiera. Su sola presencia es un error;
se recibe para poder nombrarlo en el mensaje de migración.

.PARAMETER Cmdlet
Nombre del cmdlet que llama, para que el error diga de dónde salió.
#>
function Resolve-DeployTargetFromEnv {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter()]
        [string]$EnvFile = '.env',

        [Parameter()]
        [string]$LegacyServer,

        [Parameter(Mandatory = $true)]
        [string]$Cmdlet
    )

    $envPath = if ([System.IO.Path]::IsPathRooted($EnvFile)) {
        $EnvFile
    } else {
        Join-Path $ProjectRoot $EnvFile
    }

    $vars = @{}
    if (Test-Path -LiteralPath $envPath) {
        $vars = (Read-DotEnv -Path $envPath).Env
    }

    $alias  = if ($vars['MACSS_DEPLOY_SSH_ALIAS']) { "$($vars['MACSS_DEPLOY_SSH_ALIAS'])".Trim() } else { '' }
    $legacy = if ($vars['MACSS_DEPLOY_SERVER'])    { "$($vars['MACSS_DEPLOY_SERVER'])".Trim() }    else { '' }

    # Los deprecados se comprueban ANTES de resolver: si el env trae la clave nueva y ademas
    # arrastra la vieja, el estado es ambiguo y resolverlo en silencio dejaria archivos a medio
    # migrar sin que nadie se entere.
    if ($legacy) {
        Deny-DeprecatedUsage -Cmdlet $Cmdlet -What 'MACSS_DEPLOY_SERVER' `
            -UseInstead 'MACSS_DEPLOY_SSH_ALIAS' -Since '6.0.0' -Where $EnvFile `
            -Detail 'El valor no cambia: sigue siendo el alias de ~/.ssh/config.' `
            -Reference 'ADR 0010'
    }

    if ($LegacyServer) {
        Deny-DeprecatedUsage -Cmdlet $Cmdlet -What "server: en el archivo versionado" `
            -UseInstead 'MACSS_DEPLOY_SSH_ALIAS' -Since '6.0.0' -Where $EnvFile `
            -Detail "Mueva el valor '$LegacyServer' al env file y borre la clave 'server' del archivo versionado." `
            -Reference 'ADR 0010'
    }

    if (-not $alias) {
        throw "${Cmdlet}: no hay destino de despliegue. Falta 'MACSS_DEPLOY_SSH_ALIAS' en '$EnvFile'. " +
              "Agregue 'MACSS_DEPLOY_SSH_ALIAS=<alias de ~/.ssh/config>' a ese archivo."
    }

    return $alias
}

<#
.SYNOPSIS
Resuelve el nombre de la base SQL Server desde el `.sqlproj` (ADR 0011).

.DESCRIPTION
El nombre de la base no es *dónde* despliegas: es *qué* despliegas. Por eso vive en el archivo de
proyecto versionado y no en el env file, que existe para expresar diferencias entre entornos. La
medición que motivó la decisión: `DB_NAME` era idéntico en `.env` y `.env.production` en todos los
repos de la organización — identidad duplicada, no configuración.

`DB_NAME` sobrevive como **override explícito**, por las DB Tier-1 desechables (`dev_<nombre>`),
donde el mismo dacpac se publica a una base con otro nombre. Derivar a secas eliminaría ese flujo.

Dos usos de `DB_NAME` se rechazan:

- **Redundante** (repite el nombre del proyecto): duplicación muerta, se pide borrarla.
- **Difiere solo en mayúsculas**: en una collation case-insensitive da igual; en una
  case-sensitive, no. El cmdlet no elige — adivinar sería cambiar el objetivo de un despliegue de
  producción en silencio.

.OUTPUTS
PSCustomObject con Name (el objetivo real), ProjectName (lo que declara el .sqlproj) e IsOverride.
#>
function Resolve-SqlDbIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter()]
        [string]$EnvFile = '.env'
    )

    $proj = Get-ChildItem -LiteralPath $ProjectRoot -Filter '*.sqlproj' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
    if (-not $proj) {
        throw "No se encontró ningún archivo .sqlproj en '$ProjectRoot'. Ejecute este cmdlet desde el directorio del SQL Project."
    }

    $content = Get-Content -LiteralPath $proj.FullName -Raw -Encoding UTF8
    $projectName = ''
    if ($content -match '<Name>\s*([^<]+?)\s*</Name>') { $projectName = $Matches[1].Trim() }

    if (-not $projectName) {
        throw "'$($proj.Name)' no declara <Name>. La identidad de la base se lee de ahí (ADR 0011): " +
              "agregue <Name>NombreDeLaBase</Name> dentro de su PropertyGroup."
    }

    $envPath = if ([System.IO.Path]::IsPathRooted($EnvFile)) { $EnvFile } else { Join-Path $ProjectRoot $EnvFile }
    $override = ''
    if (Test-Path -LiteralPath $envPath) {
        $vars = (Read-DotEnv -Path $envPath).Env
        if ($vars['DB_NAME']) { $override = "$($vars['DB_NAME'])".Trim() }
    }

    if ($override) {
        if ($override -ceq $projectName) {
            throw "'$($proj.Name)' ya declara la base como '$projectName'. Borre 'DB_NAME' de '$EnvFile': " +
                  "el nombre se lee del .sqlproj y tenerlo en dos sitios los deja divergir (ADR 0011)."
        }

        if ($override -ieq $projectName) {
            throw "Conflicto de mayúsculas entre el proyecto y el env, y la diferencia importa en una " +
                  "collation case-sensitive. '$($proj.Name)' declara <Name>$projectName</Name>; '$EnvFile' " +
                  "declara DB_NAME=$override. Si el nombre real de la base es '$override', corrija <Name> " +
                  "en el .sqlproj; si es '$projectName', borre DB_NAME. No se elige por usted (ADR 0011)."
        }

        return [pscustomobject]@{
            Name        = $override
            ProjectName = $projectName
            IsOverride  = $true
        }
    }

    return [pscustomobject]@{
        Name        = $projectName
        ProjectName = $projectName
        IsOverride  = $false
    }
}

<#
.SYNOPSIS
Resuelve el nombre de la base PostgreSQL desde `pgschema.yaml` (ADR 0011).

.DESCRIPTION
Misma frontera que en SQL Server: identidad en el archivo de proyecto versionado, conexión en el
env file gitignored. `pgschema` no produce un artefacto compilado que cargue identidad como el
dacpac, pero la identidad no necesita un binario: necesita un lugar versionado, y `pgschema.yaml`
ya lo es.

`PGDATABASE` en el env **falla**. No hay override aquí: si aparece un caso Tier-1 en PostgreSQL se
decidirá entonces, con el caso delante.

.OUTPUTS
PSCustomObject con Name.
#>
function Resolve-PgDbIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter()]
        [string]$EnvFile = '.env'
    )

    $yamlPath = Join-Path $ProjectRoot 'pgschema.yaml'
    if (-not (Test-Path -LiteralPath $yamlPath)) {
        throw "No se encontró pgschema.yaml en '$ProjectRoot'. Ejecute 'Invoke-PgSchema -Init' primero."
    }

    # El deprecado se comprueba antes de leer el yaml: si estan los dos, el estado es ambiguo.
    $envPath = if ([System.IO.Path]::IsPathRooted($EnvFile)) { $EnvFile } else { Join-Path $ProjectRoot $EnvFile }
    if (Test-Path -LiteralPath $envPath) {
        $vars = (Read-DotEnv -Path $envPath).Env
        if ($vars['PGDATABASE']) {
            Deny-DeprecatedUsage -Cmdlet 'Invoke-PgSchema' -What 'PGDATABASE' `
                -UseInstead 'database:' -Since '6.0.0' -Where 'pgschema.yaml' `
                -Detail "El nombre de la base es identidad del proyecto, no configuracion de entorno: mueva el valor a 'database:' en pgschema.yaml y borrelo de '$EnvFile'." `
                -Reference 'ADR 0011'
        }
    }

    $yaml = Get-Content -LiteralPath $yamlPath -Raw -Encoding UTF8
    $name = ''
    if ($yaml -match '(?m)^\s*database\s*:\s*(.+?)\s*$') {
        $name = $Matches[1].Trim().Trim("'", '"')
    }

    if (-not $name) {
        throw "pgschema.yaml no declara 'database:'. La identidad de la base se lee de ahí (ADR 0011): " +
              "agregue 'database: <nombre>' al inicio del archivo."
    }

    return [pscustomobject]@{ Name = $name }
}

<#
.SYNOPSIS
Quita del contenido del env las claves deploy-time (MACSS_DEPLOY_*) antes de subirlo (ADR 0004).

.DESCRIPTION
Las claves `MACSS_DEPLOY_*` son metadato de despliegue (p.ej. el destino), no config runtime
de la app. Se leen localmente pero NO deben viajar al env de la app en el servidor. Filtra por
linea, preservando comentarios, lineas vacias y el resto de claves tal cual (orden y valores
intactos). Solo elimina claves cuyo NOMBRE empieza con `MACSS_DEPLOY_`.

.PARAMETER Lines
Lineas del env file (Get-Content, sin -Raw).

.EXAMPLE
$clean = Remove-DeployOnlyEnvKeys -Lines (Get-Content $envFile)
#>
function Remove-DeployOnlyEnvKeys {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    return @($Lines | Where-Object { $_ -notmatch '^\s*MACSS_DEPLOY_[A-Za-z0-9_]*\s*=' })
}

<#
.SYNOPSIS
Asegura que un env file declare MACSS_DEPLOY_SERVER (ADR 0004), idempotente.

.DESCRIPTION
Usado por -Init. Si el archivo no existe lo crea con una plantilla mínima (incluye
MACSS_DEPLOY_SERVER=, PORT, NODE_ENV). Si existe pero no tiene la clave, la agrega al final.
Si ya la tiene, no toca nada. Retorna 'created' | 'appended' | 'exists'.

.PARAMETER Path
Ruta del env file.

.PARAMETER EnvLabel
Etiqueta para el comentario del archivo nuevo (p.ej. 'producción'). Opcional.

.EXAMPLE
Add-EnvDeployKey -Path (Join-Path $cwd '.env') -EnvLabel 'default (dev/pre-prod)'
#>
function Add-EnvDeployKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$EnvLabel = ''
    )

    $keyComment = '# Destino del despliegue: alias de ~/.ssh/config (config local, per-máquina).'

    if (-not (Test-Path $Path)) {
        $header = if ($EnvLabel) { "# Env file — $EnvLabel." } else { '# Env file.' }
        $tpl = @"
$header Se copia al servidor como .env del release
# (sin las claves MACSS_DEPLOY_*). NO versionar (está en .gitignore).

$keyComment
MACSS_DEPLOY_SERVER=

PORT=8080
NODE_ENV=production
"@
        Set-Content -Path $Path -Value $tpl -Encoding UTF8
        return 'created'
    }

    $content = Get-Content $Path -Raw
    if ($content -match '(?m)^\s*MACSS_DEPLOY_SERVER\s*=') {
        return 'exists'
    }

    $sep = if ($content -and -not $content.EndsWith("`n")) { "`n" } else { '' }
    Add-Content -Path $Path -Value "$sep`n$keyComment`nMACSS_DEPLOY_SERVER="
    return 'appended'
}

<#
.SYNOPSIS
Compone el identificador de release: v{version}+{shortSha} (ADR 0003).

.DESCRIPTION
Toma la version de package.json (descartando cualquier build metadata previo tras '+')
y le adjunta el sha corto de git para identificar univocamente cada despliegue, incluso
cuando la version de package.json es estatica.

.EXAMPLE
Get-ReleaseId -Version '1.0.0' -ShortSha 'abc1234'   # => v1.0.0+abc1234
#>
function Get-ReleaseId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [string]$ShortSha
    )

    $baseVersion = ($Version -split '\+')[0]
    return "v$baseVersion+$ShortSha"
}

<#
.SYNOPSIS
Indica si el arbol de trabajo de git esta limpio (ADR 0003).

.DESCRIPTION
En modo build:false el tarball se arma desde HEAD (git archive), asi que un arbol
sucio desplegaria algo distinto de lo que se ve. Este guard permite que -Apply exija
un arbol limpio (salvo -AllowDirty). Retorna $true si no hay cambios pendientes.

.PARAMETER Path
Directorio dentro del repo git a inspeccionar.

.EXAMPLE
if (-not (Test-CleanWorktree -Path $cwd)) { throw "Commit or use -AllowDirty" }
#>
function Test-CleanWorktree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # Acotado al subarbol de $Path con el pathspec '-- .': en un monorepo,
    # Publish-NodeApi corre desde el subdir del componente (p. ej. code/api) y el
    # guard NO debe bloquearse por cambios sin commitear en OTROS componentes
    # (code/db, code/app, docs...). Cuando $Path es la raiz del repo, '-- .'
    # abarca todo el repo => comportamiento identico al anterior.
    $status = & git -C $Path status --porcelain -- . 2>$null
    return [string]::IsNullOrWhiteSpace(($status | Out-String))
}

<#
.SYNOPSIS
Empaqueta como tar el subarbol versionado (HEAD) del directorio indicado, con sus
archivos en la RAIZ del tar. Agnostico a la profundidad del subdir en el repo.

.DESCRIPTION
En build:false el tarball se arma con 'git archive' desde HEAD. En un monorepo el
componente vive en un subdir (p. ej. code/api), asi que hay que archivar ese
SUBARBOL con sus archivos en la raiz del tar.

Clave: 'git archive' se corre desde el TOPLEVEL del repo. Si se corriera con -C en
el subdir, git resuelve 'HEAD:<prefix>' relativo al cwd (=> <prefix>/<prefix>,
arbol inexistente => tar VACIO => el entrypoint "no aparece"). Con --show-prefix
(ruta raiz->cwd) y --show-toplevel (raiz del repo), el empaquetado funciona igual
sin importar cuantas carpetas arriba este el .git.

.PARAMETER Path
Directorio del componente a empaquetar (desde donde se corre Publish-NodeApi).

.PARAMETER OutTar
Ruta del archivo .tar de salida.

.EXAMPLE
Export-GitSubtreeTar -Path (Get-Location) -OutTar $srcTar
#>
function Export-GitSubtreeTar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OutTar
    )

    $prefix   = "$(& git -C $Path rev-parse --show-prefix   2>$null)".Trim()
    $toplevel = "$(& git -C $Path rev-parse --show-toplevel 2>$null)".Trim()
    if (-not $toplevel) { $toplevel = $Path }
    $treeish  = if ($prefix) { "HEAD:$($prefix.TrimEnd('/'))" } else { 'HEAD' }

    & git -C $toplevel archive --format=tar -o $OutTar $treeish
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $OutTar)) {
        throw "git archive fallo (treeish=$treeish, toplevel=$toplevel)."
    }
}

<#
.SYNOPSIS
Decide como instalar node_modules de produccion segun el SO host (ADR 0003).

.DESCRIPTION
Los binarios nativos (p. ej. oracledb thick) se compilan por plataforma; un `npm ci`
en Windows produce un binario que no carga en el servidor Linux. En un host Windows la
instalacion se enruta a WSL para obtener binarios Linux; en Linux se instala nativo.
Helper de decision puro (sin efectos), testeable de forma unitaria.

.PARAMETER IsWindowsHost
$true si el host es Windows.

.EXAMPLE
$plan = Get-ProdModulesPlan -IsWindowsHost $IsWindows   # 'wsl' | 'native'
#>
function Get-ProdModulesPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$IsWindowsHost
    )

    if ($IsWindowsHost) { return 'wsl' }
    return 'native'
}

<#
.SYNOPSIS
Genera el ecosystem de pm2 en formato JSON (config-as-data) desde la topologia declarativa
de publish.yaml (ADR 0005).

.DESCRIPTION
pm2 carga JSON de forma nativa, sin la trampa CommonJS/ESM de un ecosystem.config.js en un
proyecto "type":"module". El schema es la interseccion systemd n pm2: por proceso solo se
admiten name, script, cwd y env. Las claves pm2-only (instances/cluster, cron_restart, watch,
max_memory_restart) quedan fuera y se rechazan; para esos casos existe la valvula de escape
ecosystem.config.cjs.

Sin -Processes genera un unico app (single-process) desde -AppName/-Entrypoint. El env de cada
proceso se fusiona SOBRE -RuntimeEnv (env no-secreto, versionado en publish.yaml).

.PARAMETER RuntimeEnv
Mapa de env no-secreto (runtime.env). Acepta hashtable o PSCustomObject (deserializado de YAML).

.PARAMETER Processes
Array de procesos (runtime.processes). Cada uno acepta name, script, cwd, env.

.EXAMPLE
New-Pm2EcosystemJson -AppName 'micro' -Entrypoint 'server.js' -RuntimeEnv @{ NODE_ENV = 'production' }
#>
function New-Pm2EcosystemJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppName,
        [Parameter(Mandatory = $true)][string]$Entrypoint,
        [object]$RuntimeEnv,
        [object]$Processes,
        [ValidateSet('always', 'on-failure', 'no')][string]$Restart = 'always',
        [int]$RestartDelaySec = 5
    )

    # Interseccion systemd n pm2 (ADR 0005): unicas claves portables por proceso.
    $allowedKeys = @('name', 'script', 'cwd', 'env')

    # Lee una clave de un hashtable o de un PSCustomObject (YAML deserializado).
    $getKey = {
        param($obj, $key)
        if ($null -eq $obj) { return $null }
        if ($obj -is [System.Collections.IDictionary]) { return $obj[$key] }
        $prop = $obj.PSObject.Properties[$key]
        if ($prop) { return $prop.Value }
        return $null
    }

    # Enumera las claves de un hashtable o PSCustomObject.
    $keysOf = {
        param($obj)
        if ($null -eq $obj) { return @() }
        if ($obj -is [System.Collections.IDictionary]) { return @($obj.Keys) }
        return @($obj.PSObject.Properties.Name)
    }

    # Fusiona dos mapas de env (base + override) preservando strings.
    $mergeEnv = {
        param($base, $override)
        $m = [ordered]@{}
        foreach ($src in @($base, $override)) {
            if ($null -eq $src) { continue }
            foreach ($k in (& $keysOf $src)) { $m[[string]$k] = [string](& $getKey $src $k) }
        }
        return $m
    }

    $procList = if ($Processes) { @($Processes) } else { @([ordered]@{ name = $AppName; script = $Entrypoint }) }

    $apps = [System.Collections.ArrayList]::new()
    foreach ($p in $procList) {
        $bad = @((& $keysOf $p) | Where-Object { $_ -notin $allowedKeys })
        if ($bad.Count -gt 0) {
            throw "Clave(s) fuera de la interseccion systemd n pm2 en processes: $($bad -join ', '). El schema portable solo admite: $($allowedKeys -join ', '). Para configuracion pm2-only (instances/cluster, cron_restart, watch, max_memory_restart) use un ecosystem.config.cjs (valvula de escape, ADR 0005)."
        }

        $script = & $getKey $p 'script'
        if (-not $script) { $script = $Entrypoint }
        $mergedEnv = & $mergeEnv $RuntimeEnv (& $getKey $p 'env')

        $app = [ordered]@{
            name          = [string](& $getKey $p 'name')
            script        = [string]$script
            autorestart   = ($Restart -ne 'no')
            restart_delay = ($RestartDelaySec * 1000)
        }
        $cwd = & $getKey $p 'cwd'
        if ($cwd) { $app['cwd'] = [string]$cwd }
        if ($mergedEnv.Count -gt 0) { $app['env'] = $mergedEnv }
        [void]$apps.Add($app)
    }

    return ([ordered]@{ apps = @($apps) } | ConvertTo-Json -Depth 6)
}
