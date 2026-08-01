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

function Get-DeployPlanBlocker {
    <#
    .SYNOPSIS
        Returns the 'error'-level rows of a plan as "Label: Text" strings; empty array if none.
    .DESCRIPTION
        An 'error' row means the plan already knows the apply will fail (e.g. the nginx port is
        taken). -Apply uses this to stop BEFORE doing expensive work instead of building and
        uploading toward a late failure — with -AutoApprove nobody is reading the red line.

        Emits the blockers to the output stream (0..N strings), so callers MUST wrap the call
        in @() to count them: a single blocker arrives as a scalar and none as $null.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)]$Plan)

    $blockers = New-Object System.Collections.Generic.List[string]
    foreach ($sectionName in $Plan.Sections.Keys) {
        $rows = $Plan.Sections[$sectionName]
        foreach ($label in $rows.Keys) {
            $row = ConvertTo-DeployPlanRow $rows[$label]
            if ($row.Level -eq 'error') { $blockers.Add("$($label): $($row.Text)") }
        }
    }
    return $blockers.ToArray()
}

function ConvertTo-DeployPlanCell {
    <#
    .SYNOPSIS
        Escapes a value so it cannot break out of a markdown table cell.
    .DESCRIPTION
        A raw '|' would be read as a column separator (turning a 2-column row into 3+), and a
        newline would end the row. Matters for cmdlets whose plan values are less tame than
        Flutter Web's (SQL object names, connection strings) as ADR 0009 rolls out.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    return (($Text -replace '\|', '\|') -replace '\r?\n', ' ')
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
            $cell = ConvertTo-DeployPlanCell -Text "$marker$($row.Text)"
            $lines.Add("| $(ConvertTo-DeployPlanCell -Text $label) | $cell |")
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
        Optional ISO-8601 stamp injected into the report body (tests pass a fixed value). It also
        drives the generated file name, so injecting it makes the whole call deterministic.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$OutFile = '',
        [string]$Timestamp = ''
    )

    # The file name stamp is derived from $Timestamp (not a second Get-Date) so that an injected
    # timestamp pins the name too; otherwise a "deterministic" call still produced a random name.
    if ($Timestamp) {
        try {
            $stampSource = [datetime]::Parse(
                $Timestamp,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind)
        }
        catch { $stampSource = Get-Date }
    }
    else {
        $stampSource = Get-Date
        $Timestamp = $stampSource.ToString('yyyy-MM-ddTHH:mm:ssK')
    }
    $stamp = $stampSource.ToString('yyyyMMddHHmmss')

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    if ($OutFile) {
        $path = $OutFile
    }
    else {
        $safeCmdlet = ($Plan.Cmdlet -replace '[^\w.-]', '_')
        $safeTarget = ($Plan.Target -replace '[^\w.-]', '_')
        $fileName = "$safeCmdlet-$safeTarget-$stamp.md"
        $path = Join-Path (Join-Path $ProjectRoot '.macss/plans') $fileName

        # The report embeds the target alias and IP. Make '.macss/' self-ignoring (the
        # '.terraform/' pattern) so a consumer project cannot leak it by forgetting a
        # .gitignore entry — ADR 0009 asked consumers to add one by hand.
        $macssRoot = Join-Path $ProjectRoot '.macss'
        $macssIgnore = Join-Path $macssRoot '.gitignore'
        if (-not (Test-Path $macssIgnore)) {
            New-Item -ItemType Directory -Path $macssRoot -Force | Out-Null
            [System.IO.File]::WriteAllText($macssIgnore, "*`n", $utf8NoBom)
        }
    }

    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $markdown = Format-DeployPlanMarkdown -Plan $Plan -Timestamp $Timestamp
    [System.IO.File]::WriteAllText($path, $markdown, $utf8NoBom)
    return $path
}
