# ApprovalHelpers.Tests.ps1
# Tests for the shared confirmation helper used by every -Apply path (ADR 0002):
# Confirm-MacssChange and Test-MacssInteractive.

BeforeAll {
    . "$PSScriptRoot/../Private/ApprovalHelpers.ps1"
}

Describe "Confirm-MacssChange" {

    It "returns true and never prompts when -AutoApprove is set" {
        Mock Read-Host { throw "must not prompt when auto-approved" }
        Confirm-MacssChange -Action 'Deploy demo v1 to prod' -AutoApprove | Should -BeTrue
        Should -Invoke Read-Host -Times 0
    }

    It "fails with an actionable error when non-interactive and not auto-approved" {
        Mock Test-MacssInteractive { $false }
        { Confirm-MacssChange -Action 'Deploy demo v1 to prod' } | Should -Throw "*-AutoApprove*"
    }

    It "returns true when interactive and the user answers yes" {
        Mock Test-MacssInteractive { $true }
        Mock Read-Host { 'y' }
        Confirm-MacssChange -Action 'Deploy demo v1 to prod' | Should -BeTrue
    }

    It "returns false when interactive and the user answers no (empty default)" {
        Mock Test-MacssInteractive { $true }
        Mock Read-Host { '' }
        Confirm-MacssChange -Action 'Deploy demo v1 to prod' | Should -BeFalse
    }

    It "treats -AutoApprove as precedence over the interactivity check" {
        Mock Test-MacssInteractive { $false }
        Mock Read-Host { throw "must not prompt when auto-approved" }
        Confirm-MacssChange -Action 'Deploy demo v1 to prod' -AutoApprove | Should -BeTrue
    }
}
