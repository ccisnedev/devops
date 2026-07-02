# DockerStackHelpers.ps1
# Helpers de Publish-DockerStack: lectura/validación de stack.yaml e identidad de release.
# Comparten estilo con PublishHelpers.ps1 (Get-ReleaseId, Test-CleanWorktree).

<#
.SYNOPSIS
Lee y valida stack.yaml (+ presencia de .env) y devuelve la configuración normalizada.

.DESCRIPTION
Fuente única de verdad de la configuración de un stack Docker Compose. Valida lo mínimo
para fallar temprano (server real, nombre, modo de build, imagen en transfer) y normaliza
health/postDeploy/include a formas estables que el cmdlet consume sin volver a chequear.

.PARAMETER ProjectRoot
Directorio donde viven stack.yaml, el compose y .env.

.EXAMPLE
$cfg = Get-DockerStackConfig -ProjectRoot (Get-Location).Path
#>
function Get-DockerStackConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $stackYaml = Join-Path $ProjectRoot 'stack.yaml'
    if (-not (Test-Path $stackYaml)) {
        throw "No se encontró stack.yaml en $ProjectRoot. Ejecute 'Publish-DockerStack -Init' primero."
    }
    if (-not (Test-Path (Join-Path $ProjectRoot '.env'))) {
        throw "No se encontró .env en $ProjectRoot. Cree el archivo con las variables/secretos del stack (Publish-DockerStack -Init lo genera)."
    }

    $y = (Get-Content $stackYaml -Raw) | ConvertFrom-Yaml

    $server = if ($y.server) { [string]$y.server } else { $null }
    if (-not $server) { throw "stack.yaml: falta 'server' (alias en ~/.ssh/config)." }
    if ($server -eq 'your-ssh-alias') { throw "stack.yaml contiene el valor de ejemplo 'your-ssh-alias'. Cambie 'server' por el alias SSH real." }

    $stack = $y.stack
    if (-not $stack -or -not $stack.name) { throw "stack.yaml: falta 'stack.name'." }
    $name = [string]$stack.name

    $composeFile = if ($stack.composeFile) { [string]$stack.composeFile } else { 'docker-compose.yml' }
    $version     = if ($stack.version) { [string]$stack.version } else { '0.0.0' }

    $build = if ($stack.build) { [string]$stack.build } else { 'server' }
    if ($build -notin @('server', 'transfer', 'none')) {
        throw "stack.yaml: 'stack.build' = '$build' no soportado. Use server | transfer | none."
    }
    $image = if ($stack.image) { [string]$stack.image } else { $null }
    if ($build -eq 'transfer' -and -not $image) {
        throw "stack.yaml: build:transfer requiere 'stack.image' (imagen a serializar con docker save/load)."
    }

    # include -> array de strings (rutas relativas)
    $include = @()
    if ($y.include) { $include = @($y.include | ForEach-Object { [string]$_ }) }

    # health -> modo url/container (url tiene precedencia) o ninguno
    $healthMode = $null; $healthTarget = $null
    $healthRetries = 30; $healthInterval = 4
    if ($y.health) {
        if ($y.health.retries)  { $healthRetries  = [int]$y.health.retries }
        if ($y.health.interval) { $healthInterval = [int]$y.health.interval }
        if ($y.health.url)       { $healthMode = 'url';       $healthTarget = [string]$y.health.url }
        elseif ($y.health.container) { $healthMode = 'container'; $healthTarget = [string]$y.health.container }
    }

    # postDeploy -> array de strings
    $postDeploy = @()
    if ($y.postDeploy) { $postDeploy = @($y.postDeploy | ForEach-Object { [string]$_ }) }

    return [pscustomobject]@{
        Server         = $server
        Name           = $name
        Version        = $version
        ComposeFile    = $composeFile
        Build          = $build
        Image          = $image
        Include        = $include
        HealthMode     = $healthMode
        HealthTarget   = $healthTarget
        HealthRetries  = $healthRetries
        HealthInterval = $healthInterval
        PostDeploy     = $postDeploy
    }
}

<#
.SYNOPSIS
Compone el identificador de release del stack: v{version}+{gitSha} (coherente con ADR 0003).

.DESCRIPTION
Usa el sha corto de git para identificar unívocamente cada despliegue. A diferencia de
Publish-NodeApi (build:false), aquí se empaqueta el árbol de trabajo, por lo que un árbol
sucio no es un error: se marca el release con '-dirty' y se avisa (salvo -AllowDirty).
Sin repo git, cae a 'v{version}'.

.PARAMETER ProjectRoot
Directorio del stack (dentro del repo git).

.PARAMETER Version
Versión declarada en stack.yaml (stack.version).

.PARAMETER AllowDirty
Silencia el aviso de árbol sucio.

.EXAMPLE
$release = Get-DockerStackRelease -ProjectRoot $cwd -Version '0.1.0'
#>
function Get-DockerStackRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [switch]$AllowDirty
    )

    $sha = (& git -C $ProjectRoot rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $sha) {
        return "v$Version"
    }

    if (-not (Test-CleanWorktree -Path $ProjectRoot)) {
        if (-not $AllowDirty) {
            Write-Warning "Árbol de git sucio: el release se marca '+$sha-dirty'. Use -AllowDirty para silenciar este aviso."
        }
        $sha = "$sha-dirty"
    }

    return (Get-ReleaseId -Version $Version -ShortSha $sha)
}
