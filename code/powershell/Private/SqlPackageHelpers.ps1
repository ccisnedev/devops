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
        [string]$SourcePath,

        # El nombre de la base llega resuelto desde <Name> del .sqlproj (ADR 0011); el env solo
        # aporta conexion y credenciales.
        [Parameter(Mandatory)]
        [string]$Database
    )

    $sqlArgs = @("/Action:$Action")

    # Conexión al servidor (credenciales desde .env)
    $server   = $EnvVars['DB_SERVER']
    $database = $Database
    $user     = $EnvVars['DB_USER']
    $password = $EnvVars['DB_PASSWORD']

    if (-not $server -or -not $user -or -not $password) {
        throw "Faltan variables en el env file. Se requieren: DB_SERVER, DB_USER, DB_PASSWORD"
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
    Indexa por Id las alertas de un DeployReport XML.

.DESCRIPTION
    SqlPackage no escribe las consecuencias de una operación dentro de su <Item>: las deja en
    un bloque <Alerts> aparte y las enlaza por Id desde el objeto afectado. Un Alter de tabla
    que borra tres columnas se ve, en la rama <Operations>, exactamente igual que uno que no
    borra nada; la diferencia entera vive en <Alerts>.

    Esta función resuelve ese enlace: devuelve un índice Id → alerta que Show-DeployReport usa
    para colgar cada advertencia bajo el objeto que la provoca.

.PARAMETER Report
    Documento XML del DeployReport ya cargado.

.OUTPUTS
    Hashtable — Id (string) → PSCustomObject con Id, Kind, Message, IsDataLoss.
#>
function Get-DeployReportAlert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [xml]$Report
    )

    $index = @{}

    # ChildNodes + LocalName en vez de $Report.DeploymentReport.Alerts.Alert: el documento
    # declara un namespace por defecto y los nombres 'Name' y 'Value' chocan con propiedades
    # propias de XmlElement.
    $alertsNode = $Report.DocumentElement.ChildNodes | Where-Object { $_.LocalName -eq 'Alerts' }
    $alerts = $alertsNode.ChildNodes | Where-Object { $_.LocalName -eq 'Alert' }

    foreach ($alert in $alerts) {
        $kind = $alert.GetAttribute('Name')
        $issues = $alert.ChildNodes | Where-Object { $_.LocalName -eq 'Issue' }
        foreach ($issue in $issues) {
            $id = $issue.GetAttribute('Id')
            $index[$id] = [PSCustomObject]@{
                Id         = $id
                Kind       = $kind
                Message    = $issue.GetAttribute('Value')
                IsDataLoss = ($kind -eq 'DataIssue')
            }
        }
    }

    return $index
}

<#
.SYNOPSIS
    Parsea un DeployReport XML y muestra un resumen visual de las operaciones.

.DESCRIPTION
    Lee el archivo XML generado por SqlPackage /Action:DeployReport y muestra cada operación
    detectada con formato y colores, junto con las alertas que cada objeto arrastra.

    Las alertas importan tanto como las operaciones. El 2026-08-10 un despliegue a IMPULSA
    mostró "Alter → [dbo].[CanastaPersona]" y nada más; ese Alter borraba tres columnas con
    datos y el despliegue abortó contra el guardián de BlockOnPossibleDataLoss. La advertencia
    existía —en la salida cruda de sqlpackage, sepultada entre 27 warnings de cuentas— pero el
    resumen que uno lee justo antes de teclear "y" la callaba.

.PARAMETER ReportPath
    Ruta al archivo XML del DeployReport.

.OUTPUTS
    PSCustomObject[] — Array de operaciones encontradas, o $null si no hay cambios.
    Cada elemento lleva Operation, Object, Issues (string[]) y HasDataLoss (bool).
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
    $alerts = Get-DeployReportAlert -Report $report
    $referenced = @{}
    $dataLossCount = 0
    $dataLossObjects = 0

    if ($null -eq $operations) {
        Show-DeployReportOrphanAlert -Alerts $alerts -Referenced $referenced | Out-Null
        Write-Host "  No hay cambios pendientes. La base de datos está sincronizada." -ForegroundColor Green
        return $null
    }

    Write-Host ""
    Write-Host "  Cambios detectados:" -ForegroundColor Cyan
    $results = @()

    foreach ($operation in @($operations)) {
        $op = $operation.GetAttribute('Name')
        $items = $operation.ChildNodes | Where-Object { $_.LocalName -eq 'Item' }

        foreach ($item in $items) {
            $itemAlerts = @()
            foreach ($ref in ($item.ChildNodes | Where-Object { $_.LocalName -eq 'Issue' })) {
                $id = $ref.GetAttribute('Id')
                $referenced[$id] = $true
                if ($alerts.ContainsKey($id)) { $itemAlerts += $alerts[$id] }
            }

            $lossAlerts = @($itemAlerts | Where-Object { $_.IsDataLoss })
            $hasDataLoss = $lossAlerts.Count -gt 0
            if ($hasDataLoss) {
                $dataLossCount += $lossAlerts.Count
                $dataLossObjects++
            }

            $objectName = $item.GetAttribute('Value')
            Write-Host "    $op → $objectName" -ForegroundColor $(if ($hasDataLoss) { 'Red' } else { 'Yellow' })
            foreach ($alert in $itemAlerts) {
                Write-Host "        $(Format-DeployReportAlert -Alert $alert)" `
                    -ForegroundColor $(if ($alert.IsDataLoss) { 'Red' } else { 'DarkYellow' })
            }

            $results += [PSCustomObject]@{
                Operation   = $op
                Object      = $objectName
                Issues      = @($itemAlerts | ForEach-Object { $_.Message })
                HasDataLoss = $hasDataLoss
            }
        }
    }

    $dataLossCount += (Show-DeployReportOrphanAlert -Alerts $alerts -Referenced $referenced)

    if ($dataLossCount -gt 0) {
        Write-Host ""
        Write-Host "  PÉRDIDA DE DATOS: $dataLossCount advertencia(s) en $dataLossObjects objeto(s)." -ForegroundColor Red
        Write-Host "  Con BlockOnPossibleDataLoss activo el despliegue abortará; sin él, los datos se van." -ForegroundColor Red
    }

    Write-Host ""
    return $results
}

<#
.SYNOPSIS
    Formatea una alerta del DeployReport como una línea legible.
#>
function Format-DeployReportAlert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Alert
    )

    $label = if ($Alert.IsDataLoss) { 'PÉRDIDA DE DATOS' } else { $Alert.Kind }
    return "! ${label}: $($Alert.Message)"
}

<#
.SYNOPSIS
    Muestra las alertas que ningún objeto del plan referencia.

.DESCRIPTION
    Una alerta cuyo Id no aparece en ningún <Item> no tiene dónde colgarse. Callarla repetiría,
    en la otra rama del XML, el mismo modo de falla que este módulo corrige: información de
    pérdida de datos presente en el reporte y ausente del resumen.

.OUTPUTS
    Int — Cantidad de alertas huérfanas de pérdida de datos, para el conteo del resumen.
#>
function Show-DeployReportOrphanAlert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Alerts,

        [Parameter(Mandatory)]
        [hashtable]$Referenced
    )

    $orphans = @($Alerts.Values | Where-Object { -not $Referenced.ContainsKey($_.Id) })
    if ($orphans.Count -eq 0) { return 0 }

    Write-Host ""
    Write-Host "  Alertas sin objeto asociado:" -ForegroundColor Red
    foreach ($alert in $orphans) {
        Write-Host "    $(Format-DeployReportAlert -Alert $alert)" `
            -ForegroundColor $(if ($alert.IsDataLoss) { 'Red' } else { 'DarkYellow' })
    }

    return @($orphans | Where-Object { $_.IsDataLoss }).Count
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
