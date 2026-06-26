# ApprovalHelpers.ps1
# Shared confirmation flow for every -Apply path (ADR 0002). Interactive by default,
# explicit -AutoApprove for unattended use, and a clear failure in non-interactive
# shells instead of hanging on Read-Host or applying silently.

function Test-MacssInteractive {
    <#
    .SYNOPSIS
        Returns $true when the current host can prompt the user interactively.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
}

function Confirm-MacssChange {
    <#
    .SYNOPSIS
        Asks for confirmation before applying a change (ADR 0002).
    .DESCRIPTION
        - With -AutoApprove: proceeds without prompting (conscious unattended use).
        - Interactive host: prompts (y/N) and returns the user's choice as a bool.
        - Non-interactive host without -AutoApprove: throws an actionable error
          (never hangs on Read-Host, never applies silently).
    .PARAMETER Action
        Human-readable description of the change to confirm (shown in the prompt/error).
    .PARAMETER AutoApprove
        Skip the prompt and proceed. Intended for CI and other unattended runs.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Action,
        [switch]$AutoApprove
    )

    if ($AutoApprove) {
        Write-Host "  Auto-approved (-AutoApprove): $Action" -ForegroundColor DarkGray
        return $true
    }

    if (-not (Test-MacssInteractive)) {
        throw "Confirmation required to apply: '$Action'. Re-run with -AutoApprove for unattended or non-interactive (CI) use."
    }

    $answer = Read-Host "  Apply this change? ($Action) [y/N]"
    return ($answer -match '^\s*(y|yes)\s*$')
}
