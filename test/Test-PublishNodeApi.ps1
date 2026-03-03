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
Remove-Module PSDevOps -ErrorAction SilentlyContinue
Import-Module "$ModuleRoot\PSDevOps.psd1" -Force
$cmd = Get-Command Publish-NodeApi -ErrorAction SilentlyContinue
Assert-True ($null -ne $cmd) "Cmdlet Publish-NodeApi está disponible"

# ════════════════════════════════════════════════════════════════════
# TEST GROUP 1: Cmdlet metadata y parámetros
# ════════════════════════════════════════════════════════════════════
Write-TestHeader "1. Metadata del cmdlet"

$params = (Get-Command Publish-NodeApi).Parameters

Assert-True ($params.ContainsKey('Init')) "Parámetro -Init existe"
Assert-True ($params.ContainsKey('Deploy')) "Parámetro -Deploy existe"

# Verificar ParameterSets
$paramSets = (Get-Command Publish-NodeApi).ParameterSets
$setNames = $paramSets | ForEach-Object { $_.Name }
Assert-True ($setNames -contains 'Init') "ParameterSet 'Init' existe"
Assert-True ($setNames -contains 'Deploy') "ParameterSet 'Deploy' existe"

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
# TEST GROUP 6: -Deploy falla sin deploy.yaml
# ════════════════════════════════════════════════════════════════════
Write-TestHeader "6. -Deploy falla sin deploy.yaml"

$testNoDeploy = Join-Path $env:TEMP "psdevops_test_nodeploy_$([guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $testNoDeploy -Force | Out-Null
Set-Content -Path (Join-Path $testNoDeploy "package.json") -Value '{"name":"x","version":"1.0.0"}' -Encoding UTF8

try {
    Push-Location $testNoDeploy
    Assert-Throws { Publish-NodeApi -Deploy } "-Deploy lanza error sin deploy.yaml"
} finally {
    Pop-Location
    Remove-Item -Path $testNoDeploy -Recurse -Force -ErrorAction SilentlyContinue
}

# ════════════════════════════════════════════════════════════════════
# TEST GROUP 7: -Deploy falla sin .env.production
# ════════════════════════════════════════════════════════════════════
Write-TestHeader "7. -Deploy falla sin .env.production"

$testNoEnv = Join-Path $env:TEMP "psdevops_test_noenv_$([guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $testNoEnv -Force | Out-Null
Set-Content -Path (Join-Path $testNoEnv "package.json") -Value '{"name":"x","version":"1.0.0"}' -Encoding UTF8
Set-Content -Path (Join-Path $testNoEnv "tsconfig.json") -Value '{}' -Encoding UTF8
Set-Content -Path (Join-Path $testNoEnv "deploy.yaml") -Value "server: web-server" -Encoding UTF8

try {
    Push-Location $testNoEnv
    Assert-Throws { Publish-NodeApi -Deploy } "-Deploy lanza error sin .env.production"
} finally {
    Pop-Location
    Remove-Item -Path $testNoEnv -Recurse -Force -ErrorAction SilentlyContinue
}

# ════════════════════════════════════════════════════════════════════
# TEST GROUP 8: -Deploy valida server no sea valor de ejemplo
# ════════════════════════════════════════════════════════════════════
Write-TestHeader "8. -Deploy valida que server no sea el valor de ejemplo"

$testExample = Join-Path $env:TEMP "psdevops_test_example_$([guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $testExample -Force | Out-Null
Set-Content -Path (Join-Path $testExample "package.json") -Value '{"name":"x","version":"1.0.0"}' -Encoding UTF8
Set-Content -Path (Join-Path $testExample "tsconfig.json") -Value '{}' -Encoding UTF8
Set-Content -Path (Join-Path $testExample "deploy.yaml") -Value "server: api-server" -Encoding UTF8
Set-Content -Path (Join-Path $testExample ".env.production") -Value "PORT=8080`nNODE_ENV=production" -Encoding UTF8

try {
    Push-Location $testExample
    Assert-Throws { Publish-NodeApi -Deploy } "-Deploy lanza error con server de ejemplo 'api-server'"
} finally {
    Pop-Location
    Remove-Item -Path $testExample -Recurse -Force -ErrorAction SilentlyContinue
}

# ════════════════════════════════════════════════════════════════════
# TEST GROUP 9: Archivos de infraestructura existen
# ════════════════════════════════════════════════════════════════════
Write-TestHeader "9. Archivos de infraestructura del cmdlet"

$scriptsDir = Join-Path $ModuleRoot "src\Private\scripts"
$templateDir = Join-Path $ModuleRoot "src\Resources\Publish-NodeApi\templates"

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
# TEST GROUP 10: -Init en proyecto real (dispersion_bcp_server)
# ════════════════════════════════════════════════════════════════════
Write-TestHeader "10. -Init en proyecto real (dispersion_bcp_server)"

$realProject = "D:\source\cacsi-dev\bcp\dispersion_bcp_server"
$realDeploy = Join-Path $realProject "deploy.yaml"
$realEnvProd = Join-Path $realProject ".env.production"

# Limpiar por si hay remanentes de tests anteriores
Remove-Item $realDeploy -ErrorAction SilentlyContinue
Remove-Item $realEnvProd -ErrorAction SilentlyContinue

try {
    Push-Location $realProject

    Publish-NodeApi -Init

    # Verificar deploy.yaml
    Assert-True (Test-Path $realDeploy) "deploy.yaml creado en proyecto real"
    
    $realDeployParsed = (Get-Content $realDeploy -Raw) | ConvertFrom-Yaml
    Assert-True ($null -eq $realDeployParsed.name) "No contiene name (se lee de package.json)"
    Assert-True ($null -eq $realDeployParsed.version) "No contiene version (se lee de package.json)"
    Assert-Equal "api-server" $realDeployParsed.server "Server tiene valor placeholder"
    Assert-Equal "systemd" $realDeployParsed.runtime.processManager "processManager es systemd"

    # Verificar .env.production
    Assert-True (Test-Path $realEnvProd) ".env.production creado"

    # Leer package.json para verificar consistencia
    $pkg = Get-Content (Join-Path $realProject "package.json") -Raw | ConvertFrom-Json
    Assert-Equal "dispersion_bcp_api" $pkg.name "package.json name es correcto"

} finally {
    Pop-Location
    # Limpiar archivos generados en el proyecto real
    Remove-Item $realDeploy -ErrorAction SilentlyContinue
    Remove-Item $realEnvProd -ErrorAction SilentlyContinue
}

# ════════════════════════════════════════════════════════════════════
# TEST GROUP 11: Deploy e2e (requiere servidor real)
# ════════════════════════════════════════════════════════════════════
if ($SkipDeploy) {
    Write-TestHeader "11. Deploy e2e (SKIPPED — usar sin -SkipDeploy)"
    $skipped++
} else {
    Write-TestHeader "11. Deploy e2e a app-server con pm2"
    Write-Host "    (Este test requiere servidor 'app-server' en ~/.ssh/config)" -ForegroundColor DarkGray
    
    # Preparar proyecto con deploy.yaml real
    $e2eProject = Join-Path $env:TEMP "psdevops_test_e2e_$([guid]::NewGuid().ToString().Substring(0,8))"
    New-Item -ItemType Directory -Path $e2eProject -Force | Out-Null
    
    # Copiar proyecto real
    Copy-Item -Path "$realProject\*" -Destination $e2eProject -Recurse -Exclude @('node_modules', '.git', 'dist')
    
    # Crear deploy.yaml con valores de test
    $testDeployYaml = @"
server: app-server
runtime:
  processManager: pm2
  nodeVersion: ">=18"
health:
  retries: 6
  interval: 3
"@
    Set-Content -Path (Join-Path $e2eProject "deploy.yaml") -Value $testDeployYaml -Encoding UTF8
    
    # Crear .env.production
    $testEnvProd = @"
PORT=8080
NODE_ENV=production
"@
    Set-Content -Path (Join-Path $e2eProject ".env.production") -Value $testEnvProd -Encoding UTF8
    
    try {
        Push-Location $e2eProject
        Publish-NodeApi -Deploy
        Assert-True $true "Deploy e2e completado exitosamente"
    } catch {
        Assert-True $false "Deploy e2e falló: $_"
    } finally {
        Pop-Location
        Remove-Item -Path $e2eProject -Recurse -Force -ErrorAction SilentlyContinue
    }
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
