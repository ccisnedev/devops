# Test New-Issue cmdlet

Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║         🧪 TEST DEL CMDLET NEW-ISSUE                      ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Recargar el módulo con las nuevas funciones
Write-Host "📦 Recargando módulo PSDevOps..." -ForegroundColor Yellow
Remove-Module PSDevOps -ErrorAction SilentlyContinue
Import-Module $PSScriptRoot\..\PSDevOps.psd1 -Force
Write-Host "   ✅ Módulo recargado" -ForegroundColor Green
Write-Host ""

# Verificar que el cmdlet está disponible
Write-Host "🔍 Verificando cmdlet New-Issue..." -ForegroundColor Yellow
$cmdlet = Get-Command New-Issue -ErrorAction SilentlyContinue
if ($cmdlet) {
    Write-Host "   ✅ Cmdlet disponible" -ForegroundColor Green
} else {
    Write-Host "   ❌ Cmdlet no encontrado" -ForegroundColor Red
    exit 1
}
Write-Host ""

# Mostrar ayuda
Write-Host "📖 Ayuda del cmdlet:" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Get-Help New-Issue -Detailed
Write-Host ""

# Configuración de rutas
$moduleRoot = Split-Path -Parent $PSScriptRoot

# Verificar archivo de ejemplo
Write-Host "📄 Verificando archivo de ejemplo..." -ForegroundColor Yellow
$exampleFile = Join-Path $moduleRoot "src\Resources\New-Issue\examples\bug-pingcontroller.md"
if (Test-Path $exampleFile) {
    Write-Host "   ✅ Archivo de ejemplo encontrado" -ForegroundColor Green
    Write-Host "   📍 Ubicación: $exampleFile" -ForegroundColor Gray
} else {
    Write-Host "   ⚠️  Archivo de ejemplo no encontrado" -ForegroundColor Yellow
}
Write-Host ""

# Test de parsing (sin crear la issue)
Write-Host "🧪 Test de parsing (WhatIf)..." -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
if (Test-Path $exampleFile) {
    try {
        New-Issue -Path $exampleFile -WhatIf
        Write-Host ""
        Write-Host "✅ Test de parsing exitoso" -ForegroundColor Green
    }
    catch {
        Write-Host ""
        Write-Host "❌ Error en el test: $_" -ForegroundColor Red
    }
} else {
    Write-Host "⏭️  Saltando test (archivo no encontrado)" -ForegroundColor Yellow
}
Write-Host ""

# Instrucciones de uso
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║              ✅ TEST COMPLETADO                           ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "📚 Para más información:" -ForegroundColor Yellow
Write-Host "   Get-Help New-Issue -Examples" -ForegroundColor Cyan
$readmePath = Join-Path $moduleRoot "src\Resources\New-Issue\README.md"
Write-Host "   $readmePath" -ForegroundColor Cyan
Write-Host ""
Write-Host "🧪 Para probar creando una issue real:" -ForegroundColor Yellow
Write-Host "   New-Issue -Path $exampleFile" -ForegroundColor Cyan
Write-Host ""
