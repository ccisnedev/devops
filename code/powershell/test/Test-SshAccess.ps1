# Test-SshAccess.ps1
# Tests for New-SshAccess / Remove-SshAccess (unit + pure-logic; no network).
# Run from the module: .\test\Test-SshAccess.ps1

$ErrorActionPreference = 'Stop'
$ModuleRoot = Split-Path -Parent $PSScriptRoot
$passed = 0; $failed = 0; $skipped = 0

function Write-TestHeader($t) { Write-Host ""; Write-Host "  $t" -ForegroundColor Cyan }
function Assert-True($c, $m) {
    if ($c) { Write-Host "    PASS: $m" -ForegroundColor Green; $script:passed++ }
    else    { Write-Host "    FAIL: $m" -ForegroundColor Red;   $script:failed++ }
}
function Assert-Throws($sb, $m) {
    $threw = $false
    try { & $sb } catch { $threw = $true }
    if ($threw) { Write-Host "    PASS: $m" -ForegroundColor Green; $script:passed++ }
    else        { Write-Host "    FAIL: $m (no exception)" -ForegroundColor Red; $script:failed++ }
}

Write-Host ""
Write-Host "  TEST: New-SshAccess / Remove-SshAccess" -ForegroundColor Cyan

# ── Setup ───────────────────────────────────────────────────────────
Write-TestHeader "Setup: load module"
Remove-Module 'macss-devops' -ErrorAction SilentlyContinue
Import-Module "$ModuleRoot\macss-devops.psd1" -Force
Assert-True ($null -ne (Get-Command New-SshAccess -ErrorAction SilentlyContinue)) "New-SshAccess is available"
Assert-True ($null -ne (Get-Command Remove-SshAccess -ErrorAction SilentlyContinue)) "Remove-SshAccess is available"

# ── 1. Parameters ───────────────────────────────────────────────────
Write-TestHeader "1. Cmdlet parameters"
$np = (Get-Command New-SshAccess).Parameters
foreach ($p in 'Server','HostName','User','Port','BootstrapUser','Sudo','KeyType','KeyPath','Force') {
    Assert-True ($np.ContainsKey($p)) "New-SshAccess has -$p"
}
$rp = (Get-Command Remove-SshAccess).Parameters
foreach ($p in 'Server','HostName','User','PublicKey','Fingerprint','BootstrapUser','Sudo','RemoveLocal','Force') {
    Assert-True ($rp.ContainsKey($p)) "Remove-SshAccess has -$p"
}

# ── 2. Pure helpers (config block) ──────────────────────────────────
Write-TestHeader "2. SshHelpers: config entry / add / remove"
. "$ModuleRoot\Private\SshHelpers.ps1"

Assert-True ((Get-Command Invoke-RemoteBash).Parameters.ContainsKey('Tty')) "Invoke-RemoteBash supports -Tty (sudo over ssh needs a pseudo-tty)"

$entry = New-SshConfigEntry -Alias 'h1' -HostName '10.0.0.1' -User 'svc' -Port 22 -IdentityFile '/k/h1'
Assert-True ($entry -match '(?m)^Host h1$') "config entry has 'Host h1'"
Assert-True ($entry -match 'IdentityFile /k/h1') "config entry has IdentityFile"
Assert-True ($entry -match 'IdentitiesOnly yes') "config entry pins IdentitiesOnly"

$cfg = Join-Path $env:TEMP "macss_sshcfg_$([guid]::NewGuid().ToString().Substring(0,8))"
try {
    $r1 = Add-SshConfigHost -ConfigPath $cfg -Alias 'h1' -HostName '10.0.0.1' -User 'svc' -IdentityFile '/k/h1'
    Assert-True ($r1.Action -eq 'created') "first Add creates the config"
    $r2 = Add-SshConfigHost -ConfigPath $cfg -Alias 'h2' -HostName '10.0.0.2' -User 'svc' -IdentityFile '/k/h2'
    Assert-True ($r2.Action -eq 'appended') "second alias is appended"
    Assert-Throws { Add-SshConfigHost -ConfigPath $cfg -Alias 'h1' -HostName 'x' -User 'y' -IdentityFile '/k/x' } "Add without -Force throws on existing alias"
    $r3 = Add-SshConfigHost -ConfigPath $cfg -Alias 'h1' -HostName '10.0.0.9' -User 'svc' -IdentityFile '/k/h1' -Force
    Assert-True ($r3.Action -eq 'replaced') "Add with -Force replaces the alias"
    Assert-True ((Get-Content $cfg -Raw) -match 'HostName 10.0.0.9') "replaced block has the new HostName"
    Assert-True ((Get-Content $cfg -Raw) -match '(?m)^Host h2$') "other alias survives the replace"
    $removed = Remove-SshConfigHost -ConfigPath $cfg -Alias 'h1'
    Assert-True ($removed -and ((Get-Content $cfg -Raw) -notmatch '(?m)^Host h1$')) "Remove deletes the alias block"
    Assert-True ((Get-Content $cfg -Raw) -match '(?m)^Host h2$') "Remove keeps the other alias"
} finally {
    Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
}

# ── 3. Public key blob extraction ───────────────────────────────────
Write-TestHeader "3. Get-SshPublicKeyBlob"
$blob = Get-SshPublicKeyBlob -PublicKey 'ssh-ed25519 AAAAC3Nz_blob_xyz comment@host'
Assert-True ($blob -eq 'AAAAC3Nz_blob_xyz') "extracts the base64 blob (2nd field)"

# ── 4. Key generation (guarded on ssh-keygen) ───────────────────────
Write-TestHeader "4. New-SshKeyPair (requires ssh-keygen)"
if (Get-Command ssh-keygen -ErrorAction SilentlyContinue) {
    $kp = Join-Path $env:TEMP "macss_key_$([guid]::NewGuid().ToString().Substring(0,8))"
    try {
        $k = New-SshKeyPair -Path $kp -Comment 'unit-test'
        Assert-True (Test-Path $kp) "private key created"
        Assert-True (Test-Path "$kp.pub") "public key created"
        Assert-True ($k.Fingerprint -match '^SHA256:') "fingerprint looks like SHA256:"
        Assert-True ($k.PublicKey -match '^ssh-ed25519 ') "public key is ed25519"
    } finally {
        Remove-Item -LiteralPath $kp, "$kp.pub" -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "    SKIP: ssh-keygen not found" -ForegroundColor Yellow; $script:skipped++
}

# ── 5. Remove-SshAccess argument validation (throws before any network) ──
Write-TestHeader "5. Remove-SshAccess validation"
Assert-Throws { Remove-SshAccess -PublicKey 'ssh-ed25519 AAA c' } "throws without a target (-Server or -HostName/-User)"
Assert-Throws { Remove-SshAccess -HostName 'h' -User 'u' } "throws without -PublicKey or -Fingerprint"
Assert-Throws { Remove-SshAccess -HostName 'h' -User 'u' -PublicKey 'ssh-ed25519 AAA c' -Fingerprint 'SHA256:x' } "throws when both -PublicKey and -Fingerprint given"

# ── 6. Remote scripts content ───────────────────────────────────────
Write-TestHeader "6. Bash scripts"
$scriptsDir = Join-Path $ModuleRoot 'Private\scripts'
$install = Get-Content (Join-Path $scriptsDir 'Install-AuthorizedKey.sh') -Raw
Assert-True ($install -match 'authorized_keys') "Install-AuthorizedKey.sh edits authorized_keys"
Assert-True ($install -match 'grep -qF') "Install-AuthorizedKey.sh is idempotent (grep -qF)"
Assert-True ($install -match '__TARGET_USER__' -and $install -match '__USE_SUDO__') "Install-AuthorizedKey.sh has placeholders"
$remove = Get-Content (Join-Path $scriptsDir 'Remove-AuthorizedKey.sh') -Raw
Assert-True ($remove -match '\.bak\.') "Remove-AuthorizedKey.sh backs up authorized_keys"
Assert-True ($remove -match 'would leave 0 authorized keys') "Remove-AuthorizedKey.sh has a lockout guard"
Assert-True ($remove -match 'ssh-keygen -lf -' ) "Remove-AuthorizedKey.sh supports fingerprint match"
Assert-True ($remove -match 'mv ') "Remove-AuthorizedKey.sh writes atomically (mv)"

# ── Summary ─────────────────────────────────────────────────────────
Write-Host ""
$total = $passed + $failed + $skipped
Write-Host "  Total: $total  Passed: $passed  Failed: $failed  Skipped: $skipped" -ForegroundColor White
if ($failed -gt 0) { Write-Host "  RESULT: FAIL" -ForegroundColor Red; exit 1 }
Write-Host "  RESULT: PASS" -ForegroundColor Green; exit 0
