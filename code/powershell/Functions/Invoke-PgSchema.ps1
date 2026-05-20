function Invoke-PgSchema {
    <#
    .SYNOPSIS
        Ejecuta acciones de pgschema para despliegue declarativo de esquemas PostgreSQL.

    .DESCRIPTION
        Cmdlet que envuelve pgschema CLI (ejecutado vía WSL) con configuración declarativa
        via pgschema.yaml. Soporta las acciones: Init, Dump, Plan, Apply y Script.

        pgschema trabaja schema-por-schema. El archivo pgschema.yaml define una lista
        de schemas, y el cmdlet itera sobre todos ellos (o sobre uno si se usa -Schema).

        Las credenciales se leen del archivo .env (gitignored), usando variables PG* estándar.
        Los parámetros de esquema se leen de pgschema.yaml (versionado).

        Debe ejecutarse desde el directorio db/ del proyecto (donde está pgschema.yaml).

        Referencia: https://www.pgschema.com

    .PARAMETER Init
        Genera los archivos de configuración (pgschema.yaml y .env) en el directorio actual.

    .PARAMETER Plan
        Genera un plan de migración comparando el estado deseado (main.sql) contra la BD.
        No modifica la base de datos. Equivalente a DeployReport en SqlPackage.

    .PARAMETER Apply
        Aplica el plan de migración a la base de datos.
        Usa el plan.json generado por -Plan, o genera uno sobre la marcha con --file.

    .PARAMETER Dump
        Captura el esquema actual de la BD y lo muestra por stdout (o a archivo).
        Equivalente a Extract en SqlPackage.

    .PARAMETER Script
        Genera el script SQL exacto que Apply ejecutaría, sin modificar la BD.
        Equivalente a Script en SqlPackage.

    .PARAMETER Schema
        Nombre del schema a procesar. Si se omite, procesa todos los schemas
        definidos en pgschema.yaml. Válido para Plan, Apply, Dump y Script.

    .EXAMPLE
        Invoke-PgSchema -Init

        Genera pgschema.yaml y .env en el directorio actual.

    .EXAMPLE
        Invoke-PgSchema -Plan

        Genera plan de migración para TODOS los schemas definidos en pgschema.yaml.

    .EXAMPLE
        Invoke-PgSchema -Plan -Schema auth

        Genera plan de migración solo para el schema 'auth'.

    .EXAMPLE
        Invoke-PgSchema -Apply -Schema auth

        Aplica el plan de migración solo para el schema 'auth'.

    .EXAMPLE
        Invoke-PgSchema -Dump

        Muestra el esquema actual de la BD para todos los schemas.

    .EXAMPLE
        Invoke-PgSchema -Script -Schema auth

        Genera el SQL que se ejecutaría para el schema 'auth'.

    .NOTES
        Requiere:
        - WSL con Ubuntu (pgschema instalado en /usr/local/bin/)
        - PostgreSQL accesible desde WSL
        - Archivos pgschema.yaml y .env configurados (usar -Init para generarlos)

        Author: @ccisnedev
        Version: 1.1.0
    #>
    [CmdletBinding(DefaultParameterSetName = 'Plan')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Init',
            HelpMessage = "Genera archivos de configuración (pgschema.yaml y .env)")]
        [switch]$Init,

        [Parameter(Mandatory, ParameterSetName = 'Plan',
            HelpMessage = "Genera plan de migración (dry-run, no modifica la BD)")]
        [switch]$Plan,

        [Parameter(Mandatory, ParameterSetName = 'Apply',
            HelpMessage = "Aplica el plan de migración a la BD")]
        [switch]$Apply,

        [Parameter(Mandatory, ParameterSetName = 'Dump',
            HelpMessage = "Captura el esquema actual de la BD")]
        [switch]$Dump,

        [Parameter(Mandatory, ParameterSetName = 'Script',
            HelpMessage = "Genera script SQL de los cambios sin aplicarlos")]
        [switch]$Script,

        [Parameter(ParameterSetName = 'Plan')]
        [Parameter(ParameterSetName = 'Apply')]
        [Parameter(ParameterSetName = 'Dump')]
        [Parameter(ParameterSetName = 'Script')]
        [string]$Schema
    )

    begin {
        $ErrorActionPreference = 'Stop'
    }

    process {
        # Banner
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║         pgschema — macss-devops                 ║" -ForegroundColor Cyan
        Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""

        switch ($PSCmdlet.ParameterSetName) {
            'Init' {
                Write-Host "  Inicializando configuración pgschema..." -ForegroundColor Cyan
                Write-Host ""
                New-PgSchemaConfig
                Write-Host ""
                Write-Host "  Configuración creada. Edite los archivos según su entorno:" -ForegroundColor Green
                Write-Host "    pgschema.yaml → schemas y opciones de migración (versionar)" -ForegroundColor DarkGray
                Write-Host "    .env          → credenciales PostgreSQL PG* (NO versionar)" -ForegroundColor DarkGray
                Write-Host ""
            }

            'Plan' {
                $resolved = Resolve-PgSchemaTargets -Schema $Schema
                $config   = $resolved.Config
                $schemas  = $resolved.Schemas
                $envVars  = $resolved.EnvVars

                try {
                    Write-Host "  Host:     $($envVars['PGHOST']):$($envVars['PGPORT'])" -ForegroundColor Cyan
                    Write-Host "  Database: $($envVars['PGDATABASE'])" -ForegroundColor Cyan
                    Write-Host "  Schemas:  $($schemas.name -join ', ')" -ForegroundColor Cyan
                    Write-Host "  Modo: PLAN (dry-run)" -ForegroundColor Cyan
                    Write-Host ""

                    foreach ($s in $schemas) {
                        Write-Host "  ─── Schema: $($s.name) ───" -ForegroundColor Magenta
                        Write-Host "  File: $($s.file)" -ForegroundColor DarkGray
                        Write-Host ""

                        $extraArgs = @()
                        if ($config.plan_options) {
                            if ($config.plan_options.output_human) {
                                $extraArgs += '--output-human', $config.plan_options.output_human
                            }
                        }
                        # JSON plan siempre va al archivo del schema
                        $extraArgs += '--output-json', $s.plan

                        $pgArgs = Build-PgSchemaArgs -Action 'plan' -SchemaEntry $s -EnvVars $envVars -ExtraArgs $extraArgs

                        Invoke-PgSchemaWSL -Arguments $pgArgs -Password $envVars['PGPASSWORD']

                        Write-Host ""
                        Write-Host "  Plan: $($s.plan)" -ForegroundColor DarkGray
                        Write-Host ""
                    }

                    Write-Host "  Plan generado exitosamente" -ForegroundColor Green
                    Write-Host ""
                }
                finally {
                    if ($envVars) { $envVars['PGPASSWORD'] = $null }
                    [System.GC]::Collect()
                }
            }

            'Apply' {
                $resolved = Resolve-PgSchemaTargets -Schema $Schema
                $config   = $resolved.Config
                $schemas  = $resolved.Schemas
                $envVars  = $resolved.EnvVars

                try {
                    Write-Host "  Host:     $($envVars['PGHOST']):$($envVars['PGPORT'])" -ForegroundColor Cyan
                    Write-Host "  Database: $($envVars['PGDATABASE'])" -ForegroundColor Cyan
                    Write-Host "  Schemas:  $($schemas.name -join ', ')" -ForegroundColor Cyan
                    Write-Host "  Modo: APPLY" -ForegroundColor Yellow
                    Write-Host ""

                    # Confirmación global (salvo auto_approve)
                    if (-not ($config.apply_options -and $config.apply_options.auto_approve)) {
                        $confirm = Read-Host "  ¿Aplicar cambios a la BD para [$($schemas.name -join ', ')]? (S/N)"
                        if ($confirm -notmatch '^[Ss]$') {
                            Write-Host "  Aplicación cancelada." -ForegroundColor Yellow
                            return
                        }
                    }

                    foreach ($s in $schemas) {
                        Write-Host "  ─── Schema: $($s.name) ───" -ForegroundColor Magenta

                        $extraArgs = @('--auto-approve')

                        # Determinar si usar --plan o --file
                        if ($s.plan -and (Test-Path $s.plan)) {
                            Write-Host "  Usando plan: $($s.plan)" -ForegroundColor Cyan
                            $extraArgs += '--plan', $s.plan
                        }
                        else {
                            Write-Host "  Sin plan previo, generando sobre la marcha..." -ForegroundColor Yellow
                        }

                        # Lock timeout
                        if ($config.apply_options -and $config.apply_options.lock_timeout) {
                            $extraArgs += '--lock-timeout', $config.apply_options.lock_timeout
                        }

                        $pgArgs = Build-PgSchemaArgs -Action 'apply' -SchemaEntry $s -EnvVars $envVars -ExtraArgs $extraArgs

                        Invoke-PgSchemaWSL -Arguments $pgArgs -Password $envVars['PGPASSWORD']

                        Write-Host ""
                    }

                    Write-Host "  Migración aplicada exitosamente" -ForegroundColor Green
                    Write-Host ""
                }
                finally {
                    if ($envVars) { $envVars['PGPASSWORD'] = $null }
                    [System.GC]::Collect()
                }
            }

            'Dump' {
                $resolved = Resolve-PgSchemaTargets -Schema $Schema
                $config   = $resolved.Config
                $schemas  = $resolved.Schemas
                $envVars  = $resolved.EnvVars

                try {
                    Write-Host "  Host:     $($envVars['PGHOST']):$($envVars['PGPORT'])" -ForegroundColor Cyan
                    Write-Host "  Database: $($envVars['PGDATABASE'])" -ForegroundColor Cyan
                    Write-Host "  Schemas:  $($schemas.name -join ', ')" -ForegroundColor Cyan
                    Write-Host "  Modo: DUMP (snapshot)" -ForegroundColor Cyan
                    Write-Host ""

                    foreach ($s in $schemas) {
                        Write-Host "  ─── Schema: $($s.name) ───" -ForegroundColor Magenta
                        Write-Host ""

                        $extraArgs = @()
                        if ($config.dump_options) {
                            if ($config.dump_options.multi_file) {
                                $extraArgs += '--multi-file'
                                $extraArgs += '--file', $s.file
                            }
                            if ($config.dump_options.no_comments) {
                                $extraArgs += '--no-comments'
                            }
                        }

                        $pgArgs = Build-PgSchemaArgs -Action 'dump' -SchemaEntry $s -EnvVars $envVars -ExtraArgs $extraArgs

                        Invoke-PgSchemaWSL -Arguments $pgArgs -Password $envVars['PGPASSWORD']

                        Write-Host ""
                    }

                    Write-Host "  Dump completado" -ForegroundColor Green
                    Write-Host ""
                }
                finally {
                    if ($envVars) { $envVars['PGPASSWORD'] = $null }
                    [System.GC]::Collect()
                }
            }

            'Script' {
                $resolved = Resolve-PgSchemaTargets -Schema $Schema
                $config   = $resolved.Config
                $schemas  = $resolved.Schemas
                $envVars  = $resolved.EnvVars

                try {
                    Write-Host "  Host:     $($envVars['PGHOST']):$($envVars['PGPORT'])" -ForegroundColor Cyan
                    Write-Host "  Database: $($envVars['PGDATABASE'])" -ForegroundColor Cyan
                    Write-Host "  Schemas:  $($schemas.name -join ', ')" -ForegroundColor Cyan
                    Write-Host "  Modo: SCRIPT SQL" -ForegroundColor Cyan
                    Write-Host ""

                    foreach ($s in $schemas) {
                        Write-Host "  ─── Schema: $($s.name) ───" -ForegroundColor Magenta

                        $scriptPath = "$($s.name)/deploy_script_$(Get-Date -Format 'yyyyMMdd_HHmmss').sql"

                        $extraArgs = @('--output-sql', $scriptPath)

                        $pgArgs = Build-PgSchemaArgs -Action 'plan' -SchemaEntry $s -EnvVars $envVars -ExtraArgs $extraArgs

                        Invoke-PgSchemaWSL -Arguments $pgArgs -Password $envVars['PGPASSWORD']

                        Write-Host ""
                        Write-Host "  Script: $scriptPath" -ForegroundColor Green
                        Write-Host ""
                    }
                }
                finally {
                    if ($envVars) { $envVars['PGPASSWORD'] = $null }
                    [System.GC]::Collect()
                }
            }
        }
    }
}

<#
.SYNOPSIS
    Resuelve la lista de schemas a procesar y carga config + env.

.DESCRIPTION
    Helper interno que centraliza la validación de prerequisitos,
    lectura de config, .env y filtrado por -Schema.

.PARAMETER Schema
    Nombre del schema a filtrar. Si es vacío, retorna todos.
#>
function Resolve-PgSchemaTargets {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Schema
    )

    if (-not (Test-Path ".\pgschema.yaml")) { throw "No se encontró pgschema.yaml. Ejecute 'Invoke-PgSchema -Init'." }
    if (-not (Test-Path ".\.env")) { throw "No se encontró .env. Ejecute 'Invoke-PgSchema -Init'." }

    $config = Read-PgSchemaConfig
    $envConfig = Read-DotEnv -Path ".\.env"
    $envVars = $envConfig.Env

    # Filtrar schemas
    if ($Schema) {
        $schemas = @($config.schemas | Where-Object { $_.name -eq $Schema })
        if ($schemas.Count -eq 0) {
            $available = ($config.schemas | ForEach-Object { $_.name }) -join ', '
            throw "Schema '$Schema' no encontrado en pgschema.yaml. Disponibles: $available"
        }
    }
    else {
        $schemas = @($config.schemas)
    }

    return @{
        Config  = $config
        Schemas = $schemas
        EnvVars = $envVars
    }
}
