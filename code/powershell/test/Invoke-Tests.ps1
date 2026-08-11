# Invoke-Tests.ps1 — Ejecuta la suite del modulo.
#
# Uso:
#   .\test\Invoke-Tests.ps1                    # solo Pester (rapido, sin Docker)
#   .\test\Invoke-Tests.ps1 -Container         # ademas las pruebas de contenedor
#   .\test\Invoke-Tests.ps1 -Container -Only Pm2
#   .\test\Invoke-Tests.ps1 -ContainerOnly
#
# Por que existe
# -------------
# Las pruebas de contenedor son opt-in por diseno -necesitan Docker y tardan- pero no habia
# forma de optar: ni comando, ni script, ni documentacion. Eran las unicas que ejercitan los
# scripts bash remotos y el despliegue completo, y solo corrian si alguien recordaba que
# existian y armaba la invocacion a mano.
#
# Y en Windows no corrian de ninguna manera. Git Bash reescribe las rutas POSIX antes de
# pasarlas a Docker, asi que '-v "$DIR:/scripts:ro"' terminaba montando
# 'C:/Program Files/Git/scripts', que no existe:
#
#   sed: can't read /scripts/Deploy-DockerStack.sh: No such file or directory
#
# La causa no era la prueba: era la invocacion. Este runner pasa la ruta ya en formato
# Windows y desactiva la reescritura con MSYS_NO_PATHCONV, y con eso pasan.

[CmdletBinding()]
param(
    # Ejecutar tambien las pruebas de contenedor (requieren Docker).
    [switch]$Container,

    # Ejecutar SOLO las de contenedor, saltando Pester.
    [switch]$ContainerOnly,

    # Filtro por subcadena del nombre, para iterar sobre una sola.
    [string]$Only = ""
)

$ErrorActionPreference = "Stop"
$raiz = Split-Path $PSScriptRoot -Parent
$fallos = @()
$ok = 0
$omitidas = 0

function Write-Titulo($texto) {
    Write-Host ""
    Write-Host "══ $texto " -ForegroundColor Cyan -NoNewline
    Write-Host ("═" * [Math]::Max(0, 60 - $texto.Length)) -ForegroundColor Cyan
}

# ─── Pester ──────────────────────────────────────────────────────────────────
if (-not $ContainerOnly) {
    Write-Titulo "Pester"

    if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 })) {
        Write-Host "  Pester 5+ no esta instalado: Install-Module Pester -MinimumVersion 5.0" -ForegroundColor Red
        exit 1
    }

    $config = New-PesterConfiguration
    $config.Run.Path = $PSScriptRoot
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Normal'
    if ($Only) { $config.Filter.FullName = "*$Only*" }

    $r = Invoke-Pester -Configuration $config
    $ok += $r.PassedCount
    if ($r.FailedCount -gt 0) { $fallos += "Pester: $($r.FailedCount) fallo(s)" }
}

# ─── Contenedor ──────────────────────────────────────────────────────────────
if ($Container -or $ContainerOnly) {
    Write-Titulo "Contenedor"

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host "  Docker no esta disponible; se omiten las pruebas de contenedor." -ForegroundColor Yellow
        $omitidas = (Get-ChildItem $PSScriptRoot -Filter "*.container.test.*").Count
    } else {
        $pruebas = Get-ChildItem $PSScriptRoot -Filter "*.container.test.*" | Sort-Object Name
        if ($Only) { $pruebas = $pruebas | Where-Object { $_.Name -like "*$Only*" } }

        # En Windows hacen falta DOS formas de la misma ruta, y confundirlas es lo que hacia
        # imposible ejecutar estas pruebas:
        #
        #   bash abre el script   → necesita POSIX      /c/Users/...
        #   docker monta volumen  → necesita Windows    C:/Users/...
        #
        # Ademas hay que desactivar la reescritura de Git Bash (MSYS_NO_PATHCONV), que
        # convertia el '/scripts' del '-v' en 'C:/Program Files/Git/scripts'.
        $enWindows = $IsWindows -or $env:OS -eq 'Windows_NT'

        # C:\a\b  ->  /c/a/b   (para bash)
        $aPosix = {
            param($p)
            if (-not $enWindows) { return $p }
            ($p -replace '\\', '/') -replace '^([A-Za-z]):', { "/$($_.Groups[1].Value.ToLower())" }
        }
        # C:\a\b  ->  C:/a/b   (para docker)
        $aWindows = { param($p) if ($enWindows) { $p -replace '\\', '/' } else { $p } }

        $scriptsArg = & $aWindows (Resolve-Path (Join-Path $raiz "Private/scripts")).Path

        # En Windows hay que invocar Git Bash EXPLICITAMENTE. 'bash' a secas resuelve a
        # C:\WINDOWS\system32\bash.exe, que es el de WSL: monta los discos en /mnt/c, asi
        # que una ruta /c/... no existe para el y el script "no se encuentra". Las pruebas
        # tampoco funcionarian ahi, porque llaman al docker de Windows.
        $bash = 'bash'
        if ($enWindows) {
            $candidatos = @("$env:ProgramFiles\Git\bin\bash.exe",
                            "$env:ProgramFiles\Git\usr\bin\bash.exe")
            $git = (Get-Command git -ErrorAction SilentlyContinue).Source
            if ($git) { $candidatos += (Join-Path (Split-Path (Split-Path $git)) 'bin\bash.exe') }
            $bash = $candidatos | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $bash) {
                Write-Host "  Git Bash no encontrado; las pruebas .sh no se pueden ejecutar." -ForegroundColor Red
                Write-Host "  'bash' a secas es el de WSL y no sirve para estas pruebas." -ForegroundColor DarkGray
                exit 1
            }
        }

        foreach ($p in $pruebas) {
            Write-Host ""
            Write-Host "  ── $($p.BaseName)" -ForegroundColor DarkGray

            $anterior = $env:MSYS_NO_PATHCONV
            $env:MSYS_NO_PATHCONV = "1"
            try {
                if ($p.Extension -eq '.ps1') {
                    & $p.FullName
                } else {
                    & $bash (& $aPosix $p.FullName) $scriptsArg
                }
                $codigo = $LASTEXITCODE
            } finally {
                $env:MSYS_NO_PATHCONV = $anterior
            }

            if ($codigo -eq 0) {
                Write-Host "  PASS  $($p.BaseName)" -ForegroundColor Green
                $ok++
            } else {
                Write-Host "  FAIL  $($p.BaseName) (codigo $codigo)" -ForegroundColor Red
                $fallos += $p.BaseName
            }
        }
    }
}

# ─── Resumen ─────────────────────────────────────────────────────────────────
Write-Titulo "Resumen"
Write-Host "  pasaron : $ok" -ForegroundColor Gray
if ($omitidas) { Write-Host "  omitidas: $omitidas (sin Docker)" -ForegroundColor Yellow }
if ($fallos.Count) {
    Write-Host "  fallaron: $($fallos.Count)" -ForegroundColor Red
    $fallos | ForEach-Object { Write-Host "    · $_" -ForegroundColor Red }
} else {
    Write-Host "  fallaron: 0" -ForegroundColor Green
}
Write-Host ""

exit $(if ($fallos.Count) { 1 } else { 0 })
