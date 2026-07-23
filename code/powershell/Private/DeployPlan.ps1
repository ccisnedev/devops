# DeployPlan.ps1
# Shared plan artifact + rendering for every Plan/Apply cmdlet (ADR 0009, extends ADR 0002).
#
# One structured plan object, one renderer used by BOTH -Plan and -Apply (so -Apply shows
# exactly what -Plan shows — ADR 0002 §"Confirmation flow" step 1), and one markdown report
# writer used by -Plan only.
#
# Contract:
#   $plan = New-DeployPlan -Cmdlet 'Publish-FlutterWeb' -Target 'prod (1.2.3.4)' `
#               -Sections $sections -Actions $actions
#   Show-DeployPlan -Plan $plan                       # -> screen (Plan AND Apply)
#   $report = Save-DeployPlan -Plan $plan -ProjectRoot $cwd   # -> file (Plan only)
#
# A section is an [ordered] map of label -> value, where value is a plain string or a row
# built with New-DeployPlanRow (text + severity level). Level drives color on screen and a
# marker in the markdown report.

$script:DeployPlanColors = @{
    info  = 'White'
    ok    = 'Green'
    warn  = 'Yellow'
    error = 'Red'
    muted = 'DarkGray'
}

$script:DeployPlanMarkers = @{
    info  = ''
    ok    = 'OK '
    warn  = 'WARN '
    error = 'FAIL '
    muted = ''
}

function New-DeployPlanRow {
    <#
    .SYNOPSIS
        A single plan value with a severity level (drives color on screen / marker in md).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [ValidateSet('info', 'ok', 'warn', 'error', 'muted')][string]$Level = 'info'
    )
    return [pscustomobject]@{ Text = $Text; Level = $Level }
}

function ConvertTo-DeployPlanRow {
    <#
    .SYNOPSIS
        Normalizes a section value (plain string or a row object) into a row object.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Value)

    if ($null -eq $Value) { return (New-DeployPlanRow -Text '' -Level 'muted') }
    if ($Value -is [psobject] -and $Value.PSObject.Properties['Text'] -and $Value.PSObject.Properties['Level']) {
        return $Value
    }
    return (New-DeployPlanRow -Text ([string]$Value) -Level 'info')
}

function New-DeployPlan {
    <#
    .SYNOPSIS
        Builds the common, cmdlet-agnostic plan object consumed by Show-/Save-DeployPlan.
    .PARAMETER Cmdlet
        The cmdlet the plan belongs to (e.g. 'Publish-FlutterWeb').
    .PARAMETER Target
        Human-readable deploy target (e.g. 'prod (192.168.10.18)').
    .PARAMETER Sections
        [ordered] map of section-name -> ([ordered] map of label -> string|row).
    .PARAMETER Actions
        Ordered list of the concrete steps -Apply will perform.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cmdlet,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Sections,
        [string[]]$Actions = @()
    )
    return [pscustomobject]@{
        Cmdlet   = $Cmdlet
        Target   = $Target
        Sections = $Sections
        Actions  = @($Actions)
    }
}

function Show-DeployPlan {
    <#
    .SYNOPSIS
        Renders a plan object to the screen. Used by BOTH -Plan and -Apply so that the
        preview -Apply confirms against is identical to what -Plan shows.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    Write-Host ""
    Write-Host "  Plan: $($Plan.Cmdlet) -> $($Plan.Target)" -ForegroundColor Cyan

    foreach ($sectionName in $Plan.Sections.Keys) {
        Write-Host ""
        Write-Host "  --- $sectionName ---" -ForegroundColor Cyan
        $rows = $Plan.Sections[$sectionName]
        foreach ($label in $rows.Keys) {
            $row = ConvertTo-DeployPlanRow $rows[$label]
            $color = $script:DeployPlanColors[$row.Level]
            if (-not $color) { $color = 'White' }
            Write-Host ("  {0} {1}" -f ("$($label):").PadRight(12), $row.Text) -ForegroundColor $color
        }
    }

    if ($Plan.Actions.Count -gt 0) {
        Write-Host ""
        Write-Host "  --- Acciones que realizará -Apply ---" -ForegroundColor Cyan
        for ($i = 0; $i -lt $Plan.Actions.Count; $i++) {
            Write-Host ("  {0}. {1}" -f ($i + 1), $Plan.Actions[$i]) -ForegroundColor White
        }
    }
    Write-Host ""
}

function Format-DeployPlanMarkdown {
    <#
    .SYNOPSIS
        Pure renderer: turns a plan object into a markdown change report (no side effects).
    .PARAMETER Timestamp
        Optional ISO-8601 timestamp string to stamp the report (injected for deterministic tests).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Plan,
        [string]$Timestamp = ''
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Deploy plan — $($Plan.Cmdlet)")
    $lines.Add('')
    $lines.Add("- **Target:** $($Plan.Target)")
    if ($Timestamp) { $lines.Add("- **Generated:** $Timestamp") }
    $lines.Add('')

    foreach ($sectionName in $Plan.Sections.Keys) {
        $lines.Add("## $sectionName")
        $lines.Add('')
        $lines.Add('| Campo | Valor |')
        $lines.Add('|---|---|')
        $rows = $Plan.Sections[$sectionName]
        foreach ($label in $rows.Keys) {
            $row = ConvertTo-DeployPlanRow $rows[$label]
            $marker = $script:DeployPlanMarkers[$row.Level]
            $lines.Add("| $label | $marker$($row.Text) |")
        }
        $lines.Add('')
    }

    if ($Plan.Actions.Count -gt 0) {
        $lines.Add('## Acciones que realizará -Apply')
        $lines.Add('')
        for ($i = 0; $i -lt $Plan.Actions.Count; $i++) {
            $lines.Add("$($i + 1). $($Plan.Actions[$i])")
        }
        $lines.Add('')
    }

    return ($lines -join "`n")
}

function Save-DeployPlan {
    <#
    .SYNOPSIS
        Writes the plan as a markdown change report. Used by -Plan only (ADR 0009); -Apply
        renders the same plan on screen but does NOT persist a report.
    .DESCRIPTION
        Default location is a gitignored '.macss/plans/' under the project root; override the
        full path with -OutFile (parity with `terraform plan -out`). Returns the written path.
    .PARAMETER ProjectRoot
        Project root under which '.macss/plans/' is created (ignored when -OutFile is given).
    .PARAMETER OutFile
        Full path override for the report file.
    .PARAMETER Timestamp
        Optional ISO-8601 stamp injected into the report body (tests pass a fixed value).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$OutFile = '',
        [string]$Timestamp = ''
    )

    if (-not $Timestamp) { $Timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK') }
    $stamp = (Get-Date).ToString('yyyyMMddHHmmss')

    if ($OutFile) {
        $path = $OutFile
    }
    else {
        $safeCmdlet = ($Plan.Cmdlet -replace '[^\w.-]', '_')
        $safeTarget = ($Plan.Target -replace '[^\w.-]', '_')
        $fileName = "$safeCmdlet-$safeTarget-$stamp.md"
        $path = Join-Path (Join-Path $ProjectRoot '.macss/plans') $fileName
    }

    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $markdown = Format-DeployPlanMarkdown -Plan $Plan -Timestamp $Timestamp
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $markdown, $utf8NoBom)
    return $path
}
