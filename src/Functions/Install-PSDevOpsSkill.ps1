function Install-PSDevOpsSkill {
    <#
    .SYNOPSIS
    Installs PSDevOps SKILL.md as a VS Code prompt file for AI assistant consumption.

    .DESCRIPTION
    Copies SKILL.md from the PSDevOps module directory to the VS Code user prompts folder
    as psdevops.md, making it available as context for GitHub Copilot and other AI assistants.

    .PARAMETER Destination
    Override the default VS Code prompts folder. Defaults to:
    $env:APPDATA\Code\User\prompts

    .EXAMPLE
    Install-PSDevOpsSkill

    .EXAMPLE
    Install-PSDevOpsSkill -Destination C:\MyCustomPath\prompts
    #>
    [CmdletBinding()]
    param(
        [string]$Destination
    )

    $skillSource = Join-Path $PSScriptRoot '..\..' 'SKILL.md'
    $skillSource = (Resolve-Path $skillSource).Path

    if (-not (Test-Path $skillSource)) {
        Write-Error "SKILL.md not found at '$skillSource'."
        return [PSCustomObject]@{ Success = $false; Message = "SKILL.md not found." }
    }

    if (-not $Destination) {
        $Destination = Join-Path $env:APPDATA 'Code\User\prompts'
    }

    if (-not (Test-Path $Destination)) {
        New-Item -Path $Destination -ItemType Directory -Force | Out-Null
    }

    $target = Join-Path $Destination 'psdevops.md'
    Copy-Item -Path $skillSource -Destination $target -Force

    [PSCustomObject]@{
        Success     = $true
        Source      = $skillSource
        Destination = $target
        Message     = "SKILL.md installed to $target"
    }
}
