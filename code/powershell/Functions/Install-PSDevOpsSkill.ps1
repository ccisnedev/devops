function Install-PSDevOpsSkill {
    <#
    .SYNOPSIS
    Installs the bundled SKILL.md as a VS Code prompt file for AI assistant consumption.

    .DESCRIPTION
    Copies SKILL.md from the module directory to the VS Code user prompts folder
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

    $skillCandidates = @(
        (Join-Path $PSScriptRoot '..\SKILL.md'),
        (Join-Path $PSScriptRoot '..\..\skills\SKILL.md')
    )

    $skillSource = $skillCandidates |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1

    if (-not $skillSource) {
        Write-Error "SKILL.md not found. Checked: $($skillCandidates -join ', ')."
        return [PSCustomObject]@{ Success = $false; Message = "SKILL.md not found." }
    }

    $skillSource = (Resolve-Path $skillSource).Path

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
