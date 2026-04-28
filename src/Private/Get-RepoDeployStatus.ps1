function Get-RepoDeployStatus {
    <#
    .SYNOPSIS
    Comprueba el estado de deploy de un repo: deploy.yaml + workflow.

    .PARAMETER RepoName
    Nombre del repositorio.

    .PARAMETER Org
    Organización GitHub. Default: cacsi-dev.

    .OUTPUTS
    PSCustomObject con DeployStatus, DeployYAMLExists, WorkflowExists,
    TemplateVersion, TemplateHash, WorkflowContent.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoName,

        [string]$Org = 'cacsi-dev'
    )

    $deployYAMLExists = $false
    $workflowExists   = $false
    $templateVersion  = $null
    $templateHash     = $null
    $workflowContent  = $null

    # Check deploy.yaml
    $null = & gh api "repos/$Org/$RepoName/contents/deploy.yaml" --jq '.sha' 2>&1
    if ($LASTEXITCODE -eq 0) {
        $deployYAMLExists = $true
    }

    # Check workflows
    $wfOutput = & gh api "repos/$Org/$RepoName/contents/.github/workflows" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $workflows = $wfOutput | ConvertFrom-Json -ErrorAction SilentlyContinue
        $deployWf = $workflows | Where-Object { $_.name -match '^deploy' } | Select-Object -First 1
        if ($deployWf) {
            $workflowExists = $true

            # Fetch workflow content for template comparison
            $wfContent = & gh api $deployWf.download_url 2>&1
            if ($LASTEXITCODE -eq 0) {
                $workflowContent = $wfContent -join "`n"
                $templateVersion = Get-TemplateVersion -Content $workflowContent
                $templateHash    = Get-TemplateHash -Content $workflowContent
            }
        }
    }

    # Determine status
    $deployStatus = if ($deployYAMLExists -and $workflowExists) { 'auto' }
                    elseif ($deployYAMLExists -or $workflowExists) { 'partial' }
                    else { 'none' }

    [PSCustomObject]@{
        DeployStatus    = $deployStatus
        DeployYAMLExists = $deployYAMLExists
        WorkflowExists   = $workflowExists
        TemplateVersion  = $templateVersion
        TemplateHash     = $templateHash
        WorkflowContent  = $workflowContent
    }
}
