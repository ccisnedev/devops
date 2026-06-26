#!/usr/bin/env bash
# Behavioral container test for the ADR 0002 confirmation guard (Confirm-MacssChange).
# Runs in a REAL non-interactive PowerShell container (the CI scenario the guard must
# handle): without -AutoApprove it must FAIL clearly; with -AutoApprove it must proceed.
# This exercises the real Test-MacssInteractive detection (the Pester tests mock it).
#
# Usage: bash Confirm-MacssChange.container.test.sh <path-to-Private-dir>
set -euo pipefail

HELPER_DIR="${1:?usage: $0 <path-to-Private-dir>}"
IMAGE="${PWSH_IMAGE:-mcr.microsoft.com/powershell:latest}"

echo "=== Running Confirm-MacssChange in a non-interactive pwsh container ==="
docker run --rm -v "${HELPER_DIR}:/p:ro" "$IMAGE" pwsh -NoProfile -Command '
  . /p/ApprovalHelpers.ps1
  $fail = 0
  Write-Host ("Test-MacssInteractive -> " + (Test-MacssInteractive))

  # 1) Non-interactive + no -AutoApprove must throw an actionable error (not hang, not proceed).
  try {
    Confirm-MacssChange -Action "deploy demo" | Out-Null
    Write-Host "FAIL: did not throw without -AutoApprove"; $fail = 1
  } catch {
    if ("$_" -match "AutoApprove") { Write-Host "PASS: non-interactive guard threw actionable error" }
    else { Write-Host "FAIL: threw the wrong error -> $_"; $fail = 1 }
  }

  # 2) -AutoApprove must proceed (return $true) with no prompt.
  if ((Confirm-MacssChange -Action "deploy demo" -AutoApprove) -eq $true) {
    Write-Host "PASS: -AutoApprove proceeds without prompting"
  } else { Write-Host "FAIL: -AutoApprove did not return true"; $fail = 1 }

  if ($fail -ne 0) { exit 1 }
  Write-Host "ALL CONTAINER APPROVAL TESTS PASSED"
'
