<#
.SYNOPSIS
Despliega un stack de Docker Compose a un servidor Linux remoto vía SSH.

.DESCRIPTION
`Publish-DockerStack` lleva el mismo modelo Init/Plan/Apply de `Publish-NodeApi` (ADR 0002)
al despliegue de stacks Docker Compose sobre un servidor existente por SSH:
- Lee la configuración de `stack.yaml` (versionado, SIN secretos).
- Empaqueta el compose + el contexto declarado en `include:` y lo sube versionado
  (`/opt/stacks/<name>/releases/<release>` con symlink `current` para rollback).
- Sube `.env` (gitignored) al servidor como el env-file del stack (secretos fuera del repo).
- Levanta el stack con `docker compose -p <name> up -d` en uno de tres modos de build:
  server (build en el servidor), transfer (build local + `docker save`/`load`) o none.
- Espera a que el stack quede sano (contenedor `healthy` o una URL) y corre hooks `postDeploy`.

Compose ya es declarativo e idempotente (`up -d` reconcilia contra el estado deseado); este
cmdlet es el transporte + ciclo de vida + verificación alrededor de él. Es la contraparte de
`Publish-NodeApi` para infraestructura contenedorizada.

Se ejecuta desde el directorio donde viven `stack.yaml`, el compose y `.env`.

.PARAMETER Init
Genera `stack.yaml` y `.env` en el directorio actual, y agrega `.env` a `.gitignore`.

.PARAMETER Plan
Dry-run: muestra lo que hará -Apply (release, servidor, modo de build) y consulta el estado
remoto (release actual y contenedores) sin realizar cambios.

.PARAMETER Apply
Ejecuta el despliegue completo al servidor configurado en `stack.yaml`.

.PARAMETER AutoApprove
Omite la confirmación interactiva (uso desatendido / CI, ADR 0002).

.PARAMETER AllowDirty
Permite desplegar con el árbol de git sucio (marca el release con `-dirty`).

.EXAMPLE
Publish-DockerStack -Init

.EXAMPLE
Publish-DockerStack -Plan

.EXAMPLE
Publish-DockerStack -Apply

.NOTES
Versión: 1.0.0
Autor: @ccisnedev
Requiere:
  - Alias del host en ~/.ssh/config (Host, HostName, User, IdentityFile[, Port])
  - Docker + plugin compose en el servidor remoto
  - Docker local solo para el modo build:transfer
  - Módulo powershell-yaml para parsear stack.yaml
#>
function Publish-DockerStack {

    [CmdletBinding(DefaultParameterSetName = 'Apply')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Init',
            HelpMessage = "Generate configuration files (stack.yaml and .env)")]
        [switch]$Init,

        [Parameter(Mandatory, ParameterSetName = 'Plan',
            HelpMessage = "Dry-run: show what -Apply would do, without making changes")]
        [switch]$Plan,

        [Parameter(Mandatory, ParameterSetName = 'Apply',
            HelpMessage = "Execute the deployment to the remote server")]
        [switch]$Apply,

        [Parameter(ParameterSetName = 'Apply',
            HelpMessage = "Skip the confirmation prompt for unattended/CI use (ADR 0002)")]
        [switch]$AutoApprove,

        [Parameter(ParameterSetName = 'Apply',
            HelpMessage = "Allow deploying a dirty git worktree (release is tagged +dirty)")]
        [switch]$AllowDirty,

        [Parameter(ParameterSetName = 'Apply',
            HelpMessage = "Env file selecting the environment (default .env). Its MACSS_DEPLOY_SSH_ALIAS names the target; prod is explicit: -EnvFile .env.production")]
        [Parameter(ParameterSetName = 'Plan',
            HelpMessage = "Env file selecting the environment (default .env). Its MACSS_DEPLOY_SSH_ALIAS names the target.")]
        [string]$EnvFile = '.env'
    )

    begin {
        $ErrorActionPreference = 'Stop'
    }

    process {
        # Banner
        Show-MacssBanner -Title 'Publish-DockerStack'

        # ─── helpers compartidos ─────────────────────────
        . "$PSScriptRoot/../Private/PublishHelpers.ps1"
        . "$PSScriptRoot/../Private/Read-SSHConfig.ps1"

        switch ($PSCmdlet.ParameterSetName) {

            # ═══════════════════════════════════════════════════
            # INIT — Generar stack.yaml y .env
            # ═══════════════════════════════════════════════════
            'Init' {
                $cwd = (Get-Location).Path

                $stackYamlPath = Join-Path $cwd "stack.yaml"
                if (Test-Path $stackYamlPath) {
                    throw "Ya existe stack.yaml en $cwd. Elimínelo primero si desea regenerar la configuración."
                }

                $templatePath = Join-Path $PSScriptRoot "..\Resources\Publish-DockerStack\templates\stack.yaml"
                if (-not (Test-Path $templatePath)) {
                    throw "Template no encontrado: $templatePath"
                }
                Copy-Item -Path $templatePath -Destination $stackYamlPath
                Write-Host "  Creado: stack.yaml" -ForegroundColor Green

                # Crear .env si no existe
                $envPath = Join-Path $cwd ".env"
                if (-not (Test-Path $envPath)) {
                    $envContent = @"
# .env — Variables/secretos para el stack (consumido por docker compose --env-file).
# El destino del despliegue vive aqui, no en stack.yaml: un alias SSH es machine-local
# y versionarlo obliga a editar un archivo del repo para cambiar de entorno (ADR 0010).
MACSS_DEPLOY_SSH_ALIAS=
# Este archivo se copia al servidor en cada despliegue. NO versionar (está en .gitignore).

# EJEMPLO:
# SA_PASSWORD=change-me
"@
                    Set-Content -Path $envPath -Value $envContent -Encoding UTF8
                    Write-Host "  Creado: .env" -ForegroundColor Green
                } else {
                    Write-Host "  Existe: .env (no se modificó)" -ForegroundColor Yellow
                }

                # Agregar .env a .gitignore
                $gitignorePath = Join-Path $cwd ".gitignore"
                if (Test-Path $gitignorePath) {
                    $gitignoreContent = Get-Content $gitignorePath -Raw
                    if ($gitignoreContent -notmatch '(?m)^\.env\s*$') {
                        Add-Content -Path $gitignorePath -Value "`n.env"
                        Write-Host "  Actualizado: .gitignore (+.env)" -ForegroundColor Green
                    }
                } else {
                    Set-Content -Path $gitignorePath -Value ".env`n" -Encoding UTF8
                    Write-Host "  Creado: .gitignore" -ForegroundColor Green
                }

                Write-Host ""
                Write-Host "  Configuración creada. Próximos pasos:" -ForegroundColor Green
                Write-Host "    1. Edite stack.yaml → 'server' (alias SSH), 'stack.name', 'composeFile', 'include', 'health'" -ForegroundColor DarkGray
                Write-Host "    2. Edite .env → secretos/variables del stack" -ForegroundColor DarkGray
                Write-Host "    3. Ejecute: Publish-DockerStack -Plan  (dry-run)" -ForegroundColor DarkGray
                Write-Host "    4. Ejecute: Publish-DockerStack -Apply" -ForegroundColor DarkGray
                Write-Host ""
            }

            # ═══════════════════════════════════════════════════
            # APPLY — Despliegue completo
            # ═══════════════════════════════════════════════════
            'Apply' {
                $cwd = (Get-Location).Path
                Ensure-YamlModule

                $cfg = Get-DockerStackConfig -ProjectRoot $cwd
                $release = Get-DockerStackRelease -ProjectRoot $cwd -Version $cfg.Version -AllowDirty:$AllowDirty

                # El destino se resuelve antes de mostrarlo y antes de pedir confirmacion:
                # confirmar un despliegue sin ver a donde va anula el gate de ADR 0002.
                $server = Resolve-DeployTargetFromEnv -ProjectRoot $cwd -EnvFile $EnvFile `
                              -LegacyServer $cfg.Server -Cmdlet 'Publish-DockerStack'

                Write-Host "  Stack:      $($cfg.Name)" -ForegroundColor Cyan
                Write-Host "  Release:    $release" -ForegroundColor Cyan
                Write-Host "  Compose:    $($cfg.ComposeFile)" -ForegroundColor Cyan
                Write-Host "  Build:      $($cfg.Build)$(if ($cfg.Build -eq 'transfer') { " ($($cfg.Image))" })" -ForegroundColor Cyan
                Write-Host "  Servidor:   $server" -ForegroundColor Cyan
                if ($cfg.HealthMode) {
                    Write-Host "  Health:     $($cfg.HealthMode) → $($cfg.HealthTarget)" -ForegroundColor Cyan
                }
                Write-Host ""

                if (-not (Confirm-MacssChange -Action "Deploy stack '$($cfg.Name)' $release to '$server' (build:$($cfg.Build))" -AutoApprove:$AutoApprove)) {
                    Write-Host "  Apply cancelado." -ForegroundColor Yellow
                    return
                }

                # ─── SSH ─────────────────────────────────────
                $ssh = Read-SSHConfig -HostAlias $server
                $user = $ssh.User
                $ip = $ssh.HostName
                $sshPort = $ssh.Port
                $keyPath = $ssh.IdentityFile

                # ─── Constantes remotas ──────────────────────
                $remoteRoot  = "/opt/stacks"
                $stackDir    = "$remoteRoot/$($cfg.Name)"
                $releaseDir  = "$stackDir/releases/$release"
                $currentLink = "$stackDir/current"
                $tarballName = "$($cfg.Name)-$release.tar.gz"
                $remoteTar   = "/tmp/$tarballName"
                $remoteEnv   = "/tmp/$($cfg.Name).env"

                # ─── Empaquetar (compose + include) ──────────
                Write-Host "  Empaquetando stack..." -ForegroundColor Cyan
                $items = @($cfg.ComposeFile) + $cfg.Include | Select-Object -Unique
                foreach ($it in $items) {
                    if (-not (Test-Path (Join-Path $cwd $it))) {
                        throw "El elemento de 'include'/compose no existe: $it (relativo a $cwd)"
                    }
                }
                $localTar = Join-Path $env:TEMP $tarballName
                $tarArgs = @('-czf', $localTar, '-C', $cwd) + $items
                & tar.exe @tarArgs
                if (-not (Test-Path $localTar)) { throw "Error al crear el tarball del stack." }
                $tarMB = [math]::Round((Get-Item $localTar).Length / 1MB, 1)
                Write-Host "    $tarballName ($tarMB MB)" -ForegroundColor Green

                # ─── build:transfer → build local + save ─────
                $imageTar = $null
                if ($cfg.Build -eq 'transfer') {
                    Write-Host "  Build local (transfer)..." -ForegroundColor Cyan
                    & docker compose -f (Join-Path $cwd $cfg.ComposeFile) build
                    if ($LASTEXITCODE -ne 0) { throw "docker compose build (local) falló con código $LASTEXITCODE" }

                    Write-Host "  Serializando imagen $($cfg.Image) (docker save)..." -ForegroundColor Cyan
                    $imageTar = Join-Path $env:TEMP "$($cfg.Name)-image-$release.tar"
                    & docker save -o $imageTar $cfg.Image
                    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $imageTar)) { throw "docker save de $($cfg.Image) falló." }
                    $imgMB = [math]::Round((Get-Item $imageTar).Length / 1MB, 1)
                    Write-Host "    imagen $imgMB MB" -ForegroundColor Green
                }

                try {
                    # ─── Subir artefactos ────────────────────
                    Write-Host "  Subiendo a $ip..." -ForegroundColor Cyan
                    & scp -i $keyPath -P $sshPort $localTar "$($user)@$($ip):$remoteTar" 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Error al subir el tarball (scp exit: $LASTEXITCODE)" }

                    # Las claves MACSS_DEPLOY_* son metadato de despliegue, no config de runtime
                    # del stack: se filtran antes de subir (ADR 0004 §2, ADR 0010).
                    $envRaw = (Remove-DeployOnlyEnvKeys -Lines (Get-Content (Join-Path $cwd $EnvFile))) -join "`n"

                    $tmpEnv = New-UnixTempFile -Content $envRaw -Prefix "psdevops_dockenv_"
                    & scp -i $keyPath -P $sshPort $tmpEnv "$($user)@$($ip):$remoteEnv" 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Error al subir .env (scp exit: $LASTEXITCODE)" }
                    Remove-Item -LiteralPath $tmpEnv -ErrorAction SilentlyContinue
                    Write-Host "    tarball + .env subidos" -ForegroundColor Green

                    if ($cfg.Build -eq 'transfer') {
                        $remoteImg = "/tmp/$($cfg.Name)-image-$release.tar"
                        & scp -i $keyPath -P $sshPort $imageTar "$($user)@$($ip):$remoteImg" 2>&1 | Out-Null
                        if ($LASTEXITCODE -ne 0) { throw "Error al subir la imagen (scp exit: $LASTEXITCODE)" }
                        Write-Host "  Cargando imagen en el servidor (docker load)..." -ForegroundColor Cyan
                        $loadRc = Invoke-RemoteScript -ScriptContent "set -e`ndocker load -i '$remoteImg'`nrm -f '$remoteImg'" `
                            -User $user -IP $ip -Port $sshPort -KeyPath $keyPath -ScriptPrefix "psdevops_dockload_"
                        if ($loadRc -ne 0) { throw "docker load en el servidor falló con código $loadRc" }
                    }

                    # ─── Instalar release + up ───────────────
                    Write-Host "  Instalando release y levantando el stack..." -ForegroundColor Cyan
                    $buildFlag = switch ($cfg.Build) {
                        'server'   { '--build' }
                        'transfer' { '--no-build' }
                        default    { '' }
                    }
                    $deployScript = Get-BashScript -ScriptName "Deploy-DockerStack.sh" -Placeholders @{
                        '__NAME__'         = $cfg.Name
                        '__STACK_DIR__'    = $stackDir
                        '__RELEASE_DIR__'  = $releaseDir
                        '__CURRENT_LINK__' = $currentLink
                        '__TARBALL__'      = $remoteTar
                        '__REMOTE_ENV__'   = $remoteEnv
                        '__COMPOSE_FILE__' = $cfg.ComposeFile
                        '__BUILD_FLAG__'   = $buildFlag
                        '__RELEASE_ID__'   = $release
                    }
                    $rc = Invoke-RemoteScript -ScriptContent $deployScript `
                        -User $user -IP $ip -Port $sshPort -KeyPath $keyPath -ScriptPrefix "psdevops_dockdeploy_"
                    if ($rc -ne 0) { throw "El despliegue del stack falló con código $rc." }

                    # ─── Healthcheck ─────────────────────────
                    if ($cfg.HealthMode) {
                        Write-Host "  Verificando salud ($($cfg.HealthMode) → $($cfg.HealthTarget))..." -ForegroundColor Cyan
                        $healthScript = Get-BashScript -ScriptName "Wait-StackHealth.sh" -Placeholders @{
                            '__MODE__'     = $cfg.HealthMode
                            '__NAME__'     = $cfg.Name
                            '__TARGET__'   = $cfg.HealthTarget
                            '__RETRIES__'  = "$($cfg.HealthRetries)"
                            '__INTERVAL__' = "$($cfg.HealthInterval)"
                        }
                        $hrc = Invoke-RemoteScript -ScriptContent $healthScript `
                            -User $user -IP $ip -Port $sshPort -KeyPath $keyPath -ScriptPrefix "psdevops_dockhealth_"
                        if ($hrc -ne 0) {
                            throw "Healthcheck falló. Revise: ssh $server 'cd $currentLink && docker compose -p $($cfg.Name) logs --tail 80'"
                        }
                    } else {
                        Write-Host "  (sin healthcheck configurado)" -ForegroundColor Yellow
                    }

                    # ─── postDeploy ──────────────────────────
                    if ($cfg.PostDeploy -and $cfg.PostDeploy.Count -gt 0) {
                        Write-Host "  Ejecutando postDeploy ($($cfg.PostDeploy.Count) paso(s))..." -ForegroundColor Cyan
                        $lines = @("set -e", "cd '$currentLink'")
                        $lines += $cfg.PostDeploy
                        $prc = Invoke-RemoteScript -ScriptContent ($lines -join "`n") `
                            -User $user -IP $ip -Port $sshPort -KeyPath $keyPath -ScriptPrefix "psdevops_dockpost_"
                        if ($prc -ne 0) { throw "Un paso de postDeploy falló con código $prc." }
                    }

                    Write-Host ""
                    Write-Host "══════════════════════════════════════════════════" -ForegroundColor Green
                    Write-Host "  Deploy completado: $($cfg.Name) $release" -ForegroundColor Green
                    Write-Host "══════════════════════════════════════════════════" -ForegroundColor Green
                    Write-Host "  Servidor:  $server ($ip)" -ForegroundColor White
                    Write-Host "  Release:   $releaseDir" -ForegroundColor White
                    Write-Host "  Rollback:  ssh $server 'ln -sfn <release-anterior> $currentLink && cd $currentLink && docker compose -p $($cfg.Name) up -d'" -ForegroundColor White
                    Write-Host "══════════════════════════════════════════════════" -ForegroundColor Green
                    Write-Host ""
                }
                finally {
                    Remove-Item -LiteralPath $localTar -ErrorAction SilentlyContinue
                    if ($imageTar) { Remove-Item -LiteralPath $imageTar -ErrorAction SilentlyContinue }
                }
            }

            # ═══════════════════════════════════════════════════
            # PLAN — Dry-run
            # ═══════════════════════════════════════════════════
            'Plan' {
                $cwd = (Get-Location).Path
                Ensure-YamlModule

                $cfg = Get-DockerStackConfig -ProjectRoot $cwd
                $release = Get-DockerStackRelease -ProjectRoot $cwd -Version $cfg.Version -AllowDirty

                $server = Resolve-DeployTargetFromEnv -ProjectRoot $cwd -EnvFile $EnvFile `
                              -LegacyServer $cfg.Server -Cmdlet 'Publish-DockerStack'
                $ssh = Read-SSHConfig -HostAlias $server
                $user = $ssh.User; $ip = $ssh.HostName; $sshPort = $ssh.Port; $keyPath = $ssh.IdentityFile

                Write-Host "  Modo: SOLO REPORTE (no se realizarán cambios)" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  ─── Configuración local ───" -ForegroundColor Cyan
                Write-Host "  Stack:      $($cfg.Name)" -ForegroundColor White
                Write-Host "  Release:    $release" -ForegroundColor White
                Write-Host "  Compose:    $($cfg.ComposeFile)" -ForegroundColor White
                Write-Host "  Build:      $($cfg.Build)" -ForegroundColor White
                Write-Host "  Servidor:   $server ($ip)" -ForegroundColor White
                if ($cfg.HealthMode) { Write-Host "  Health:     $($cfg.HealthMode) → $($cfg.HealthTarget)" -ForegroundColor White }
                Write-Host ""

                Write-Host "  ─── Estado del servidor ───" -ForegroundColor Cyan
                $remoteRoot = "/opt/stacks"
                $stackDir = "$remoteRoot/$($cfg.Name)"
                $reportScript = @"
#!/bin/bash
if [ -L "$stackDir/current" ]; then
    echo "CURRENT:`$(readlink "$stackDir/current" | xargs basename)"
else
    echo "CURRENT:none"
fi
if [ -d "$stackDir/releases/$release" ]; then echo "RELEASE:exists"; else echo "RELEASE:new"; fi
if command -v docker >/dev/null 2>&1; then
    echo "--- docker compose ps ($($cfg.Name)) ---"
    docker compose -p "$($cfg.Name)" ps 2>/dev/null || echo "(sin contenedores para el proyecto)"
else
    echo "DOCKER:missing"
fi
"@
                $tmpLocal = New-UnixTempFile -Content $reportScript -Prefix "psdevops_dockreport_"
                try {
                    $remoteName = [IO.Path]::GetFileName($tmpLocal)
                    $remotePath = "/tmp/$remoteName"
                    & scp -i $keyPath -P $sshPort $tmpLocal "$($user)@$($ip):$remotePath" 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Error al conectar con el servidor (scp exit: $LASTEXITCODE)" }
                    $remoteCmd = "bash $remotePath ; rc=`$?; rm -f $remotePath; exit `$rc"
                    $output = & ssh -i $keyPath -p $sshPort "$($user)@$($ip)" $remoteCmd 2>&1
                } finally {
                    Remove-Item -LiteralPath $tmpLocal -ErrorAction SilentlyContinue
                }

                foreach ($line in $output) {
                    if ($line -match '^CURRENT:(.+)$') {
                        if ($Matches[1] -eq 'none') { Write-Host "  Current:    (primer deploy)" -ForegroundColor Yellow }
                        else { Write-Host "  Current:    $($Matches[1])" -ForegroundColor White }
                    }
                    elseif ($line -match '^RELEASE:(.+)$') {
                        if ($Matches[1] -eq 'exists') { Write-Host "  Release:    $release ya existe (se sobreescribirá)" -ForegroundColor Yellow }
                        else { Write-Host "  Release:    $release (nueva)" -ForegroundColor Green }
                    }
                    else { Write-Host "  $line" -ForegroundColor DarkGray }
                }

                Write-Host ""
                # Los pasos se numeran al imprimirse, no en el texto: con numeros fijos, saltarse
                # un paso condicional dejaba huecos (1, 3, 4, 5) e invitaba a preguntarse que fue
                # del 2 y si fallo en silencio.
                $acciones = @("Empaquetar compose + include en tar.gz")
                if ($cfg.Build -eq 'transfer') {
                    $acciones += "Build local + docker save/load de $($cfg.Image) al servidor"
                }
                $acciones += "Subir a ${ip}:$stackDir/releases/$release/ y apuntar 'current'"
                $acciones += "docker compose -p $($cfg.Name) up -d ($($cfg.Build))"
                if ($cfg.HealthMode)            { $acciones += "Healthcheck ($($cfg.HealthMode))" }
                if ($cfg.PostDeploy.Count -gt 0) { $acciones += "postDeploy: $($cfg.PostDeploy.Count) paso(s)" }

                Write-Host "  ─── Acciones que realizará -Apply ───" -ForegroundColor Cyan
                for ($i = 0; $i -lt $acciones.Count; $i++) {
                    Write-Host "  $($i + 1). $($acciones[$i])" -ForegroundColor White
                }
                Write-Host ""
            }
        }
    }
}
