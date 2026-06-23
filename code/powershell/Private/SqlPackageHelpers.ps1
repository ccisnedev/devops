# SqlPackageHelpers.ps1
# Funciones helper para Invoke-SqlPackage

<#
.SYNOPSIS
    Lee y parsea el archivo sqlpackage.yaml del directorio actual.

.DESCRIPTION
    Usa ConvertFrom-Yaml (powershell-yaml) para parsear el archivo de configuración.
    Valida que existan las secciones mínimas requeridas (properties).

.PARAMETER Path
    Ruta al archivo sqlpackage.yaml. Por defecto: ./sqlpackage.yaml

.OUTPUTS
    Hashtable con la configuración parseada.
#>
function Read-SqlPackageConfig {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Path = ".\sqlpackage.yaml"
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
        throw "No se encontró '$Path'. Ejecute 'Invoke-SqlPackage -Init' para generarlo."
    }

    $raw = Get-Content $Path -Raw
    $config = ConvertFrom-Yaml $raw

    if (-not $config.properties) {
        throw "El archivo '$Path' no tiene la sección 'properties' requerida."
    }

    return $config
}

<#
.SYNOPSIS
    Construye el array de argumentos para sqlpackage.exe.

.DESCRIPTION
    Traduce la configuración YAML + credenciales .env en argumentos de línea de comando
    compatibles con sqlpackage.exe.

.PARAMETER Action
    La acción de SqlPackage (Publish, DeployReport, Script, Extract, Export, Import).

.PARAMETER Config
    Hashtable de configuración leída de sqlpackage.yaml.

.PARAMETER EnvVars
    Hashtable de variables de entorno leídas de .env.

.PARAMETER DacpacPath
    Ruta al archivo .dacpac (requerido para Publish, DeployReport, Script).

.PARAMETER OutputPath
    Ruta de salida para el archivo generado (requerido para DeployReport, Script, Extract, Export).

.PARAMETER SourcePath
    Ruta al archivo fuente .bacpac (requerido para Import).

.OUTPUTS
    String[] — Array de argumentos para sqlpackage.exe.
#>
function Build-SqlPackageArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Publish', 'DeployReport', 'Script', 'Extract', 'Export', 'Import')]
        [string]$Action,

        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [hashtable]$EnvVars,

        [Parameter()]
        [string]$DacpacPath,

        [Parameter()]
        [string]$OutputPath,

        [Parameter()]
        [string]$SourcePath
    )

    $sqlArgs = @("/Action:$Action")

    # Conexión al servidor (credenciales desde .env)
    $server   = $EnvVars['DB_SERVER']
    $database = $EnvVars['DB_NAME']
    $user     = $EnvVars['DB_USER']
    $password = $EnvVars['DB_PASSWORD']

    if (-not $server -or -not $database -or -not $user -or -not $password) {
        throw "Faltan variables en .env. Se requieren: DB_SERVER, DB_NAME, DB_USER, DB_PASSWORD"
    }

    # Acciones que usan Source (el .dacpac como fuente)
    $dacpacActions = @('Publish', 'DeployReport', 'Script')
    # Acciones que leen del servidor (Extract, Export)
    $serverSourceActions = @('Extract', 'Export')

    if ($Action -in $dacpacActions) {
        if (-not $DacpacPath) {
            throw "Se requiere -DacpacPath para la acción '$Action'"
        }
        $sqlArgs += "/SourceFile:$DacpacPath"
        $sqlArgs += "/TargetServerName:$server"
        $sqlArgs += "/TargetDatabaseName:$database"
        $sqlArgs += "/TargetUser:$user"
        $sqlArgs += "/TargetPassword:$password"
        $sqlArgs += "/TargetTrustServerCertificate:True"
        $sqlArgs += "/TargetEncryptConnection:True"
    }
    elseif ($Action -in $serverSourceActions) {
        $sqlArgs += "/SourceServerName:$server"
        $sqlArgs += "/SourceDatabaseName:$database"
        $sqlArgs += "/SourceUser:$user"
        $sqlArgs += "/SourcePassword:$password"
        $sqlArgs += "/SourceTrustServerCertificate:True"
        $sqlArgs += "/SourceEncryptConnection:True"
    }
    elseif ($Action -eq 'Import') {
        if (-not $SourcePath) {
            throw "Se requiere la ruta al archivo .bacpac en la configuración (import.sourcePath)"
        }
        $sqlArgs += "/SourceFile:$SourcePath"
        $sqlArgs += "/TargetServerName:$server"
        $sqlArgs += "/TargetDatabaseName:$database"
        $sqlArgs += "/TargetUser:$user"
        $sqlArgs += "/TargetPassword:$password"
        $sqlArgs += "/TargetTrustServerCertificate:True"
        $sqlArgs += "/TargetEncryptConnection:True"
    }

    # Output path
    if ($OutputPath) {
        if ($Action -in $serverSourceActions) {
            $sqlArgs += "/TargetFile:$OutputPath"
        }
        else {
            $sqlArgs += "/OutputPath:$OutputPath"
        }
    }

    # Propiedades /p: (solo para acciones que las soportan)
    $propsActions = @('Publish', 'DeployReport', 'Script')
    if ($Action -in $propsActions -and $Config.properties) {
        foreach ($key in $Config.properties.Keys) {
            $sqlArgs += "/p:$key=$($Config.properties[$key])"
        }
    }

    # Variables SqlCmd /v: desde .env: cualquier variable con prefijo SQLVAR_ se pasa como
    # /v:<nombre>=<valor> (p. ej. SQLVAR_FotosApiLoginPassword -> /v:FotosApiLoginPassword=...).
    # Permite inyectar secretos (p. ej. contrasenas de logins en el modelo) en el deploy sin
    # commitearlos en el repo.
    if ($Action -in $propsActions) {
        foreach ($key in $EnvVars.Keys) {
            if ($key -like 'SQLVAR_*') {
                $varName = $key.Substring(7)
                $sqlArgs += "/v:$varName=$($EnvVars[$key])"
            }
        }
    }

    return $sqlArgs
}

<#
.SYNOPSIS
    Busca el archivo .dacpac correspondiente al proyecto SQL actual.

.DESCRIPTION
    Localiza el archivo .sqlproj en el directorio actual, extrae el nombre del proyecto
    y construye la ruta esperada del .dacpac en bin/Debug/.

.OUTPUTS
    String — Ruta al archivo .dacpac.
#>
function Find-DacpacPath {
    [CmdletBinding()]
    param()

    $sqlproj = Get-ChildItem -Path "." -Filter "*.sqlproj" -File | Select-Object -First 1
    if (-not $sqlproj) {
        throw "No se encontró un archivo .sqlproj en el directorio actual."
    }

    $projectName = [System.IO.Path]::GetFileNameWithoutExtension($sqlproj.Name)
    $dacpacPath = ".\bin\Debug\$projectName.dacpac"

    return $dacpacPath
}

<#
.SYNOPSIS
    Parsea un DeployReport XML y muestra un resumen visual de las operaciones.

.DESCRIPTION
    Lee el archivo XML generado por SqlPackage /Action:DeployReport y muestra
    cada operación detectada con formato y colores.

.PARAMETER ReportPath
    Ruta al archivo XML del DeployReport.

.OUTPUTS
    PSCustomObject[] — Array de operaciones encontradas, o $null si no hay cambios.
#>
function Show-DeployReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ReportPath
    )

    if (-not (Test-Path $ReportPath)) {
        throw "No se encontró el reporte: $ReportPath"
    }

    [xml]$report = Get-Content $ReportPath
    $operations = $report.DeploymentReport.Operations.Operation

    if ($null -eq $operations) {
        Write-Host "  No hay cambios pendientes. La base de datos está sincronizada." -ForegroundColor Green
        return $null
    }

    Write-Host ""
    Write-Host "  Cambios detectados:" -ForegroundColor Cyan
    $results = @()

    $operations | ForEach-Object {
        $op = $_.Name
        $items = $_.Item
        if ($items -is [array]) {
            $items | ForEach-Object {
                Write-Host "    $op → $($_.Value)" -ForegroundColor Yellow
                $results += [PSCustomObject]@{ Operation = $op; Object = $_.Value }
            }
        }
        else {
            Write-Host "    $op → $($items.Value)" -ForegroundColor Yellow
            $results += [PSCustomObject]@{ Operation = $op; Object = $items.Value }
        }
    }

    Write-Host ""
    return $results
}

<#
.SYNOPSIS
    Copia las plantillas de configuración al directorio actual.

.DESCRIPTION
    Copia sqlpackage.yaml y .env.example desde los templates del módulo
    al directorio de trabajo actual. No sobrescribe archivos existentes.

.PARAMETER Force
    Sobrescribir archivos existentes.
#>
function New-SqlPackageConfig {
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    $templateDir = Join-Path $PSScriptRoot "..\Resources\Invoke-SqlPackage\templates"

    # sqlpackage.yaml
    $yamlTarget = Join-Path (Get-Location) "sqlpackage.yaml"
    $yamlSource = Join-Path $templateDir "sqlpackage.yaml"

    if ((Test-Path $yamlTarget) -and -not $Force) {
        Write-Host "  sqlpackage.yaml ya existe (use -Force para sobrescribir)" -ForegroundColor Yellow
    }
    else {
        Copy-Item $yamlSource $yamlTarget -Force
        Write-Host "  sqlpackage.yaml creado" -ForegroundColor Green
    }

    # .env
    $envTarget = Join-Path (Get-Location) ".env"
    $envExampleSource = Join-Path $templateDir ".env.example"

    if ((Test-Path $envTarget) -and -not $Force) {
        Write-Host "  .env ya existe (use -Force para sobrescribir)" -ForegroundColor Yellow
    }
    else {
        Copy-Item $envExampleSource $envTarget -Force
        Write-Host "  .env creado (configure las credenciales)" -ForegroundColor Green
    }
}
