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
        Version: 1.0.1
    #>
    [CmdletBinding(DefaultParameterSetName = 'Apply')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Init',
            HelpMessage = "Generate configuration files (sqlpackage.yaml and .env)")]
        [switch]$Init,

        [Parameter(Mandatory, ParameterSetName = 'Apply',
            HelpMessage = "Deploy the .dacpac to the server (build -> plan -> confirm -> apply)")]
        [switch]$Apply,

        [Parameter(Mandatory, ParameterSetName = 'Plan',
            HelpMessage = "Dry-run: XML diff report of what -Apply would change")]
        [switch]$Plan,

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
        [switch]$Import,

        [Parameter(ParameterSetName = 'Apply',
            HelpMessage = "Skip the confirmation prompt for unattended/CI use (ADR 0002)")]
        [Parameter(ParameterSetName = 'Import')]
        [switch]$AutoApprove,

        # Env file que selecciona el entorno (ADR 0004): default .env, -EnvFile lo pisa
        # (p.ej. .env.production para prod). Lleva las credenciales del servidor SQL.
        [Parameter(ParameterSetName = 'Apply')]
        [Parameter(ParameterSetName = 'Plan')]
        [Parameter(ParameterSetName = 'Script')]
        [Parameter(ParameterSetName = 'Extract')]
        [Parameter(ParameterSetName = 'Export')]
        [Parameter(ParameterSetName = 'Import',
            HelpMessage = "Env file selecting the environment (default .env). Prod: -EnvFile .env.production")]
        [string]$EnvFile = '.env'
    )

    begin {
        $ErrorActionPreference = 'Stop'
    }

    process {
        # Banner
        Show-MacssBanner -Title 'Invoke-SqlPackage'

        # Deprecation notice for the pre-ADR-0002 vocabulary.
        if ($MyInvocation.Line -match '-(Publish|DeployReport)\b') {
        }

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

            'Apply' {
                # Validar prerequisitos
                $sqlproj = Get-ChildItem -Path "." -Filter "*.sqlproj" -File | Select-Object -First 1
                if (-not $sqlproj) { throw "No se encontró .sqlproj en el directorio actual." }
                if (-not (Test-Path ".\sqlpackage.yaml")) { throw "No se encontró sqlpackage.yaml. Ejecute 'Invoke-SqlPackage -Init'." }
                if (-not (Test-Path $EnvFile)) { throw "No se encontró el env file '$EnvFile'. Ejecute 'Invoke-SqlPackage -Init' o especifique -EnvFile <archivo>." }

                $config = Read-SqlPackageConfig
                $envConfig = Read-DotEnv -Path $EnvFile
                $envVars = $envConfig.Env

                # Identidad de la base: <Name> del .sqlproj, con DB_NAME como override explicito
                # (ADR 0011). El env aporta conexion y credenciales, no identidad.
                $dbIdentity = Resolve-SqlDbIdentity -ProjectRoot (Get-Location).Path -EnvFile $EnvFile
                $dbName = $dbIdentity.Name

                try {
                    Write-Host "  Servidor:  $($envVars['DB_SERVER'])" -ForegroundColor Cyan
                    Write-Host "  Base datos: $dbName$(if ($dbIdentity.IsOverride) { "  (override de DB_NAME; el proyecto declara '$($dbIdentity.ProjectName)')" })" -ForegroundColor Cyan
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

                    # Crear directorio de salida si está configurado y no existe
                    $outputDir = "."
                    if ($config.deployReport -and $config.deployReport.outputDir) {
                        $outputDir = $config.deployReport.outputDir
                    }
                    if (-not (Test-Path $outputDir)) { New-Item -Path $outputDir -ItemType Directory -Force | Out-Null }
                    $reportPath = Join-Path $outputDir "deploy_report_$(Get-Date -Format 'yyyyMMdd_HHmmss').xml"
                    $reportArgs = Build-SqlPackageArgs -Action 'DeployReport' -Config $config -EnvVars $envVars -Database $dbName -DacpacPath $dacpacPath -OutputPath $reportPath

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

                    # 4. Confirmation (ADR 0002): -AutoApprove skips; fails clearly when non-interactive.
                    if (-not (Confirm-MacssChange -Action "Apply dacpac to '$dbName' on '$($envVars['DB_SERVER'])'" -AutoApprove:$AutoApprove)) {
                        Write-Host "  Apply cancelled." -ForegroundColor Yellow
                        Remove-Item $reportPath -ErrorAction SilentlyContinue
                        return
                    }

                    # 5. Publish
                    Write-Host ""
                    Write-Host "  Iniciando despliegue..." -ForegroundColor Cyan
                    $publishArgs = Build-SqlPackageArgs -Action 'Publish' -Config $config -EnvVars $envVars -Database $dbName -DacpacPath $dacpacPath

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

            'Plan' {
                # Validar prerequisitos
                if (-not (Test-Path ".\sqlpackage.yaml")) { throw "No se encontró sqlpackage.yaml. Ejecute 'Invoke-SqlPackage -Init'." }
                if (-not (Test-Path $EnvFile)) { throw "No se encontró el env file '$EnvFile'. Ejecute 'Invoke-SqlPackage -Init' o especifique -EnvFile <archivo>." }

                $config = Read-SqlPackageConfig
                $envConfig = Read-DotEnv -Path $EnvFile
                $envVars = $envConfig.Env

                # Identidad de la base: <Name> del .sqlproj, con DB_NAME como override explicito
                # (ADR 0011). El env aporta conexion y credenciales, no identidad.
                $dbIdentity = Resolve-SqlDbIdentity -ProjectRoot (Get-Location).Path -EnvFile $EnvFile
                $dbName = $dbIdentity.Name
                $outputDir = "."
                if ($config.deployReport -and $config.deployReport.outputDir) {
                    $outputDir = $config.deployReport.outputDir
                }
                if (-not (Test-Path $outputDir)) { New-Item -Path $outputDir -ItemType Directory -Force | Out-Null }

                try {
                    Write-Host "  Servidor:  $($envVars['DB_SERVER'])" -ForegroundColor Cyan
                    Write-Host "  Base datos: $dbName$(if ($dbIdentity.IsOverride) { "  (override de DB_NAME; el proyecto declara '$($dbIdentity.ProjectName)')" })" -ForegroundColor Cyan
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

                    $reportPath = Join-Path $outputDir "deploy_report_$(Get-Date -Format 'yyyyMMdd_HHmmss').xml"

                    Write-Host "  Generando reporte de cambios..." -ForegroundColor Cyan
                    $reportArgs = Build-SqlPackageArgs -Action 'DeployReport' -Config $config -EnvVars $envVars -Database $dbName -DacpacPath $dacpacPath -OutputPath $reportPath

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
                if (-not (Test-Path $EnvFile)) { throw "No se encontró el env file '$EnvFile'. Ejecute 'Invoke-SqlPackage -Init' o especifique -EnvFile <archivo>." }

                $config = Read-SqlPackageConfig
                $envConfig = Read-DotEnv -Path $EnvFile
                $envVars = $envConfig.Env

                # Identidad de la base: <Name> del .sqlproj, con DB_NAME como override explicito
                # (ADR 0011). El env aporta conexion y credenciales, no identidad.
                $dbIdentity = Resolve-SqlDbIdentity -ProjectRoot (Get-Location).Path -EnvFile $EnvFile
                $dbName = $dbIdentity.Name
                $outputDir = "."
                if ($config.script -and $config.script.outputDir) {
                    $outputDir = $config.script.outputDir
                }
                if (-not (Test-Path $outputDir)) { New-Item -Path $outputDir -ItemType Directory -Force | Out-Null }

                try {
                    Write-Host "  Servidor:  $($envVars['DB_SERVER'])" -ForegroundColor Cyan
                    Write-Host "  Base datos: $dbName$(if ($dbIdentity.IsOverride) { "  (override de DB_NAME; el proyecto declara '$($dbIdentity.ProjectName)')" })" -ForegroundColor Cyan
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

                    $scriptPath = Join-Path $outputDir "deploy_script_$(Get-Date -Format 'yyyyMMdd_HHmmss').sql"

                    Write-Host "  Generando script SQL..." -ForegroundColor Cyan
                    $scriptArgs = Build-SqlPackageArgs -Action 'Script' -Config $config -EnvVars $envVars -Database $dbName -DacpacPath $dacpacPath -OutputPath $scriptPath

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
                if (-not (Test-Path $EnvFile)) { throw "No se encontró el env file '$EnvFile'. Ejecute 'Invoke-SqlPackage -Init' o especifique -EnvFile <archivo>." }
                if (-not (Test-Path ".\sqlpackage.yaml")) { throw "No se encontró sqlpackage.yaml. Ejecute 'Invoke-SqlPackage -Init'." }

                $config = Read-SqlPackageConfig
                $envConfig = Read-DotEnv -Path $EnvFile
                $envVars = $envConfig.Env

                # Identidad de la base: <Name> del .sqlproj, con DB_NAME como override explicito
                # (ADR 0011). El env aporta conexion y credenciales, no identidad.
                $dbIdentity = Resolve-SqlDbIdentity -ProjectRoot (Get-Location).Path -EnvFile $EnvFile
                $dbName = $dbIdentity.Name

                try {
                    Write-Host "  Servidor:  $($envVars['DB_SERVER'])" -ForegroundColor Cyan
                    Write-Host "  Base datos: $dbName$(if ($dbIdentity.IsOverride) { "  (override de DB_NAME; el proyecto declara '$($dbIdentity.ProjectName)')" })" -ForegroundColor Cyan
                    Write-Host "  Modo: EXTRACT (snapshot)" -ForegroundColor Cyan
                    Write-Host ""

                    $outputDir = "./snapshots"
                    if ($config.extract -and $config.extract.outputDir) {
                        $outputDir = $config.extract.outputDir
                    }
                    if (-not (Test-Path $outputDir)) { New-Item -Path $outputDir -ItemType Directory -Force | Out-Null }

                    $extractPath = Join-Path $outputDir "$($dbName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').dacpac"

                    Write-Host "  Extrayendo esquema del servidor..." -ForegroundColor Cyan
                    $extractArgs = Build-SqlPackageArgs -Action 'Extract' -Config $config -EnvVars $envVars -Database $dbName -OutputPath $extractPath

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
                if (-not (Test-Path $EnvFile)) { throw "No se encontró el env file '$EnvFile'. Ejecute 'Invoke-SqlPackage -Init' o especifique -EnvFile <archivo>." }
                if (-not (Test-Path ".\sqlpackage.yaml")) { throw "No se encontró sqlpackage.yaml. Ejecute 'Invoke-SqlPackage -Init'." }

                $config = Read-SqlPackageConfig
                $envConfig = Read-DotEnv -Path $EnvFile
                $envVars = $envConfig.Env

                # Identidad de la base: <Name> del .sqlproj, con DB_NAME como override explicito
                # (ADR 0011). El env aporta conexion y credenciales, no identidad.
                $dbIdentity = Resolve-SqlDbIdentity -ProjectRoot (Get-Location).Path -EnvFile $EnvFile
                $dbName = $dbIdentity.Name

                try {
                    Write-Host "  Servidor:  $($envVars['DB_SERVER'])" -ForegroundColor Cyan
                    Write-Host "  Base datos: $dbName$(if ($dbIdentity.IsOverride) { "  (override de DB_NAME; el proyecto declara '$($dbIdentity.ProjectName)')" })" -ForegroundColor Cyan
                    Write-Host "  Modo: EXPORT (esquema + datos)" -ForegroundColor Cyan
                    Write-Host ""

                    $outputDir = "./exports"
                    if ($config.export -and $config.export.outputDir) {
                        $outputDir = $config.export.outputDir
                    }
                    if (-not (Test-Path $outputDir)) { New-Item -Path $outputDir -ItemType Directory -Force | Out-Null }

                    $exportPath = Join-Path $outputDir "$($dbName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').bacpac"

                    Write-Host "  Exportando esquema y datos..." -ForegroundColor Cyan
                    $exportArgs = Build-SqlPackageArgs -Action 'Export' -Config $config -EnvVars $envVars -Database $dbName -OutputPath $exportPath

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
                if (-not (Test-Path $EnvFile)) { throw "No se encontró el env file '$EnvFile'. Ejecute 'Invoke-SqlPackage -Init' o especifique -EnvFile <archivo>." }
                if (-not (Test-Path ".\sqlpackage.yaml")) { throw "No se encontró sqlpackage.yaml. Ejecute 'Invoke-SqlPackage -Init'." }

                $config = Read-SqlPackageConfig
                $envConfig = Read-DotEnv -Path $EnvFile
                $envVars = $envConfig.Env

                # Identidad de la base: <Name> del .sqlproj, con DB_NAME como override explicito
                # (ADR 0011). El env aporta conexion y credenciales, no identidad.
                $dbIdentity = Resolve-SqlDbIdentity -ProjectRoot (Get-Location).Path -EnvFile $EnvFile
                $dbName = $dbIdentity.Name

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
                    Write-Host "  Base datos: $dbName$(if ($dbIdentity.IsOverride) { "  (override de DB_NAME; el proyecto declara '$($dbIdentity.ProjectName)')" })" -ForegroundColor Cyan
                    Write-Host "  Fuente:    $sourcePath" -ForegroundColor Cyan
                    Write-Host "  Modo: IMPORT (.bacpac → servidor)" -ForegroundColor Yellow
                    Write-Host ""
                    Write-Host "  ADVERTENCIA: Esta acción reemplazará la base de datos completa." -ForegroundColor Red
                    Write-Host ""

                    if (-not (Confirm-MacssChange -Action "Import bacpac into '$dbName' on '$($envVars['DB_SERVER'])' (replaces the whole database)" -AutoApprove:$AutoApprove)) {
                        Write-Host "  Import cancelled." -ForegroundColor Yellow
                        return
                    }

                    Write-Host ""
                    Write-Host "  Importando .bacpac..." -ForegroundColor Cyan
                    $importArgs = Build-SqlPackageArgs -Action 'Import' -Config $config -EnvVars $envVars -Database $dbName -SourcePath $sourcePath

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
