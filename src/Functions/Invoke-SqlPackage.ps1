function Invoke-SqlPackage {
    <#
    .SYNOPSIS
        Ejecuta acciones de SqlPackage para despliegue declarativo de bases de datos SQL Server.

    .DESCRIPTION
        Cmdlet que envuelve sqlpackage.exe con configuración declarativa via sqlpackage.yaml.
        Soporta las 6 acciones principales de SqlPackage más un inicializador de plantillas.

        Las credenciales se leen del archivo .env (gitignored).
        Los parámetros de comportamiento se leen de sqlpackage.yaml (versionado).

        Debe ejecutarse desde el directorio del SQL Project (donde está el .sqlproj).

    .PARAMETER Init
        Genera los archivos de configuración (sqlpackage.yaml y .env) en el directorio actual.
        Requiere que exista un archivo .sqlproj.

    .PARAMETER Publish
        Despliega el .dacpac al servidor. Compila el proyecto, genera un DeployReport previo,
        solicita confirmación y ejecuta el publish.

    .PARAMETER DeployReport
        Genera un reporte XML con las diferencias entre el código y el servidor (dry-run).
        No modifica la base de datos.

    .PARAMETER Script
        Genera el archivo .sql exacto que Publish ejecutaría.
        No modifica la base de datos.

    .PARAMETER Extract
        Captura el esquema actual del servidor y genera un .dacpac snapshot.
        No modifica la base de datos.

    .PARAMETER Export
        Exporta esquema y datos del servidor a un archivo .bacpac.
        No modifica la base de datos.

    .PARAMETER Import
        Importa un archivo .bacpac (esquema + datos) al servidor.
        Modifica la base de datos.

    .EXAMPLE
        Invoke-SqlPackage -Init

        Genera sqlpackage.yaml y .env en el directorio actual del SQL Project.

    .EXAMPLE
        Invoke-SqlPackage -DeployReport

        Muestra qué cambios se aplicarían sin modificar la base de datos.

    .EXAMPLE
        Invoke-SqlPackage -Publish

        Compila, muestra cambios, pide confirmación y despliega.

    .EXAMPLE
        Invoke-SqlPackage -Script

        Genera el archivo .sql con el SQL exacto que se ejecutaría.

    .EXAMPLE
        Invoke-SqlPackage -Extract

        Captura el esquema actual del servidor como snapshot .dacpac.

    .NOTES
        Requiere:
        - sqlpackage.exe en el PATH
        - dotnet SDK (para compilar el SQL Project)
        - Archivos sqlpackage.yaml y .env configurados (usar -Init para generarlos)

        Referencia: https://learn.microsoft.com/sql/tools/sqlpackage
        Author: @ccisnedev
        Version: 1.0.0
    #>
    [CmdletBinding(DefaultParameterSetName = 'Publish')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Init',
            HelpMessage = "Genera archivos de configuración (sqlpackage.yaml y .env)")]
        [switch]$Init,

        [Parameter(Mandatory, ParameterSetName = 'Publish',
            HelpMessage = "Despliega el .dacpac al servidor (build → report → confirm → publish)")]
        [switch]$Publish,

        [Parameter(Mandatory, ParameterSetName = 'DeployReport',
            HelpMessage = "Genera reporte XML de diferencias (dry-run)")]
        [switch]$DeployReport,

        [Parameter(Mandatory, ParameterSetName = 'Script',
            HelpMessage = "Genera el script SQL que Publish ejecutaría")]
        [switch]$Script,

        [Parameter(Mandatory, ParameterSetName = 'Extract',
            HelpMessage = "Captura el esquema actual del servidor como .dacpac")]
        [switch]$Extract,

        [Parameter(Mandatory, ParameterSetName = 'Export',
            HelpMessage = "Exporta esquema + datos del servidor como .bacpac")]
        [switch]$Export,

        [Parameter(Mandatory, ParameterSetName = 'Import',
            HelpMessage = "Importa un archivo .bacpac al servidor")]
        [switch]$Import
    )

    begin {
        $ErrorActionPreference = 'Stop'
    }

    process {
        # Banner
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║           SqlPackage — PSDevOps                  ║" -ForegroundColor Cyan
        Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""

        switch ($PSCmdlet.ParameterSetName) {
            'Init' {
                # Validar que existe .sqlproj
                $sqlproj = Get-ChildItem -Path "." -Filter "*.sqlproj" -File | Select-Object -First 1
                if (-not $sqlproj) {
                    throw "No se encontró un archivo .sqlproj en el directorio actual. Ejecute este cmdlet desde un SQL Project."
                }

                Write-Host "  Inicializando configuración para: $($sqlproj.Name)" -ForegroundColor Cyan
                Write-Host ""
                New-SqlPackageConfig
                Write-Host ""
                Write-Host "  Configuración creada. Edite los archivos según su entorno:" -ForegroundColor Green
                Write-Host "    sqlpackage.yaml  → parámetros de SqlPackage (versionar)" -ForegroundColor DarkGray
                Write-Host "    .env             → credenciales del servidor (NO versionar)" -ForegroundColor DarkGray
                Write-Host ""
            }

            'Publish' {
                # Validar prerequisitos
                $sqlproj = Get-ChildItem -Path "." -Filter "*.sqlproj" -File | Select-Object -First 1
                if (-not $sqlproj) { throw "No se encontró .sqlproj en el directorio actual." }
                if (-not (Test-Path ".\sqlpackage.yaml")) { throw "No se encontró sqlpackage.yaml. Ejecute 'Invoke-SqlPackage -Init'." }
                if (-not (Test-Path ".\.env")) { throw "No se encontró .env. Ejecute 'Invoke-SqlPackage -Init'." }

                $config = Read-SqlPackageConfig
                $envConfig = Read-DotEnv -Path ".\.env"
                $envVars = $envConfig.Env

                try {
                    Write-Host "  Servidor:  $($envVars['DB_SERVER'])" -ForegroundColor Cyan
                    Write-Host "  Base datos: $($envVars['DB_NAME'])" -ForegroundColor Cyan
                    Write-Host "  Usuario:   $($envVars['DB_USER'])" -ForegroundColor Cyan
                    Write-Host ""

                    # 1. Build
                    Write-Host "  Compilando proyecto..." -ForegroundColor Cyan
                    $buildResult = dotnet build 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "  ERROR: La compilación falló" -ForegroundColor Red
                        $buildResult | Write-Host
                        throw "Build fallido"
                    }
                    Write-Host "  Build exitoso" -ForegroundColor Green
                    Write-Host ""

                    # 2. DeployReport
                    Write-Host "  Generando reporte de cambios..." -ForegroundColor Cyan
                    $dacpacPath = Find-DacpacPath
                    if (-not (Test-Path $dacpacPath)) { throw "No se encontró $dacpacPath" }

                    $reportPath = ".\deploy_report_$(Get-Date -Format 'yyyyMMdd_HHmmss').xml"
                    $reportArgs = Build-SqlPackageArgs -Action 'DeployReport' -Config $config -EnvVars $envVars -DacpacPath $dacpacPath -OutputPath $reportPath

                    & sqlpackage @reportArgs 2>&1 | Tee-Object -Variable reportOutput
                    if ($LASTEXITCODE -ne 0) {
                        throw "No se pudo generar el reporte. Verifique la conexión y permisos."
                    }

                    # 3. Mostrar cambios
                    $changes = Show-DeployReport -ReportPath $reportPath
                    if ($null -eq $changes) {
                        Remove-Item $reportPath -ErrorAction SilentlyContinue
                        return
                    }

                    # 4. Confirmación
                    $confirm = Read-Host "  ¿Aplicar estos cambios? (S/N)"
                    if ($confirm -notmatch '^[Ss]$') {
                        Write-Host "  Despliegue cancelado." -ForegroundColor Yellow
                        Remove-Item $reportPath -ErrorAction SilentlyContinue
                        return
                    }

                    # 5. Publish
                    Write-Host ""
                    Write-Host "  Iniciando despliegue..." -ForegroundColor Cyan
                    $publishArgs = Build-SqlPackageArgs -Action 'Publish' -Config $config -EnvVars $envVars -DacpacPath $dacpacPath

                    & sqlpackage @publishArgs 2>&1 | Tee-Object -Variable publishOutput
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host ""
                        Write-Host "  Despliegue completado exitosamente" -ForegroundColor Green
                        Remove-Item $reportPath -ErrorAction SilentlyContinue
                    }
                    else {
                        throw "El despliegue falló con código de salida: $LASTEXITCODE"
                    }
                }
                finally {
                    # Limpiar contraseña de memoria
                    if ($envVars) { $envVars['DB_PASSWORD'] = $null }
                    [System.GC]::Collect()
                }
            }

            'DeployReport' {
                # Validar prerequisitos
                if (-not (Test-Path ".\sqlpackage.yaml")) { throw "No se encontró sqlpackage.yaml. Ejecute 'Invoke-SqlPackage -Init'." }
                if (-not (Test-Path ".\.env")) { throw "No se encontró .env. Ejecute 'Invoke-SqlPackage -Init'." }

                $config = Read-SqlPackageConfig
                $envConfig = Read-DotEnv -Path ".\.env"
                $envVars = $envConfig.Env

                try {
                    Write-Host "  Servidor:  $($envVars['DB_SERVER'])" -ForegroundColor Cyan
                    Write-Host "  Base datos: $($envVars['DB_NAME'])" -ForegroundColor Cyan
                    Write-Host "  Modo: SOLO REPORTE" -ForegroundColor Cyan
                    Write-Host ""

                    # Build
                    Write-Host "  Compilando proyecto..." -ForegroundColor Cyan
                    $buildResult = dotnet build 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "  ERROR: La compilación falló" -ForegroundColor Red
                        $buildResult | Write-Host
                        throw "Build fallido"
                    }
                    Write-Host "  Build exitoso" -ForegroundColor Green
                    Write-Host ""

                    $dacpacPath = Find-DacpacPath
                    if (-not (Test-Path $dacpacPath)) { throw "No se encontró $dacpacPath" }

                    $outputDir = "."
                    if ($config.deployReport -and $config.deployReport.outputDir) {
                        $outputDir = $config.deployReport.outputDir
                    }
                    $reportPath = Join-Path $outputDir "deploy_report_$(Get-Date -Format 'yyyyMMdd_HHmmss').xml"

                    Write-Host "  Generando reporte de cambios..." -ForegroundColor Cyan
                    $reportArgs = Build-SqlPackageArgs -Action 'DeployReport' -Config $config -EnvVars $envVars -DacpacPath $dacpacPath -OutputPath $reportPath

                    & sqlpackage @reportArgs 2>&1 | Tee-Object -Variable reportOutput
                    if ($LASTEXITCODE -ne 0) {
                        throw "No se pudo generar el reporte. Verifique la conexión y permisos."
                    }

                    $changes = Show-DeployReport -ReportPath $reportPath
                    Write-Host "  Reporte guardado en: $reportPath" -ForegroundColor DarkGray
                    Write-Host ""
                }
                finally {
                    # Limpiar contraseña de memoria
                    if ($envVars) { $envVars['DB_PASSWORD'] = $null }
                    [System.GC]::Collect()
                }
            }

            'Script' {
                if (-not (Test-Path ".\sqlpackage.yaml")) { throw "No se encontró sqlpackage.yaml. Ejecute 'Invoke-SqlPackage -Init'." }
                if (-not (Test-Path ".\.env")) { throw "No se encontró .env. Ejecute 'Invoke-SqlPackage -Init'." }

                $config = Read-SqlPackageConfig
                $envConfig = Read-DotEnv -Path ".\.env"
                $envVars = $envConfig.Env

                try {
                    Write-Host "  Servidor:  $($envVars['DB_SERVER'])" -ForegroundColor Cyan
                    Write-Host "  Base datos: $($envVars['DB_NAME'])" -ForegroundColor Cyan
                    Write-Host "  Modo: GENERAR SCRIPT SQL" -ForegroundColor Cyan
                    Write-Host ""

                    # Build
                    Write-Host "  Compilando proyecto..." -ForegroundColor Cyan
                    $buildResult = dotnet build 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "  ERROR: La compilación falló" -ForegroundColor Red
                        $buildResult | Write-Host
                        throw "Build fallido"
                    }
                    Write-Host "  Build exitoso" -ForegroundColor Green
                    Write-Host ""

                    $dacpacPath = Find-DacpacPath
                    if (-not (Test-Path $dacpacPath)) { throw "No se encontró $dacpacPath" }

                    $outputDir = "."
                    if ($config.script -and $config.script.outputDir) {
                        $outputDir = $config.script.outputDir
                    }
                    $scriptPath = Join-Path $outputDir "deploy_script_$(Get-Date -Format 'yyyyMMdd_HHmmss').sql"

                    Write-Host "  Generando script SQL..." -ForegroundColor Cyan
                    $scriptArgs = Build-SqlPackageArgs -Action 'Script' -Config $config -EnvVars $envVars -DacpacPath $dacpacPath -OutputPath $scriptPath

                    & sqlpackage @scriptArgs 2>&1 | Tee-Object -Variable scriptOutput
                    if ($LASTEXITCODE -ne 0) {
                        throw "No se pudo generar el script. Verifique la conexión y permisos."
                    }

                    Write-Host ""
                    Write-Host "  Script generado en: $scriptPath" -ForegroundColor Green
                    Write-Host ""
                }
                finally {
                    # Limpiar contraseña de memoria
                    if ($envVars) { $envVars['DB_PASSWORD'] = $null }
                    [System.GC]::Collect()
                }
            }

            'Extract' {
                if (-not (Test-Path ".\.env")) { throw "No se encontró .env. Ejecute 'Invoke-SqlPackage -Init'." }
                if (-not (Test-Path ".\sqlpackage.yaml")) { throw "No se encontró sqlpackage.yaml. Ejecute 'Invoke-SqlPackage -Init'." }

                $config = Read-SqlPackageConfig
                $envConfig = Read-DotEnv -Path ".\.env"
                $envVars = $envConfig.Env

                try {
                    Write-Host "  Servidor:  $($envVars['DB_SERVER'])" -ForegroundColor Cyan
                    Write-Host "  Base datos: $($envVars['DB_NAME'])" -ForegroundColor Cyan
                    Write-Host "  Modo: EXTRACT (snapshot)" -ForegroundColor Cyan
                    Write-Host ""

                    $outputDir = "./snapshots"
                    if ($config.extract -and $config.extract.outputDir) {
                        $outputDir = $config.extract.outputDir
                    }
                    if (-not (Test-Path $outputDir)) { New-Item -Path $outputDir -ItemType Directory -Force | Out-Null }

                    $dbName = $envVars['DB_NAME']
                    $extractPath = Join-Path $outputDir "$($dbName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').dacpac"

                    Write-Host "  Extrayendo esquema del servidor..." -ForegroundColor Cyan
                    $extractArgs = Build-SqlPackageArgs -Action 'Extract' -Config $config -EnvVars $envVars -OutputPath $extractPath

                    & sqlpackage @extractArgs 2>&1 | Tee-Object -Variable extractOutput
                    if ($LASTEXITCODE -ne 0) {
                        throw "No se pudo extraer el esquema. Verifique la conexión y permisos."
                    }

                    Write-Host ""
                    Write-Host "  Snapshot guardado en: $extractPath" -ForegroundColor Green
                    Write-Host ""
                }
                finally {
                    # Limpiar contraseña de memoria
                    if ($envVars) { $envVars['DB_PASSWORD'] = $null }
                    [System.GC]::Collect()
                }
            }

            'Export' {
                if (-not (Test-Path ".\.env")) { throw "No se encontró .env. Ejecute 'Invoke-SqlPackage -Init'." }
                if (-not (Test-Path ".\sqlpackage.yaml")) { throw "No se encontró sqlpackage.yaml. Ejecute 'Invoke-SqlPackage -Init'." }

                $config = Read-SqlPackageConfig
                $envConfig = Read-DotEnv -Path ".\.env"
                $envVars = $envConfig.Env

                try {
                    Write-Host "  Servidor:  $($envVars['DB_SERVER'])" -ForegroundColor Cyan
                    Write-Host "  Base datos: $($envVars['DB_NAME'])" -ForegroundColor Cyan
                    Write-Host "  Modo: EXPORT (esquema + datos)" -ForegroundColor Cyan
                    Write-Host ""

                    $outputDir = "./exports"
                    if ($config.export -and $config.export.outputDir) {
                        $outputDir = $config.export.outputDir
                    }
                    if (-not (Test-Path $outputDir)) { New-Item -Path $outputDir -ItemType Directory -Force | Out-Null }

                    $dbName = $envVars['DB_NAME']
                    $exportPath = Join-Path $outputDir "$($dbName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').bacpac"

                    Write-Host "  Exportando esquema y datos..." -ForegroundColor Cyan
                    $exportArgs = Build-SqlPackageArgs -Action 'Export' -Config $config -EnvVars $envVars -OutputPath $exportPath

                    & sqlpackage @exportArgs 2>&1 | Tee-Object -Variable exportOutput
                    if ($LASTEXITCODE -ne 0) {
                        throw "No se pudo exportar. Verifique la conexión y permisos."
                    }

                    Write-Host ""
                    Write-Host "  Exportación guardada en: $exportPath" -ForegroundColor Green
                    Write-Host ""
                }
                finally {
                    # Limpiar contraseña de memoria
                    if ($envVars) { $envVars['DB_PASSWORD'] = $null }
                    [System.GC]::Collect()
                }
            }

            'Import' {
                if (-not (Test-Path ".\.env")) { throw "No se encontró .env. Ejecute 'Invoke-SqlPackage -Init'." }
                if (-not (Test-Path ".\sqlpackage.yaml")) { throw "No se encontró sqlpackage.yaml. Ejecute 'Invoke-SqlPackage -Init'." }

                $config = Read-SqlPackageConfig
                $envConfig = Read-DotEnv -Path ".\.env"
                $envVars = $envConfig.Env

                # Obtener ruta del .bacpac
                $sourcePath = $null
                if ($config.import -and $config.import.sourcePath) {
                    $sourcePath = $config.import.sourcePath
                }
                if (-not $sourcePath -or -not (Test-Path $sourcePath)) {
                    throw "Configure 'import.sourcePath' en sqlpackage.yaml con la ruta al archivo .bacpac"
                }

                try {
                    Write-Host "  Servidor:  $($envVars['DB_SERVER'])" -ForegroundColor Cyan
                    Write-Host "  Base datos: $($envVars['DB_NAME'])" -ForegroundColor Cyan
                    Write-Host "  Fuente:    $sourcePath" -ForegroundColor Cyan
                    Write-Host "  Modo: IMPORT (.bacpac → servidor)" -ForegroundColor Yellow
                    Write-Host ""
                    Write-Host "  ADVERTENCIA: Esta acción reemplazará la base de datos completa." -ForegroundColor Red
                    Write-Host ""

                    $confirm = Read-Host "  ¿Continuar con la importación? (S/N)"
                    if ($confirm -notmatch '^[Ss]$') {
                        Write-Host "  Importación cancelada." -ForegroundColor Yellow
                        return
                    }

                    Write-Host ""
                    Write-Host "  Importando .bacpac..." -ForegroundColor Cyan
                    $importArgs = Build-SqlPackageArgs -Action 'Import' -Config $config -EnvVars $envVars -SourcePath $sourcePath

                    & sqlpackage @importArgs 2>&1 | Tee-Object -Variable importOutput
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host ""
                        Write-Host "  Importación completada exitosamente" -ForegroundColor Green
                    }
                    else {
                        throw "La importación falló con código de salida: $LASTEXITCODE"
                    }
                }
                finally {
                    # Limpiar contraseña de memoria
                    if ($envVars) { $envVars['DB_PASSWORD'] = $null }
                    [System.GC]::Collect()
                }
            }
        }
    }
}
