# PgSchemaHelpers.ps1
# Funciones helper para Invoke-PgSchema

<#
.SYNOPSIS
    Lee y parsea el archivo pgschema.yaml del directorio actual.

.DESCRIPTION
    Valida que exista la sección 'schemas' como lista de schemas.
    Cada entrada debe tener: name, file, plan.

.PARAMETER Path
    Ruta al archivo pgschema.yaml. Por defecto: ./pgschema.yaml

.OUTPUTS
    Hashtable con la configuración parseada.
#>
function Read-PgSchemaConfig {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Path = ".\pgschema.yaml"
    )

    if (Get-Command -Name Ensure-YamlModule -ErrorAction SilentlyContinue) {
        Ensure-YamlModule
    }
    elseif (-not (Get-Command -Name ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        try {
            Import-Module powershell-yaml -ErrorAction Stop | Out-Null
        }
        catch {
            throw "No se encontró el módulo 'powershell-yaml'. Instale con: Install-Module powershell-yaml -Scope CurrentUser -Force"
        }
    }

    if (-not (Test-Path $Path)) {
        throw "No se encontró '$Path'. Ejecute 'Invoke-PgSchema -Init' para generarlo."
    }

    $raw = Get-Content $Path -Raw
    $config = ConvertFrom-Yaml $raw

    if (-not $config.schemas -or $config.schemas.Count -eq 0) {
        throw "El archivo '$Path' no tiene la sección 'schemas' requerida (lista de schemas)."
    }

    # Validar cada entrada
    foreach ($s in $config.schemas) {
        if (-not $s.name) { throw "Cada schema en '$Path' debe tener 'name'." }
        if (-not $s.file) { throw "El schema '$($s.name)' en '$Path' no tiene 'file' (ruta al main.sql)." }
        if (-not $s.plan) { throw "El schema '$($s.name)' en '$Path' no tiene 'plan' (ruta al plan.json)." }
    }

    return $config
}

<#
.SYNOPSIS
    Construye el array de argumentos para pgschema CLI vía WSL.

.PARAMETER Action
    La acción de pgschema (dump, plan, apply).

.PARAMETER Config
    Hashtable de configuración leída de pgschema.yaml.

.PARAMETER EnvVars
    Hashtable de variables de entorno leídas de .env.

.PARAMETER ExtraArgs
    Argumentos adicionales (output paths, flags, etc.).

.OUTPUTS
    String[] — Array de argumentos para pgschema.
#>
function Build-PgSchemaArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('dump', 'plan', 'apply')]
        [string]$Action,

        [Parameter(Mandatory)]
        [hashtable]$SchemaEntry,

        [Parameter(Mandatory)]
        [hashtable]$EnvVars,

        [Parameter()]
        [string[]]$ExtraArgs
    )

    $pgArgs = @($Action)

    # Conexión al servidor (credenciales desde .env, variables PG* estándar)
    $host_    = $EnvVars['PGHOST']
    $port     = $EnvVars['PGPORT']
    $database = $EnvVars['PGDATABASE']
    $user     = $EnvVars['PGUSER']
    $sslmode  = $EnvVars['PGSSLMODE']

    if (-not $host_)    { throw "Falta PGHOST en .env" }
    if (-not $database) { throw "Falta PGDATABASE en .env" }
    if (-not $user)     { throw "Falta PGUSER en .env" }

    $pgArgs += '--host', $host_
    if ($port) { $pgArgs += '--port', $port }
    $pgArgs += '--db', $database
    $pgArgs += '--user', $user

    # Schema desde la entrada individual
    $pgArgs += '--schema', $SchemaEntry.name

    # SSL mode
    if ($sslmode) {
        $pgArgs += '--sslmode', $sslmode
    }

    # Acción-específicos
    switch ($Action) {
        'dump' {
            # dump no necesita --file (output a stdout por defecto)
        }
        'plan' {
            $pgArgs += '--file', $SchemaEntry.file
        }
        'apply' {
            # apply acepta --file o --plan
        }
    }

    # Argumentos extra
    if ($ExtraArgs) {
        $pgArgs += $ExtraArgs
    }

    return $pgArgs
}

<#
.SYNOPSIS
    Genera los archivos de configuración pgschema.yaml y .env para un proyecto PostgreSQL.

.DESCRIPTION
    Crea plantillas de configuración en el directorio actual.
    pgschema.yaml contiene parámetros de esquema (versionado).
    .env contiene credenciales de conexión (NO versionado).
#>
function New-PgSchemaConfig {
    [CmdletBinding()]
    param()

    # pgschema.yaml
    if (-not (Test-Path ".\pgschema.yaml")) {
        $yamlContent = @"
# pgschema.yaml — Configuración declarativa para pgschema
# Ejecutar desde: db/  (directorio raíz de la base de datos)
# Referencia: https://www.pgschema.com
#
# pgschema trabaja schema-por-schema. Cada entrada define:
#   name: nombre del schema PostgreSQL
#   file: ruta al main.sql (estado deseado)
#   plan: ruta al plan.json generado

schemas:
  - name: auth
    file: auth/main.sql
    plan: auth/plan.json
  # - name: votacion
  #   file: votacion/main.sql
  #   plan: votacion/plan.json

# Opciones compartidas de plan
plan_options:
  output_human: stdout
  # output_sql: plan.sql    # Descomenta para generar script SQL

# Opciones compartidas de apply
apply_options:
  auto_approve: false
  # lock_timeout: 30s

# Opciones compartidas de dump
dump_options:
  # multi_file: false
  # no_comments: false
"@
        $yamlContent | Out-File -FilePath ".\pgschema.yaml" -Encoding utf8 -NoNewline
        Write-Host "  Creado: pgschema.yaml" -ForegroundColor Green
    }
    else {
        Write-Host "  Ya existe: pgschema.yaml" -ForegroundColor Yellow
    }

    # .env
    if (-not (Test-Path ".\.env")) {
        $envContent = @"
# .env — Credenciales PostgreSQL (NO versionar)
# Variables estándar PG* usadas por pgschema

PGHOST=localhost
PGPORT=5432
PGDATABASE=socia
PGUSER=postgres
PGPASSWORD=tu_password_aqui
# PGSSLMODE=prefer
"@
        $envContent | Out-File -FilePath ".\.env" -Encoding utf8 -NoNewline
        Write-Host "  Creado: .env" -ForegroundColor Green
    }
    else {
        Write-Host "  Ya existe: .env" -ForegroundColor Yellow
    }
}

<#
.SYNOPSIS
    Ejecuta pgschema dentro de WSL desde PowerShell en Windows.

.DESCRIPTION
    Construye el comando pgschema con los argumentos dados y lo ejecuta en WSL,
    pasando PGPASSWORD como variable de entorno (no como argumento CLI).

.PARAMETER Arguments
    Array de argumentos para pgschema.

.PARAMETER Password
    Contraseña de PostgreSQL (se pasa como PGPASSWORD env var).

.PARAMETER WorkingDir
    Directorio de trabajo en Windows (se convierte a ruta WSL).

.PARAMETER WSLDistro
    Distribución WSL a usar.

.OUTPUTS
    El output de pgschema.
#>
function Invoke-PgSchemaWSL {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter()]
        [string]$Password,

        [Parameter()]
        [string]$WorkingDir = (Get-Location).Path,

        [Parameter()]
        [string]$WSLDistro = "Ubuntu"
    )

    # Convertir directorio de trabajo a ruta WSL
    $wslPath = ConvertTo-WSLPath -winPath $WorkingDir -WSLDistro $WSLDistro

    # Construir comando: cd al directorio + PGPASSWORD + pgschema args
    $argsString = ($Arguments | ForEach-Object {
        # Escapar comillas simples dentro de cada argumento
        $escaped = $_ -replace "'", "'\''"
        "'$escaped'"
    }) -join ' '

    $envPrefix = ""
    if ($Password) {
        # Escapar comillas simples en la contraseña
        $escapedPwd = $Password -replace "'", "'\''"
        $envPrefix = "PGPASSWORD='$escapedPwd' "
    }

    $bashCmd = "cd $wslPath && ${envPrefix}pgschema $argsString"

    Write-Verbose "WSL cmd: $bashCmd"

    # Ejecutar en WSL
    $output = & wsl.exe -d $WSLDistro -- bash -c $bashCmd 2>&1
    $exitCode = $LASTEXITCODE

    # Mostrar output
    $output | ForEach-Object { Write-Host $_ }

    if ($exitCode -ne 0) {
        throw "pgschema falló con código de salida: $exitCode"
    }

    return $output
}
