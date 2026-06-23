function Test-RepoHealth {
    <#
    .SYNOPSIS
    Ejecuta checks de salud sobre un repositorio y retorna un diagnóstico.

    .PARAMETER Name
    Nombre del repositorio a evaluar.

    .PARAMETER Org
    Organización GitHub. Default: cacsi-dev.

    .PARAMETER Fix
    Aplica sugerencias automáticamente (no implementado aún).

    .EXAMPLE
    Test-RepoHealth -Name "gabinete_ui"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [string]$Org = 'cacsi-dev',

        [switch]$Fix
    )

    if ($Fix) {
        throw "Not implemented: -Fix switch is reserved for future auto-remediation."
    }

    $info = Get-RepoInfo -Name $Name -Org $Org
    if (-not $info) {
        Write-Error "Could not retrieve repo info for $Name"
        return
    }

    # Archived repos skip all checks
    if ($info.IsArchived) {
        return [PSCustomObject]@{
            Name         = $info.Name
            HealthStatus = 'archived'
            Checks       = @()
            Actions      = @()
        }
    }

    $checks  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $actions = [System.Collections.Generic.List[string]]::new()

    # Check 1: Valid metadata description
    if ($info.HasMetadata) {
        $checks.Add([PSCustomObject]@{ Check = 'Has valid metadata description'; Status = 'PASS'; Suggestion = $null })
    }
    else {
        $suggestion = "Set repo description to metadata format."
        if ($info.SuggestedDescription) {
            $suggestion = "Suggested: $($info.SuggestedDescription)"
        }
        $checks.Add([PSCustomObject]@{ Check = 'Has valid metadata description'; Status = 'FAIL'; Suggestion = $suggestion })
        $actions.Add("Update description to metadata format: $suggestion")
    }

    # Check 2: publish.yaml exists (acepta el legacy deploy.yaml)
    if ($info.DeployYAMLExists) {
        $checks.Add([PSCustomObject]@{ Check = 'Publish.yaml exists and is valid'; Status = 'PASS'; Suggestion = $null })
    }
    else {
        $checks.Add([PSCustomObject]@{ Check = 'Publish.yaml exists and is valid'; Status = 'FAIL'; Suggestion = 'Create publish.yaml with server/port configuration.' })
        $actions.Add("Create publish.yaml for $Name")
    }

    # Check 3: Workflow file exists
    if ($info.WorkflowExists) {
        $checks.Add([PSCustomObject]@{ Check = 'Workflow file exists'; Status = 'PASS'; Suggestion = $null })
    }
    else {
        $checks.Add([PSCustomObject]@{ Check = 'Workflow file exists'; Status = 'FAIL'; Suggestion = 'Run New-DeployWorkflow to generate the deploy workflow.' })
        $actions.Add("Run New-DeployWorkflow -Name $Name to create workflow")
    }

    # Check 4: Template version is current
    if ($info.WorkflowExists -and $info.TemplateIsCurrent -eq $true) {
        $checks.Add([PSCustomObject]@{ Check = 'Template version is current'; Status = 'PASS'; Suggestion = $null })
    }
    elseif ($info.WorkflowExists) {
        $suggestion = "Current version: $($info.TemplateVersion). Re-run New-DeployWorkflow to update."
        $checks.Add([PSCustomObject]@{ Check = 'Template version is current'; Status = 'FAIL'; Suggestion = $suggestion })
        $actions.Add("Update workflow template: New-DeployWorkflow -Name $Name -Force")
    }
    else {
        $checks.Add([PSCustomObject]@{ Check = 'Template version is current'; Status = 'FAIL'; Suggestion = 'No workflow to check. Create one first.' })
    }

    # Determine HealthStatus
    $failedChecks = @($checks | Where-Object { $_.Status -eq 'FAIL' })

    $healthStatus = if ($failedChecks.Count -eq 0) {
        'healthy'
    }
    elseif ($info.WorkflowExists -and ($failedChecks | Where-Object { $_.Check -eq 'Template version is current' })) {
        'misconfigured'
    }
    elseif (-not $info.HasMetadata) {
        'needs-automation'
    }
    else {
        'needs-automation'
    }

    [PSCustomObject]@{
        Name         = $info.Name
        HealthStatus = $healthStatus
        Checks       = @($checks)
        Actions      = @($actions)
    }
}
