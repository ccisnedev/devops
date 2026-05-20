# Test-PublishNodeApi.ps1
# Test del cmdlet Publish-NodeApi usando TDD
# Ejecutar desde la raíz del módulo: .\test\Test-PublishNodeApi.ps1

param(
    [switch]$SkipDeploy  # Solo ejecutar tests unitarios (sin servidor real)
)

$ErrorActionPreference = 'Stop'

# ─── Setup ──────────────────────────────────────────────────────────
$ModuleRoot = Split-Path -Parent $PSScriptRoot
$passed = 0
$failed = 0
$skipped = 0

function Write-TestHeader($text) {
    Write-Host ""
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host "  $('─' * ($text.Length))" -ForegroundColor DarkGray
}

function Assert-True($condition, $message) {
    if ($condition) {
        Write-Host "    PASS: $message" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "    FAIL: $message" -ForegroundColor Red
        $script:failed++
    }
}

function Assert-Equal($expected, $actual, $message) {
    if ($expected -eq $actual) {
        Write-Host "    PASS: $message" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "    FAIL: $message (expected='$expected', actual='$actual')" -ForegroundColor Red
        $script:failed++
    }
}

function Assert-Throws($scriptBlock, $message) {
    $threw = $false
    try { & $scriptBlock } catch { $threw = $true }
    if ($threw) {
        Write-Host "    PASS: $message" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "    FAIL: $message (no lanzó excepción)" -ForegroundColor Red
        $script:failed++
    }
}

function Assert-FileContains($filePath, $pattern, $message) {
    $content = Get-Content $filePath -Raw
    if ($content -match $pattern) {
        Write-Host "    PASS: $message" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "    FAIL: $message (patrón '$pattern' no encontrado en $filePath)" -ForegroundColor Red
        $script:failed++
    }
}

# ─── Banner ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║        TEST: Publish-NodeApi — PSDevOps                  ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ─── Cargar módulo ──────────────────────────────────────────────────
Write-TestHeader "Setup: Cargar módulo"
Remove-Module 'macss-devops' -ErrorAction SilentlyContinue
Import-Module "$ModuleRoot\..\macss-devops.psd1" -Force
$cmd = Get-Command Publish-NodeApi -ErrorAction SilentlyContinue
Assert-True ($null -ne $cmd) "Cmdlet Publish-NodeApi está disponible"

# ════════════════════════════════════════════════════════════════════
# TEST GROUP 1: Cmdlet metadata y parámetros
# ════════════════════════════════════════════════════════════════════
Write-TestHeader "1. Metadata del cmdlet"

$params = (Get-Command Publish-NodeApi).Parameters

Assert-True ($params.ContainsKey('Init')) "Parámetro -Init existe"
Assert-True ($params.ContainsKey('Publish')) "Parámetro -Publish existe"

# Verificar ParameterSets
$paramSets = (Get-Command Publish-NodeApi).ParameterSets
$setNames = $paramSets | ForEach-Object { $_.Name }
Assert-True ($setNames -contains 'Init') "ParameterSet 'Init' existe"
Assert-True ($setNames -contains 'Publish') "ParameterSet 'Publish' existe"

# ════════════════════════════════════════════════════════════════════
# TEST GROUP 2: -Init en proyecto TypeScript válido
# ════════════════════════════════════════════════════════════════════
Write-TestHeader "2. -Init genera deploy.yaml en proyecto TypeScript"

# Crear proyecto de prueba temporal
$testProject = Join-Path $env:TEMP "psdevops_test_nodeapi_$([guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $testProject -Force | Out-Null

# Crear package.json de prueba
$packageJson = @{
    name = "test_api"
    version = "1.2.3"
    main = "dist/main.js"
    scripts = @{ build = "tsc"; start = "node dist/main.js" }
} | ConvertTo-Json
Set-Content -Path (Join-Path $testProject "package.json") -Value $packageJson -Encoding UTF8

# Crear tsconfig.json de prueba
$tsconfig = @{ compilerOptions = @{ outDir = "./dist"; rootDir = "./src" } } | ConvertTo-Json
Set-Content -Path (Join-Path $testProject "tsconfig.json") -Value $tsconfig -Encoding UTF8

try {
    Push-Location $testProject

    # Ejecutar -Init
    Publish-NodeApi -Init

    # Verificar que deploy.yaml se creó
    $deployYaml = Join-Path $testProject "deploy.yaml"
    Assert-True (Test-Path $deployYaml) "deploy.yaml fue creado"
    Assert-FileContains $deployYaml "server:" "deploy.yaml contiene 'server:'"
    Assert-FileContains $deployYaml "processManager:" "deploy.yaml contiene 'processManager:'"
    Assert-FileContains $deployYaml "systemd" "deploy.yaml tiene systemd como default"
    Assert-FileContains $deployYaml "retries:" "deploy.yaml contiene health retries"

    # Verificar que deploy.yaml NO contiene name ni version (se leen de package.json)
    $deployContent = Get-Content $deployYaml -Raw
    $yamlParsed = $deployContent | ConvertFrom-Yaml
    Assert-True ($null -eq $yamlParsed.name) "deploy.yaml NO contiene campo 'name'"
    Assert-True ($null -eq $yamlParsed.version) "deploy.yaml NO contiene campo 'version'"

    # Verificar que .env.production se creó
    $envProd = Join-Path $testProject ".env.production"
    Assert-True (Test-Path $envProd) ".env.production fue creado"
    Assert-FileContains $envProd "PORT=" ".env.production contiene PORT"
    Assert-FileContains $envProd "NODE_ENV=" ".env.production contiene NODE_ENV"

    # Verificar que .gitignore tiene .env.production
    $gitignore = Join-Path $testProject ".gitignore"
    if (Test-Path $gitignore) {
        Assert-FileContains $gitignore "\.env\.production" ".gitignore contiene .env.production"
    }

} finally {
    Pop-Location
    Remove-Item -Path $testProject -Recurse -Force -ErrorAction SilentlyContinue
}

# ════════════════════════════════════════════════════════════════════
# TEST GROUP 3: -Init falla sin package.json
# ════════════════════════════════════════════════════════════════════
Write-TestHeader "3. -Init falla sin package.json"

$testEmpty = Join-Path $env:TEMP "psdevops_test_empty_$([guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $testEmpty -Force | Out-Null

try {
    Push-Location $testEmpty
    Assert-Throws { Publish-NodeApi -Init } "-Init lanza error sin package.json"
} finally {
    Pop-Location
    Remove-Item -Path $testEmpty -Recurse -Force -ErrorAction SilentlyContinue
}

# ════════════════════════════════════════════════════════════════════
# TEST GROUP 4: -Init falla sin tsconfig.json
# ════════════════════════════════════════════════════════════════════
Write-TestHeader "4. -Init falla sin tsconfig.json"

$testNoTs = Join-Path $env:TEMP "psdevops_test_nots_$([guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $testNoTs -Force | Out-Null
Set-Content -Path (Join-Path $testNoTs "package.json") -Value '{"name":"x","version":"1.0.0"}' -Encoding UTF8

try {
    Push-Location $testNoTs
    Assert-Throws { Publish-NodeApi -Init } "-Init lanza error sin tsconfig.json"
} finally {
    Pop-Location
    Remove-Item -Path $testNoTs -Recurse -Force -ErrorAction SilentlyContinue
}

# ════════════════════════════════════════════════════════════════════
# TEST GROUP 5: -Init no sobrescribe deploy.yaml existente
# ════════════════════════════════════════════════════════════════════
Write-TestHeader "5. -Init no sobrescribe deploy.yaml existente"

$testExisting = Join-Path $env:TEMP "psdevops_test_existing_$([guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $testExisting -Force | Out-Null
Set-Content -Path (Join-Path $testExisting "package.json") -Value '{"name":"existing_api","version":"2.0.0"}' -Encoding UTF8
Set-Content -Path (Join-Path $testExisting "tsconfig.json") -Value '{}' -Encoding UTF8
Set-Content -Path (Join-Path $testExisting "deploy.yaml") -Value "server: my-real-server" -Encoding UTF8

try {
    Push-Location $testExisting
    Assert-Throws { Publish-NodeApi -Init } "-Init lanza error si deploy.yaml ya existe"
} finally {
    Pop-Location
    Remove-Item -Path $testExisting -Recurse -Force -ErrorAction SilentlyContinue
}

# ════════════════════════════════════════════════════════════════════
# TEST GROUP 6: -Publish falla sin deploy.yaml
# ════════════════════════════════════════════════════════════════════
Write-TestHeader "6. -Publish falla sin deploy.yaml"

$testNoDeploy = Join-Path $env:TEMP "psdevops_test_nodeploy_$([guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $testNoDeploy -Force | Out-Null
Set-Content -Path (Join-Path $testNoDeploy "package.json") -Value '{"name":"x","version":"1.0.0"}' -Encoding UTF8

try {
    Push-Location $testNoDeploy
    Assert-Throws { Publish-NodeApi -Publish } "-Publish lanza error sin deploy.yaml"
} finally {
    Pop-Location
    Remove-Item -Path $testNoDeploy -Recurse -Force -ErrorAction SilentlyContinue
}

# ════════════════════════════════════════════════════════════════════
# TEST GROUP 7: -Publish falla sin .env.production
# ════════════════════════════════════════════════════════════════════
Write-TestHeader "7. -Publish falla sin .env.production"

$testNoEnv = Join-Path $env:TEMP "psdevops_test_noenv_$([guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $testNoEnv -Force | Out-Null
Set-Content -Path (Join-Path $testNoEnv "package.json") -Value '{"name":"x","version":"1.0.0"}' -Encoding UTF8
Set-Content -Path (Join-Path $testNoEnv "tsconfig.json") -Value '{}' -Encoding UTF8
Set-Content -Path (Join-Path $testNoEnv "deploy.yaml") -Value "server: web-server" -Encoding UTF8

try {
    Push-Location $testNoEnv
    Assert-Throws { Publish-NodeApi -Publish } "-Publish lanza error sin .env.production"
} finally {
    Pop-Location
    Remove-Item -Path $testNoEnv -Recurse -Force -ErrorAction SilentlyContinue
}

# ════════════════════════════════════════════════════════════════════
# TEST GROUP 8: -Publish valida server no sea valor de ejemplo
# ════════════════════════════════════════════════════════════════════
Write-TestHeader "8. -Publish valida que server no sea el valor de ejemplo"

$testExample = Join-Path $env:TEMP "psdevops_test_example_$([guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $testExample -Force | Out-Null
Set-Content -Path (Join-Path $testExample "package.json") -Value '{"name":"x","version":"1.0.0"}' -Encoding UTF8
Set-Content -Path (Join-Path $testExample "tsconfig.json") -Value '{}' -Encoding UTF8
Set-Content -Path (Join-Path $testExample "deploy.yaml") -Value "server: your-ssh-alias" -Encoding UTF8
Set-Content -Path (Join-Path $testExample ".env.production") -Value "PORT=8080`nNODE_ENV=production" -Encoding UTF8

try {
    Push-Location $testExample
    Assert-Throws { Publish-NodeApi -Publish } "-Publish lanza error con server de ejemplo 'your-ssh-alias'"
} finally {
    Pop-Location
    Remove-Item -Path $testExample -Recurse -Force -ErrorAction SilentlyContinue
}

# ════════════════════════════════════════════════════════════════════
# TEST GROUP 9: Archivos de infraestructura existen
# ════════════════════════════════════════════════════════════════════
Write-TestHeader "9. Archivos de infraestructura del cmdlet"

$scriptsDir = Join-Path $ModuleRoot "Private\scripts"
$templateDir = Join-Path $ModuleRoot "Resources\Publish-NodeApi\templates"

Assert-True (Test-Path (Join-Path $scriptsDir "Install-NodeApi.sh")) "Install-NodeApi.sh existe"
Assert-True (Test-Path (Join-Path $scriptsDir "Manage-NodeProcess.sh")) "Manage-NodeProcess.sh existe"
Assert-True (Test-Path (Join-Path $templateDir "deploy.yaml")) "Template deploy.yaml existe"

# Verificar contenido de los scripts bash
$installSh = Get-Content (Join-Path $scriptsDir "Install-NodeApi.sh") -Raw
Assert-True ($installSh -match '__NAME__') "Install-NodeApi.sh tiene placeholder __NAME__"
Assert-True ($installSh -match '__VERSION__') "Install-NodeApi.sh tiene placeholder __VERSION__"
Assert-True ($installSh -match 'NVM_DIR') "Install-NodeApi.sh carga nvm"
Assert-True ($installSh -match 'dist/main\.js') "Install-NodeApi.sh verifica dist/main.js"
Assert-True ($installSh -match 'ln -sfn') "Install-NodeApi.sh crea symlink"

$manageSh = Get-Content (Join-Path $scriptsDir "Manage-NodeProcess.sh") -Raw
Assert-True ($manageSh -match '__PROCESS_MANAGER__') "Manage-NodeProcess.sh tiene placeholder __PROCESS_MANAGER__"
Assert-True ($manageSh -match 'systemctl') "Manage-NodeProcess.sh soporta systemd"
Assert-True ($manageSh -match 'pm2') "Manage-NodeProcess.sh soporta pm2"

# ════════════════════════════════════════════════════════════════════
# TEST GROUP 10: Deploy e2e (requiere servidor real)
# ════════════════════════════════════════════════════════════════════
if ($SkipDeploy) {
    Write-TestHeader "10. Deploy e2e (SKIPPED — usar sin -SkipDeploy)"
    $skipped++
} else {
    Write-TestHeader "10. Deploy e2e (requiere servidor real y proyecto Node.js)"
    Write-Host "    Skipped: deploy e2e requiere entorno configurado" -ForegroundColor Yellow
    $skipped++
}

# ════════════════════════════════════════════════════════════════════
# TEST GROUP 11: New-UnixTempFile normaliza CRLF en contenido .env
# ────────────────────────────────────────────────────────────────────
# Propósito: Verificar que New-UnixTempFile normaliza CRLF → LF en
#            contenido tipo .env (variables de entorno para producción).
# Precondición: PublishHelpers.ps1 cargado (New-UnixTempFile disponible).
# Resultado esperado: archivo temporal sin \r, contenido preservado.
# ════════════════════════════════════════════════════════════════════
Write-TestHeader "11. New-UnixTempFile normaliza CRLF en contenido .env"

# Cargar helper directamente (función privada, no exportada por el módulo)
. "$ModuleRoot\Private\PublishHelpers.ps1"

# 12a. Contenido .env con CRLF → archivo resultante solo tiene LF
$envCRLF = "PORT=8080`r`nNODE_ENV=production`r`nDB_HOST=localhost`r`n"
$tmpEnvPath = New-UnixTempFile -Content $envCRLF -Prefix "test_env_"

try {
    Assert-True (Test-Path $tmpEnvPath) "12a: Archivo temporal fue creado"

    $rawBytes = [System.IO.File]::ReadAllBytes($tmpEnvPath)
    $hasCR = $rawBytes -contains 0x0D
    Assert-True (-not $hasCR) "12a: Archivo no contiene bytes CR (0x0D)"

    # 12b. Variables y valores se preservan intactos tras normalización
    $normalizedContent = [System.IO.File]::ReadAllText($tmpEnvPath)
    Assert-True ($normalizedContent -match 'PORT=8080') "12b: PORT=8080 preservado"
    Assert-True ($normalizedContent -match 'NODE_ENV=production') "12b: NODE_ENV=production preservado"
    Assert-True ($normalizedContent -match 'DB_HOST=localhost') "12b: DB_HOST=localhost preservado"

    # 12c. Comentarios y líneas vacías se preservan
    $envWithComments = "# Variables de producción`r`n`r`nKEY=value`r`n# Fin`r`n"
    $tmpEnvPath2 = New-UnixTempFile -Content $envWithComments -Prefix "test_env_comments_"
    $normalized2 = [System.IO.File]::ReadAllText($tmpEnvPath2)
    $rawBytes2 = [System.IO.File]::ReadAllBytes($tmpEnvPath2)
    $hasCR2 = $rawBytes2 -contains 0x0D

    Assert-True (-not $hasCR2) "12c: Archivo con comentarios no contiene CR"
    Assert-True ($normalized2 -match '# Variables de producción') "12c: Comentario preservado"
    Assert-True ($normalized2 -match 'KEY=value') "12c: Variable preservada tras línea vacía"

    Remove-Item -LiteralPath $tmpEnvPath2 -ErrorAction SilentlyContinue
} finally {
    Remove-Item -LiteralPath $tmpEnvPath -ErrorAction SilentlyContinue
}

# ════════════════════════════════════════════════════════════════════
# TEST GROUP 12: Publish-NodeApi normaliza .env.production antes del SCP
# ────────────────────────────────────────────────────────────────────
# Propósito: Verificar que el código fuente de Publish-NodeApi.ps1
#            crea una copia temporal LF del .env.production antes del SCP.
# Precondición: Publish-NodeApi.ps1 existe en Functions/.
# Resultado esperado: el source usa New-UnixTempFile para .env y sube
#                     la copia temporal ($tmpEnvPath), no el original.
# ════════════════════════════════════════════════════════════════════
Write-TestHeader "12. Publish-NodeApi normaliza .env.production antes del SCP"

$publishSource = Get-Content "$ModuleRoot\Functions\Publish-NodeApi.ps1" -Raw

# 12a. El source llama a New-UnixTempFile para el contenido de .env.production
Assert-True ($publishSource -match 'New-UnixTempFile.*-Content.*\$envProdPath|New-UnixTempFile.*envContent|New-UnixTempFile.*env') "12a: Source usa New-UnixTempFile para .env.production"

# 12b. El SCP de .env usa la variable temporal, no $envProdPath directamente
#      Búsqueda: la línea de scpEnvArgs debe contener $tmpEnvPath (temporal), no $envProdPath
Assert-True ($publishSource -match 'scpEnvArgs.*\$tmpEnvPath') "12b: SCP usa \$tmpEnvPath (temporal) en vez de \$envProdPath"

# 12c. El bloque finally limpia $tmpEnvPath (archivo temporal del .env)
Assert-True ($publishSource -match 'finally[\s\S]*Remove-Item.*\$tmpEnvPath') "12c: finally limpia \$tmpEnvPath"

# ════════════════════════════════════════════════════════════════════
# TEST GROUP 13: -DeployReport ParameterSet y validaciones
# ════════════════════════════════════════════════════════════════════
Write-TestHeader "13. -DeployReport metadata y validaciones"

# ParameterSet existe
$setNames = (Get-Command Publish-NodeApi).ParameterSets | ForEach-Object { $_.Name }
Assert-True ($setNames -contains 'DeployReport') "ParameterSet 'DeployReport' existe"

# Parámetro existe
$params = (Get-Command Publish-NodeApi).Parameters
Assert-True ($params.ContainsKey('DeployReport')) "Parámetro -DeployReport existe"

# DefaultParameterSetName sigue siendo Publish
$defaultSet = (Get-Command Publish-NodeApi).DefaultParameterSet
Assert-True ($defaultSet -eq 'Publish') "DefaultParameterSetName sigue siendo 'Publish'"

# Falla sin package.json
$testDrNoPackage = Join-Path $env:TEMP "psdevops_test_dr_nopkg_$([guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $testDrNoPackage -Force | Out-Null
Set-Content -Path (Join-Path $testDrNoPackage "deploy.yaml") -Value "server: test`nport: 8080" -Encoding UTF8
Set-Content -Path (Join-Path $testDrNoPackage ".env.production") -Value "PORT=8080" -Encoding UTF8
try {
    Push-Location $testDrNoPackage
    Assert-Throws { Publish-NodeApi -DeployReport } "-DeployReport falla sin package.json"
} finally {
    Pop-Location
    Remove-Item -Path $testDrNoPackage -Recurse -Force -ErrorAction SilentlyContinue
}

# Falla sin deploy.yaml
$testDrNoDeploy = Join-Path $env:TEMP "psdevops_test_dr_nodeploy_$([guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $testDrNoDeploy -Force | Out-Null
Set-Content -Path (Join-Path $testDrNoDeploy "package.json") -Value '{"name":"x","version":"1.0.0"}' -Encoding UTF8
Set-Content -Path (Join-Path $testDrNoDeploy ".env.production") -Value "PORT=8080" -Encoding UTF8
try {
    Push-Location $testDrNoDeploy
    Assert-Throws { Publish-NodeApi -DeployReport } "-DeployReport falla sin deploy.yaml"
} finally {
    Pop-Location
    Remove-Item -Path $testDrNoDeploy -Recurse -Force -ErrorAction SilentlyContinue
}

# Falla con placeholder server
$testDrPlaceholder = Join-Path $env:TEMP "psdevops_test_dr_ph_$([guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $testDrPlaceholder -Force | Out-Null
Set-Content -Path (Join-Path $testDrPlaceholder "package.json") -Value '{"name":"x","version":"1.0.0"}' -Encoding UTF8
Set-Content -Path (Join-Path $testDrPlaceholder "deploy.yaml") -Value "server: your-ssh-alias`nport: 8080" -Encoding UTF8
Set-Content -Path (Join-Path $testDrPlaceholder ".env.production") -Value "PORT=8080" -Encoding UTF8
try {
    Push-Location $testDrPlaceholder
    Assert-Throws { Publish-NodeApi -DeployReport } "-DeployReport falla con server placeholder"
} finally {
    Pop-Location
    Remove-Item -Path $testDrPlaceholder -Recurse -Force -ErrorAction SilentlyContinue
}

# No compila (falla en SSH, no en build)
$testDrNoBuild = Join-Path $env:TEMP "psdevops_test_dr_nobuild_$([guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $testDrNoBuild -Force | Out-Null
Set-Content -Path (Join-Path $testDrNoBuild "package.json") -Value '{"name":"testapi","version":"2.0.0"}' -Encoding UTF8
Set-Content -Path (Join-Path $testDrNoBuild "deploy.yaml") -Value "server: real-server`nport: 8080" -Encoding UTF8
Set-Content -Path (Join-Path $testDrNoBuild ".env.production") -Value "PORT=8080`nNODE_ENV=production" -Encoding UTF8
try {
    Push-Location $testDrNoBuild
    $threwSSH = $false
    try {
        Publish-NodeApi -DeployReport -ErrorAction Stop *>&1 | Out-Null
    } catch {
        $threwSSH = $_.Exception.Message -notmatch 'package\.json|deploy\.yaml|your-ssh-alias|npm|tsc|build'
    }
    Assert-True $threwSSH "-DeployReport falla en SSH, no en compilación"
} finally {
    Pop-Location
    Remove-Item -Path $testDrNoBuild -Recurse -Force -ErrorAction SilentlyContinue
}

# ─── Resumen ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                    RESULTADOS                            ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$total = $passed + $failed + $skipped
Write-Host "  Total:    $total" -ForegroundColor White
Write-Host "  Passed:   $passed" -ForegroundColor Green
if ($failed -gt 0) {
    Write-Host "  Failed:   $failed" -ForegroundColor Red
} else {
    Write-Host "  Failed:   $failed" -ForegroundColor Green
}
if ($skipped -gt 0) {
    Write-Host "  Skipped:  $skipped" -ForegroundColor Yellow
}
Write-Host ""

if ($failed -gt 0) {
    Write-Host "  RESULTADO: FAIL" -ForegroundColor Red
    exit 1
} else {
    Write-Host "  RESULTADO: PASS" -ForegroundColor Green
    exit 0
}
