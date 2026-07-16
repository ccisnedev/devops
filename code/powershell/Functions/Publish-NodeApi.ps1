<#
.SYNOPSIS
Despliega una API Node.js/TypeScript a un servidor Linux remoto vía SSH.

.DESCRIPTION
El cmdlet `Publish-NodeApi` gestiona el ciclo completo de despliegue de APIs TypeScript:
- Lee `name` y `version` de `package.json` (single source of truth).
- Lee la configuración de despliegue de `publish.yaml`.
- Ejecuta build local (npm ci + tsc) y empaqueta los artefactos compilados.
- Sube dist/ + node_modules/ + package.json al servidor (no requiere internet en el servidor).
- Usa releases versionados con symlink `current` para rollback fácil.
- Soporta systemd (default) y PM2 como process managers.

Se debe ejecutar desde la raíz del proyecto donde existen:
  - package.json   (name, version)
  - tsconfig.json  (proyecto TypeScript)
  - publish.yaml   (servidor, runtime, health, api — generar con -Init)
  - .env.production (variables de entorno — se copia al servidor como .env)

.PARAMETER Init
Genera los archivos de configuración (publish.yaml y .env.production) en el directorio actual.
Requiere que existan package.json y tsconfig.json.

.PARAMETER Publish
Ejecuta el despliegue completo al servidor remoto.
Lee publish.yaml para el servidor destino y la configuración de runtime.
Siempre sube .env.production como .env dentro del release.

.PARAMETER DeployReport
Muestra las acciones que realizará -Publish sin ejecutarlas.
Consulta el servidor para mostrar: versión actual, si la release existe, estado del servicio.

.EXAMPLE
Publish-NodeApi -Init

Genera publish.yaml y .env.production en el directorio actual del proyecto TypeScript.

.EXAMPLE
Publish-NodeApi -DeployReport

Muestra un reporte de lo que hará -Publish sin realizar cambios.

.EXAMPLE
Publish-NodeApi -Publish

Empaqueta, sube y despliega la API al servidor configurado en publish.yaml. Acepta el nombre anterior deploy.yaml con aviso de deprecación.

.NOTES
Versión: 2.0.0
Autor: @ccisnedev
Requiere:
  - Configuración del host en ~/.ssh/config (Host, HostName, User, Port, IdentityFile)
  - Node.js y npm instalados localmente para el build
  - Node.js en el servidor remoto (solo runtime, no necesita internet)
  - PM2 o systemd según la configuración de publish.yaml
  - Módulo powershell-yaml para parseo de publish.yaml
#>
function Publish-NodeApi {

    [CmdletBinding(DefaultParameterSetName = 'Apply')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Init',
            HelpMessage = "Generate configuration files (publish.yaml and .env.production)")]
        [switch]$Init,

        [Parameter(Mandatory, ParameterSetName = 'Plan',
            HelpMessage = "Dry-run: show what -Apply would do, without making changes")]
        [Alias('DeployReport')]
        [switch]$Plan,

        [Parameter(Mandatory, ParameterSetName = 'Apply',
            HelpMessage = "Execute the deployment to the remote server")]
        [Alias('Publish')]
        [switch]$Apply,

        [Parameter(ParameterSetName = 'Apply',
            HelpMessage = "Skip the confirmation prompt for unattended/CI use (ADR 0002)")]
        [Parameter(ParameterSetName = 'PushShared',
            HelpMessage = "Skip the confirmation prompt for unattended/CI use (ADR 0002)")]
        [switch]$AutoApprove,

        [Parameter(ParameterSetName = 'Apply',
            HelpMessage = "Allow deploying a dirty worktree in build:false (packages the working dir, tags +dirty)")]
        [switch]$AllowDirty,

        [Parameter(Mandatory, ParameterSetName = 'PushShared',
            HelpMessage = "Sube (reemplazo limpio) los runtime.sharedPaths locales al servidor. Modo propio, separado de -Apply. Confirma mostrando destino; -AutoApprove para desatendido.")]
        [switch]$PushShared,

        [Parameter(ParameterSetName = 'Apply',
            HelpMessage = "Env file selecting the environment (default .env). Its MACSS_DEPLOY_SERVER names the target; prod is explicit: -EnvFile .env.production")]
        [Parameter(ParameterSetName = 'Plan',
            HelpMessage = "Env file selecting the environment (default .env). Its MACSS_DEPLOY_SERVER names the target.")]
        [Parameter(ParameterSetName = 'PushShared',
            HelpMessage = "Env file selecting the environment (default .env). Its MACSS_DEPLOY_SERVER names the target.")]
        [string]$EnvFile = '.env'
    )

    begin {
        $ErrorActionPreference = 'Stop'
    }

    process {
        # Banner
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║       Publish-NodeApi — macss-devops            ║" -ForegroundColor Cyan
        Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""

        # Deprecation notice for the pre-ADR-0002 vocabulary.
        if ($MyInvocation.Line -match '-(Publish|DeployReport)\b') {
            Write-Warning "-Publish/-DeployReport are deprecated; use -Apply/-Plan (ADR 0002). They will be removed in a future major."
        }

        switch ($PSCmdlet.ParameterSetName) {

            # ═══════════════════════════════════════════════════
            # INIT — Generar publish.yaml y .env.production
            # ═══════════════════════════════════════════════════
            'Init' {
                $cwd = (Get-Location).Path

                # Validar package.json
                $packageJsonPath = Join-Path $cwd "package.json"
                if (-not (Test-Path $packageJsonPath)) {
                    throw "No se encontró package.json en $cwd. Ejecute este cmdlet dentro de un proyecto Node.js."
                }

                # Detectar modo (ADR 0003): con tsconfig.json → build:true (TS);
                # sin tsconfig.json → build:false (API Node sin build, empaqueta el fuente).
                $tsconfigPath = Join-Path $cwd "tsconfig.json"
                $isBuildProject = Test-Path $tsconfigPath

                # Validar que publish.yaml no exista (ni el legacy deploy.yaml)
                $publishYamlPath = Join-Path $cwd "publish.yaml"
                if (Test-Path $publishYamlPath) {
                    throw "Ya existe publish.yaml en $cwd. Elimínelo primero si desea regenerar la configuración."
                }
                if (Test-Path (Join-Path $cwd "deploy.yaml")) {
                    throw "Existe deploy.yaml (nombre anterior) en $cwd. Renómbrelo a publish.yaml o elimínelo antes de regenerar."
                }

                # Leer package.json para mostrar información
                $pkg = Get-Content $packageJsonPath -Raw | ConvertFrom-Json
                $appName = $pkg.name
                $appVersion = $pkg.version

                Write-Host "  Proyecto:  $appName" -ForegroundColor Cyan
                Write-Host "  Versión:   $appVersion" -ForegroundColor Cyan
                Write-Host ""

                # Copiar template publish.yaml
                $templatePath = Join-Path $PSScriptRoot "..\Resources\Publish-NodeApi\templates\publish.yaml"
                if (-not (Test-Path $templatePath)) {
                    throw "Template no encontrado: $templatePath"
                }
                Copy-Item -Path $templatePath -Destination $publishYamlPath
                # Sin tsconfig.json: configurar el runtime no-build (ADR 0003).
                if (-not $isBuildProject) {
                    $yaml = Get-Content $publishYamlPath -Raw
                    $yaml = $yaml -replace 'build: true', 'build: false'
                    $yaml = $yaml -replace 'entrypoint: dist/main\.js', 'entrypoint: server.js'
                    Set-Content -Path $publishYamlPath -Value $yaml -Encoding UTF8
                    Write-Host "  Creado: publish.yaml (runtime build:false — sin tsconfig.json)" -ForegroundColor Green
                } else {
                    Write-Host "  Creado: publish.yaml (runtime build:true — TypeScript)" -ForegroundColor Green
                }

                # Env files (ADR 0004): asegurar MACSS_DEPLOY_SERVER en .env (default: dev/pre-prod)
                # y .env.production (prod). Ambos gitignored; cada uno lleva su propio destino.
                foreach ($ef in @(
                    @{ Name = '.env';            Label = 'default (dev/pre-prod)' },
                    @{ Name = '.env.production'; Label = 'producción' }
                )) {
                    $efPath = Join-Path $cwd $ef.Name
                    $status = Add-EnvDeployKey -Path $efPath -EnvLabel $ef.Label
                    switch ($status) {
                        'created'  { Write-Host "  Creado: $($ef.Name) (con MACSS_DEPLOY_SERVER=)" -ForegroundColor Green }
                        'appended' { Write-Host "  Actualizado: $($ef.Name) (+MACSS_DEPLOY_SERVER=)" -ForegroundColor Green }
                        'exists'   { Write-Host "  Existe: $($ef.Name) (ya tiene MACSS_DEPLOY_SERVER)" -ForegroundColor Yellow }
                    }
                }

                # Gitignorar los env files (patrón .env*, excepto ejemplos)
                $gitignorePath = Join-Path $cwd ".gitignore"
                $ignoreRules = @('.env', '.env.production', '.env.*', '!.env.example')
                if (Test-Path $gitignorePath) {
                    $gitignoreContent = Get-Content $gitignorePath -Raw
                    $toAdd = $ignoreRules | Where-Object { $gitignoreContent -notmatch ([regex]::Escape($_) + '(\r?\n|$)') }
                    if ($toAdd) {
                        Add-Content -Path $gitignorePath -Value ("`n" + ($toAdd -join "`n"))
                        Write-Host "  Actualizado: .gitignore (+$($toAdd -join ', '))" -ForegroundColor Green
                    }
                } else {
                    Set-Content -Path $gitignorePath -Value (($ignoreRules -join "`n") + "`n") -Encoding UTF8
                    Write-Host "  Creado: .gitignore" -ForegroundColor Green
                }

                # Instrucciones
                Write-Host ""
                Write-Host "  Configuración creada. Próximos pasos:" -ForegroundColor Green
                Write-Host "    1. Edite .env → MACSS_DEPLOY_SERVER=<su alias de ~/.ssh/config> + variables del entorno dev/pre-prod" -ForegroundColor DarkGray
                Write-Host "    2. Edite .env.production → MACSS_DEPLOY_SERVER=<alias prod> + variables de producción" -ForegroundColor DarkGray
                Write-Host "    3. (modular_api) Declare el basePath en package.json: `"modularApi`": { `"basePath`": `"/api/v1`" }" -ForegroundColor DarkGray
                Write-Host "    4. Deploy: Publish-NodeApi -Apply           (usa .env)" -ForegroundColor DarkGray
                Write-Host "              Publish-NodeApi -Apply -EnvFile .env.production   (prod, explícito)" -ForegroundColor DarkGray
                Write-Host ""
            }

            # ═══════════════════════════════════════════════════
            # PUBLISH — Despliegue completo
            # ═══════════════════════════════════════════════════
            'Apply' {
                $cwd = (Get-Location).Path
                Ensure-YamlModule

                # ─── 1. Cargar helpers ───────────────────────
                . "$PSScriptRoot/../Private/PublishHelpers.ps1"
                . "$PSScriptRoot/../Private/Read-SSHConfig.ps1"

                # ─── 0. Validaciones ─────────────────────────
                $configResolution = Resolve-PublishConfigPath -ProjectRoot $cwd
                $publishYamlPath = $configResolution.Path
                $packageJsonPath = Join-Path $cwd "package.json"
                $tsconfigPath = Join-Path $cwd "tsconfig.json"
                # Env file que selecciona el entorno (ADR 0004): default .env, sobreescribible
                # con -EnvFile (p.ej. .env.production para prod). Lleva MACSS_DEPLOY_SERVER.
                $envProdPath = if ([System.IO.Path]::IsPathRooted($EnvFile)) { $EnvFile } else { Join-Path $cwd $EnvFile }

                if (-not $publishYamlPath) {
                    throw "No se encontró publish.yaml. Ejecute 'Publish-NodeApi -Init' primero."
                }
                if ($configResolution.IsLegacy) {
                    Write-Host "  Aviso: 'deploy.yaml' está deprecado; renómbrelo a 'publish.yaml'." -ForegroundColor Yellow
                }
                if (-not (Test-Path $packageJsonPath)) {
                    throw "No se encontró package.json en $cwd."
                }
                # tsconfig.json solo se exige en modo build:true (ADR 0003) — se valida
                # más abajo, una vez leída la configuración de runtime.
                if (-not (Test-Path $envProdPath)) {
                    throw "No se encontró el env file '$EnvFile' en $cwd. Ejecute 'Publish-NodeApi -Init' o especifique -EnvFile <archivo>."
                }

                # ─── 2. Leer configuración ───────────────────
                # publish.yaml (server, runtime, health, api)
                $deployConfig = (Get-Content $publishYamlPath -Raw) | ConvertFrom-Yaml

                # package.json (name, version)
                $pkg = Get-Content $packageJsonPath -Raw | ConvertFrom-Json
                $appName = $pkg.name
                $appVersion = ($pkg.version -split '\+')[0]  # sin build metadata

                # ─── Runtime (ADR 0003): build (default true) + entrypoint ───
                $runtime = Resolve-NodeRuntime -PublishConfig $deployConfig
                $entrypoint = $runtime.Entrypoint

                # tsconfig.json se exige solo en modo build:true
                if ($runtime.Build -and -not (Test-Path $tsconfigPath)) {
                    throw "No se encontró tsconfig.json en $cwd (requerido en modo build:true). Para una API sin build declare 'runtime.build: false' en publish.yaml."
                }

                # ─── Identidad de release: v{version}+{shortSha} (ADR 0003) ───
                $gitSha = (& git -C $cwd rev-parse --short HEAD 2>$null)
                $inGitRepo = ($LASTEXITCODE -eq 0 -and $gitSha)
                if ($inGitRepo) {
                    # Guard de árbol limpio: build:false despliega desde HEAD.
                    if (-not $runtime.Build -and -not (Test-CleanWorktree -Path $cwd)) {
                        if (-not $AllowDirty) {
                            throw "El árbol de trabajo tiene cambios sin commitear. build:false despliega desde HEAD (git archive); commitee los cambios o use -AllowDirty."
                        }
                        Write-Warning "Árbol sucio: -AllowDirty empaqueta el working dir. La release se marcará +dirty."
                        $gitSha = "$gitSha-dirty"
                    }
                    $release = Get-ReleaseId -Version $appVersion -ShortSha $gitSha
                } else {
                    if (-not $runtime.Build) {
                        throw "build:false requiere un repositorio git (el artefacto se arma desde HEAD). No se detectó repo en $cwd."
                    }
                    $gitSha = ''
                    $release = "v$appVersion"
                }

                # env file (PORT + destino). ADR 0004: el destino sale de MACSS_DEPLOY_SERVER
                # del env elegido, no de publish.yaml (que ya no lleva 'server').
                $envConfig = Read-DotEnv -Path $envProdPath -DefaultPort 8080
                $port = $envConfig.Port
                $server = Resolve-DeployTarget -EnvVars $envConfig.Env -EnvFilePath $EnvFile

                $processManager = if ($deployConfig.runtime -and $deployConfig.runtime.processManager) {
                    $deployConfig.runtime.processManager
                } else { 'systemd' }
                $nodeVersion = if ($deployConfig.runtime -and $deployConfig.runtime.nodeVersion) { 
                    $deployConfig.runtime.nodeVersion 
                } else { '>=18' }
                # sudo is opt-in (default rootless): the deploy user owns REMOTE_ROOT/<name>.
                $useSudo = if ($deployConfig.runtime -and ($null -ne $deployConfig.runtime.useSudo)) {
                    [bool]$deployConfig.runtime.useSudo
                } else { $false }
                $healthRetries = if ($deployConfig.health -and $deployConfig.health.retries) {
                    $deployConfig.health.retries
                } else { 6 }
                $healthInterval = if ($deployConfig.health -and $deployConfig.health.interval) {
                    $deployConfig.health.interval
                } else { 3 }
                # basePath del API: package.json (modularApi.basePath) > publish.yaml (api.basePath) > raiz
                $apiBasePath = Resolve-ApiBasePath -PackageJson $pkg -PublishConfig $deployConfig

                # ─── 3. Validaciones de config ───────────────
                if (-not $server) {
                    throw "No se encontró 'server:' en publish.yaml."
                }
                if ($server -eq 'your-ssh-alias') {
                    throw "publish.yaml contiene el valor de ejemplo 'your-ssh-alias'. Cambie 'server' por el alias SSH real de su servidor."
                }
                if ($processManager -notin @('systemd', 'pm2')) {
                    throw "Process manager '$processManager' no soportado. Use 'systemd' o 'pm2'."
                }

                Write-Host "  Proyecto:   $appName" -ForegroundColor Cyan
                Write-Host "  Release:    $release" -ForegroundColor Cyan
                Write-Host "  Runtime:    $(if ($runtime.Build) { 'build (TypeScript)' } else { 'no-build (source)' }) → $entrypoint" -ForegroundColor Cyan
                if (@($runtime.SharedPaths).Count -gt 0) {
                    Write-Host "  Shared:     $(@($runtime.SharedPaths) -join ', ') (symlink desde shared/, no versionado)" -ForegroundColor Cyan
                }
                Write-Host "  Servidor:   $server" -ForegroundColor Cyan
                Write-Host "  Proceso:    $processManager" -ForegroundColor Cyan
                Write-Host "  Puerto:     $port" -ForegroundColor Cyan
                if ($apiBasePath) {
                    Write-Host "  BasePath:   $apiBasePath" -ForegroundColor Cyan
                }
                Write-Host ""

                # ─── Confirmation (ADR 0002): the summary above is the plan; confirm before applying. ───
                if (-not (Confirm-MacssChange -Action "Deploy $appName $release to '$server' ($processManager)" -AutoApprove:$AutoApprove)) {
                    Write-Host "  Apply cancelled." -ForegroundColor Yellow
                    return
                }

                # ─── 4. SSH Config ───────────────────────────
                $sshConfig = Read-SSHConfig -HostAlias $server
                $user = $sshConfig.User
                $ip = $sshConfig.HostName
                $sshPort = $sshConfig.Port
                $privateKeyPath = $sshConfig.IdentityFile

                # ─── Constantes remotas ──────────────────────
                $remoteRoot = "/opt/app"
                $releaseDir = "$remoteRoot/$appName/releases/$release"
                $currentLink = "$remoteRoot/$appName/current"
                $entryPath = "$currentLink/$entrypoint"
                $workingDir = "$currentLink"
                $envFile = "$currentLink/.env"
                $tarballName = "${appName}-${release}.tar.gz"
                $remoteTarball = "/tmp/$tarballName"
                $remoteEnvFile = "/tmp/${appName}.env.production"

                # ─── 5. Preparar artefactos ──────────────────
                $localTarball = Join-Path $env:TEMP $tarballName
                $isWindowsHost = ($env:OS -eq 'Windows_NT')

                if ($runtime.Build) {
                    # ══ Modo build:true (TypeScript) — flujo original ══
                    Write-Host "  Compilando localmente..." -ForegroundColor Cyan

                    # 5a. Instalar TODAS las dependencias (incluye devDeps para tsc)
                    Write-Host "    npm ci..." -ForegroundColor DarkGray
                    $npmCiResult = & npm ci 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        $npmCiResult | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
                        throw "npm ci falló con código $LASTEXITCODE"
                    }
                    Write-Host "    Dependencias instaladas" -ForegroundColor Green

                    # 5b. Build TypeScript
                    Write-Host "    npm run build..." -ForegroundColor DarkGray
                    $buildResult = & npm run build 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        $buildResult | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
                        throw "npm run build falló con código $LASTEXITCODE"
                    }

                    # Verificar que el entrypoint compilado se generó
                    $entryLocal = Join-Path $cwd ($entrypoint -replace '/', '\')
                    if (-not (Test-Path $entryLocal)) {
                        throw "Build completó pero el entrypoint '$entrypoint' no existe. Verifique tsconfig.json / runtime.entrypoint."
                    }
                    Write-Host "    Build completado ($entrypoint OK)" -ForegroundColor Green

                    # 5c. Reinstalar solo dependencias de producción (para tarball liviano)
                    Write-Host "    npm ci --omit=dev (producción)..." -ForegroundColor DarkGray
                    $npmProdResult = & npm ci --omit=dev 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        $npmProdResult | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
                        throw "npm ci --omit=dev falló con código $LASTEXITCODE"
                    }
                    Write-Host "    node_modules optimizado para producción" -ForegroundColor Green

                    # 6. Empaquetar: dist/ + node_modules/ + package.json (+ ecosystem.config.js)
                    Write-Host "  Empaquetando artefactos..." -ForegroundColor Cyan
                    $tarItems = @('dist', 'node_modules', 'package.json')
                    if (Test-Path (Join-Path $cwd 'ecosystem.config.js')) {
                        $tarItems += 'ecosystem.config.js'
                        Write-Host "  ecosystem.config.js detected (config-as-code)" -ForegroundColor Green
                    }
                    $tarCmd = "tar.exe -czf `"$localTarball`" -C `"$cwd`" $($tarItems -join ' ')"
                    $tarResult = Invoke-Expression $tarCmd 2>&1
                    if (-not (Test-Path $localTarball)) {
                        throw "Error al crear tarball: $tarResult"
                    }
                } else {
                    # ══ Modo build:false (ADR 0003) — empaquetar el fuente desde HEAD ══
                    Write-Host "  Modo build:false (sin compilación)" -ForegroundColor Cyan

                    # Empaquetado build:false: fuente versionado (git archive HEAD) +
                    # node_modules de producción. Todo se construye en un dir temporal
                    # ext4 (mktemp) vía Build-NodeApiPackage.sh — NO muta el working tree
                    # (no borra devDependencies) y NO corre npm ci sobre drvfs (/mnt/c en
                    # WSL, que da EIO). En Windows se ejecuta dentro de WSL; en Linux, nativo.
                    $modulesPlan = Get-ProdModulesPlan -IsWindowsHost $isWindowsHost
                    Write-Host "  Empaquetando (git archive HEAD + npm ci --omit=dev, $modulesPlan)..." -ForegroundColor Cyan

                    $srcTar = Join-Path $env:TEMP "psdevops_src_$([guid]::NewGuid().ToString('N').Substring(0,8)).tar"

                    # Materializar el script a un temp con LF (sin BOM) y ejecutarlo como
                    # archivo — NO por stdin: al pipear, PowerShell añade un CRLF final que
                    # bash interpreta como un comando `\r` (exit 127 espurio tras el build).
                    $buildScript = (Get-BashScript -ScriptName 'Build-NodeApiPackage.sh' -Placeholders @{}) -replace "`r`n", "`n" -replace "`r", "`n"
                    $buildScriptTmp = Join-Path $env:TEMP "psdevops_build_$([guid]::NewGuid().ToString('N').Substring(0,8)).sh"
                    [System.IO.File]::WriteAllText($buildScriptTmp, $buildScript, (New-Object System.Text.UTF8Encoding $false))
                    try {
                        # Empaqueta el subarbol versionado del componente desde el TOPLEVEL del
                        # repo (depth-agnostico; ver Export-GitSubtreeTar). Evita el tar vacio que
                        # producia 'git -C <subdir> archive HEAD:<prefix>' cuando el api vive en un
                        # subdir del monorepo (p. ej. code/api).
                        Export-GitSubtreeTar -Path $cwd -OutTar $srcTar
                        if ($modulesPlan -eq 'wsl') {
                            $distro = Get-ValidWSLDistro
                            $wslSrc = ConvertTo-WSLPath -winPath $srcTar -WSLDistro $distro
                            $wslOut = ConvertTo-WSLPath -winPath $localTarball -WSLDistro $distro
                            $wslScript = ConvertTo-WSLPath -winPath $buildScriptTmp -WSLDistro $distro
                            & wsl.exe -d $distro -- bash $wslScript $wslSrc $entrypoint $wslOut 2>&1 |
                                ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
                            if ($LASTEXITCODE -ne 0) { throw "Empaquetado en WSL falló con código $LASTEXITCODE" }
                        } else {
                            & bash $buildScriptTmp $srcTar $entrypoint $localTarball 2>&1 |
                                ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
                            if ($LASTEXITCODE -ne 0) { throw "Empaquetado falló con código $LASTEXITCODE" }
                        }
                        if (-not (Test-Path $localTarball)) {
                            throw "Error al crear el tarball de fuente."
                        }
                    } finally {
                        Remove-Item -LiteralPath $srcTar, $buildScriptTmp -ErrorAction SilentlyContinue
                    }
                    Write-Host "    node_modules (producción) listo — working tree intacto" -ForegroundColor Green
                }

                $tarSize = [math]::Round((Get-Item $localTarball).Length / 1MB, 1)
                Write-Host "  Tarball: $tarballName ($($tarSize) MB)" -ForegroundColor Green

                try {
                    # ─── 7. SCP: subir tarball + .env ────────
                    Write-Host "  Subiendo archivos a $ip..." -ForegroundColor Cyan

                    # Subir tarball
                    $scpArgs = @('-i', $privateKeyPath, '-P', $sshPort, $localTarball, "$($user)@$($ip):$remoteTarball")
                    & scp @scpArgs 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Error al subir tarball (scp exit: $LASTEXITCODE)" }
                    Write-Host "    Tarball subido" -ForegroundColor Green

                    # Subir el env como .env del release (LF para bash en Linux). ADR 0004: se
                    # quitan las claves MACSS_DEPLOY_* (metadato deploy-time) para no contaminar
                    # el runtime env de la app.
                    $envContent = (Remove-DeployOnlyEnvKeys -Lines @(Get-Content $envProdPath)) -join "`n"
                    $tmpEnvPath = New-UnixTempFile -Content $envContent -Prefix "psdevops_env_"
                    $scpEnvArgs = @('-i', $privateKeyPath, '-P', $sshPort, $tmpEnvPath, "$($user)@$($ip):$remoteEnvFile")
                    & scp @scpEnvArgs 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Error al subir el env (scp exit: $LASTEXITCODE)" }
                    Write-Host "    $EnvFile subido como .env (LF, sin MACSS_DEPLOY_*)" -ForegroundColor Green

                    # ─── 8. Instalar release ─────────────────
                    Write-Host "  Instalando release $release..." -ForegroundColor Cyan

                    $installScript = Get-BashScript -ScriptName "Install-NodeApi.sh" -Placeholders @{
                        '__NAME__'          = $appName
                        '__VERSION__'       = $appVersion
                        '__REMOTE_ROOT__'   = $remoteRoot
                        '__NODE_VERSION__'  = $nodeVersion
                        '__USER__'          = $user
                        '__USE_SUDO__'      = ($(if ($useSudo) { '1' } else { '0' }))
                        '__ENTRYPOINT__'    = $entrypoint
                        '__RELEASE_ID__'    = $release
                        '__GIT_SHA__'       = $gitSha
                        '__SHARED_PATHS__'  = (@($runtime.SharedPaths) -join ' ')
                    }

                    $exitCode = Invoke-RemoteScript -ScriptContent $installScript `
                                                    -User $user -IP $ip -Port $sshPort `
                                                    -KeyPath $privateKeyPath `
                                                    -ScriptPrefix "psdevops_install_nodeapi_"

                    if ($exitCode -ne 0) {
                        throw "Instalación falló con código $exitCode. Revise la salida anterior."
                    }

                    # ─── 9. Gestionar proceso ────────────────
                    Write-Host "  Configurando $processManager..." -ForegroundColor Cyan

                    $manageScript = Get-BashScript -ScriptName "Manage-NodeProcess.sh" -Placeholders @{
                        '__NAME__'             = $appName
                        '__PROCESS_MANAGER__'  = $processManager
                        '__ENTRY_PATH__'       = $entryPath
                        '__WORKING_DIR__'      = $workingDir
                        '__ENV_FILE__'         = $envFile
                        '__PORT__'             = $port.ToString()
                        '__USER__'             = $user
                    }

                    $exitCode = Invoke-RemoteScript -ScriptContent $manageScript `
                                                    -User $user -IP $ip -Port $sshPort `
                                                    -KeyPath $privateKeyPath `
                                                    -ScriptPrefix "psdevops_manage_nodeapi_"

                    if ($exitCode -ne 0) {
                        throw "Configuración de $processManager falló con código $exitCode"
                    }

                    # ─── 10. Healthcheck ─────────────────────
                    $healthUrl = "http://127.0.0.1:$port$apiBasePath/health"
                    Write-Host "  Verificando: $healthUrl" -ForegroundColor Cyan

                    $healthScript = Get-BashScript -ScriptName "Healthcheck.sh" -Placeholders @{
                        '__HEALTHURL__' = $healthUrl
                    }

                    $exitCode = Invoke-RemoteScript -ScriptContent $healthScript `
                                                    -User $user -IP $ip -Port $sshPort `
                                                    -KeyPath $privateKeyPath `
                                                    -ScriptPrefix "psdevops_health_nodeapi_"

                    if ($exitCode -ne 0) {
                        $logCmd = if ($processManager -eq 'pm2') { 
                            "pm2 logs $appName --lines 50" 
                        } else { 
                            "journalctl -u $appName --no-pager -n 50" 
                        }
                        throw "Healthcheck falló en $healthUrl. Revise logs con: ssh $user@$ip '$logCmd'"
                    }

                    # ─── Éxito ───────────────────────────────
                    Write-Host ""
                    Write-Host "══════════════════════════════════════════════════" -ForegroundColor Green
                    Write-Host "  Deploy completado: $appName $release" -ForegroundColor Green
                    Write-Host "══════════════════════════════════════════════════" -ForegroundColor Green
                    Write-Host "  Servidor:  $ip" -ForegroundColor White
                    Write-Host "  Release:   $releaseDir" -ForegroundColor White
                    Write-Host "  Proceso:   $processManager" -ForegroundColor White
                    Write-Host "  Health:    $healthUrl" -ForegroundColor White
                    Write-Host "══════════════════════════════════════════════════" -ForegroundColor Green
                    Write-Host ""

                } finally {
                    # Limpiar archivos temporales locales
                    Remove-Item -LiteralPath $localTarball -ErrorAction SilentlyContinue
                    if ($tmpEnvPath) { Remove-Item -LiteralPath $tmpEnvPath -ErrorAction SilentlyContinue }
                }
            }

            # ═══════════════════════════════════════════════════
            # DEPLOY REPORT — Reporte pre-deploy (dry-run)
            # ═══════════════════════════════════════════════════
            'Plan' {
                $cwd = (Get-Location).Path
                Ensure-YamlModule

                # ─── 1. Cargar helpers ───────────────────────
                . "$PSScriptRoot/../Private/PublishHelpers.ps1"
                . "$PSScriptRoot/../Private/Read-SSHConfig.ps1"

                # ─── 0. Validaciones ─────────────────────────
                $packageJsonPath = Join-Path $cwd "package.json"
                $configResolution = Resolve-PublishConfigPath -ProjectRoot $cwd
                $publishYamlPath = $configResolution.Path
                # Env file que selecciona el entorno (ADR 0004): default .env, -EnvFile lo pisa.
                $envProdPath = if ([System.IO.Path]::IsPathRooted($EnvFile)) { $EnvFile } else { Join-Path $cwd $EnvFile }

                if (-not (Test-Path $packageJsonPath)) {
                    throw "No se encontró package.json en $cwd."
                }
                if (-not $publishYamlPath) {
                    throw "No se encontró publish.yaml. Ejecute 'Publish-NodeApi -Init' primero."
                }
                if ($configResolution.IsLegacy) {
                    Write-Host "  Aviso: 'deploy.yaml' está deprecado; renómbrelo a 'publish.yaml'." -ForegroundColor Yellow
                }
                if (-not (Test-Path $envProdPath)) {
                    throw "No se encontró el env file '$EnvFile' en $cwd. Ejecute 'Publish-NodeApi -Init' o especifique -EnvFile <archivo>."
                }

                # ─── 2. Leer configuración ───────────────────
                $packageJson = Get-Content $packageJsonPath -Raw | ConvertFrom-Json
                $appName = $packageJson.name
                $appVersion = ($packageJson.version -split '\+')[0]

                $deployConfig = Get-Content $publishYamlPath -Raw | ConvertFrom-Yaml

                # Runtime + release id (ADR 0003): mismo cálculo que -Apply.
                $runtime = Resolve-NodeRuntime -PublishConfig $deployConfig
                $entrypoint = $runtime.Entrypoint
                $gitSha = (& git -C $cwd rev-parse --short HEAD 2>$null)
                if ($LASTEXITCODE -eq 0 -and $gitSha) {
                    if (-not $runtime.Build -and -not (Test-CleanWorktree -Path $cwd)) { $gitSha = "$gitSha-dirty" }
                    $release = Get-ReleaseId -Version $appVersion -ShortSha $gitSha
                } else {
                    $release = "v$appVersion"
                }

                # env file (PORT + destino). ADR 0004: destino desde MACSS_DEPLOY_SERVER.
                $envConfig = Read-DotEnv -Path $envProdPath -DefaultPort 8080
                $port = $envConfig.Port
                $server = Resolve-DeployTarget -EnvVars $envConfig.Env -EnvFilePath $EnvFile

                $processManager = if ($deployConfig.runtime -and $deployConfig.runtime.processManager) {
                    $deployConfig.runtime.processManager
                } else { 'systemd' }

                $apiBasePath = Resolve-ApiBasePath -PackageJson $packageJson -PublishConfig $deployConfig

                # ─── 3. Validaciones de config ───────────────
                if ($server -eq 'your-ssh-alias') {
                    throw "publish.yaml contiene el valor de ejemplo 'your-ssh-alias'. Cambie 'server' por el alias SSH real de su servidor."
                }

                # ─── 4. SSH Config ───────────────────────────
                $sshConfig = Read-SSHConfig -HostAlias $server
                $user = $sshConfig.User
                $ip = $sshConfig.HostName
                $sshPort = $sshConfig.Port
                $privateKeyPath = $sshConfig.IdentityFile

                $remoteRoot = "/opt/app"

                Write-Host "  Modo: SOLO REPORTE (no se realizarán cambios)" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  ─── Configuración local ───" -ForegroundColor Cyan
                Write-Host "  Proyecto:   $appName" -ForegroundColor White
                Write-Host "  Release:    $release" -ForegroundColor White
                Write-Host "  Runtime:    $(if ($runtime.Build) { 'build (TypeScript)' } else { 'no-build (source)' }) → $entrypoint" -ForegroundColor White
                Write-Host "  Servidor:   $server ($ip)" -ForegroundColor White
                Write-Host "  Proceso:    $processManager" -ForegroundColor White
                Write-Host "  Puerto:     $port" -ForegroundColor White
                if ($apiBasePath) {
                    Write-Host "  BasePath:   $apiBasePath (healthcheck: $apiBasePath/health)" -ForegroundColor White
                }
                Write-Host ""

                # ─── 5. Consultar estado del servidor ────────
                Write-Host "  ─── Estado del servidor ───" -ForegroundColor Cyan

                # Chequeo de sharedPaths (estado por path) inyectado en el reporte remoto.
                # Mismo criterio de "usable" que Install-NodeApi.sh (existe + no vacío).
                $sharedDirPlan = "$remoteRoot/$appName/shared"
                $sharedCheckBlock = ""
                foreach ($sp in @($runtime.SharedPaths)) {
                    $sharedCheckBlock += @"

if [ ! -e "$sharedDirPlan/$sp" ]; then echo "SHARED:${sp}:missing"
elif [ -f "$sharedDirPlan/$sp" ]; then { [ -s "$sharedDirPlan/$sp" ] && echo "SHARED:${sp}:ok"; } || echo "SHARED:${sp}:empty"
elif [ -n "`$(find "$sharedDirPlan/$sp" -type f -size +0c -print -quit 2>/dev/null)" ]; then echo "SHARED:${sp}:ok"
else echo "SHARED:${sp}:empty"; fi
"@
                }

                $reportScript = @"
#!/bin/bash
# Versión actual (symlink current)
if [ -L "$remoteRoot/$appName/current" ]; then
    CURRENT=`$(readlink "$remoteRoot/$appName/current" | xargs basename)
    echo "CURRENT:`$CURRENT"
else
    echo "CURRENT:none"
fi

# Release destino ya existe?
if [ -d "$remoteRoot/$appName/releases/$release" ]; then
    echo "RELEASE:exists"
else
    echo "RELEASE:new"
fi

# Estado del servicio
if [ "$processManager" = "systemd" ]; then
    if systemctl is-active --quiet $appName 2>/dev/null; then
        echo "SERVICE:running"
    elif systemctl is-enabled --quiet $appName 2>/dev/null; then
        echo "SERVICE:stopped"
    else
        echo "SERVICE:not-configured"
    fi
else
    if pm2 describe $appName >/dev/null 2>&1; then
        STATUS=`$(pm2 describe $appName 2>/dev/null | grep status | head -1 | awk '{print `$4}')
        echo "SERVICE:`$STATUS"
    else
        echo "SERVICE:not-configured"
    fi
fi
$sharedCheckBlock
"@

                $tmpLocal = New-UnixTempFile -Content $reportScript -Prefix "psdevops_report_nodeapi_"
                try {
                    $remoteName = [IO.Path]::GetFileName($tmpLocal)
                    $remotePath = "/tmp/$remoteName"

                    & scp -i $privateKeyPath -P $sshPort $tmpLocal "$($user)@$($ip):$remotePath" 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Error al conectar con el servidor (scp exit: $LASTEXITCODE)" }

                    $remoteCmd = "bash $remotePath ; rc=`$?; rm -f $remotePath; exit `$rc"
                    $output = & ssh -i $privateKeyPath -p $sshPort "$($user)@$($ip)" $remoteCmd 2>&1
                } finally {
                    Remove-Item -LiteralPath $tmpLocal -ErrorAction SilentlyContinue
                }

                # Parsear salida
                $currentVersion = 'desconocido'
                $releaseStatus = 'desconocido'
                $serviceStatus = 'desconocido'

                $sharedStatuses = @{}
                foreach ($line in $output) {
                    if ($line -match '^CURRENT:(.+)$') { $currentVersion = $Matches[1] }
                    if ($line -match '^RELEASE:(.+)$') { $releaseStatus = $Matches[1] }
                    if ($line -match '^SERVICE:(.+)$') { $serviceStatus = $Matches[1] }
                    if ($line -match '^SHARED:(.+):(missing|empty|ok)$') { $sharedStatuses[$Matches[1]] = $Matches[2] }
                }

                if ($currentVersion -eq 'none') {
                    Write-Host "  Current:    (primer deploy)" -ForegroundColor Yellow
                } else {
                    Write-Host "  Current:    $currentVersion" -ForegroundColor White
                }

                if ($releaseStatus -eq 'exists') {
                    Write-Host "  Release:    $release ya existe (se sobreescribirá)" -ForegroundColor Yellow
                } else {
                    Write-Host "  Release:    $release (nueva)" -ForegroundColor Green
                }

                if ($serviceStatus -eq 'running') {
                    Write-Host "  Servicio:   $processManager activo (se reiniciará)" -ForegroundColor White
                } elseif ($serviceStatus -eq 'not-configured') {
                    Write-Host "  Servicio:   se creará ($processManager)" -ForegroundColor Green
                } else {
                    Write-Host "  Servicio:   $serviceStatus" -ForegroundColor Yellow
                }

                # Estado de sharedPaths (para saber si hay que correr -PushShared antes de -Apply)
                if (@($runtime.SharedPaths).Count -gt 0) {
                    Write-Host ""
                    Write-Host "  ─── sharedPaths (runtime.sharedPaths) ───" -ForegroundColor Cyan
                    foreach ($sp in @($runtime.SharedPaths)) {
                        switch ($sharedStatuses[$sp]) {
                            'ok'      { Write-Host "  ${sp}: OK (presente en shared/)" -ForegroundColor Green }
                            'empty'   { Write-Host "  ${sp}: VACÍO -> corre 'Publish-NodeApi -PushShared'" -ForegroundColor Red }
                            'missing' { Write-Host "  ${sp}: FALTA -> corre 'Publish-NodeApi -PushShared' antes de -Apply" -ForegroundColor Red }
                            default   { Write-Host "  ${sp}: (estado desconocido)" -ForegroundColor Yellow }
                        }
                    }
                }

                # ─── 6. Acciones que realizará -Apply ──────
                # Lista derivada de la config real (no genérica): el paso de build y el
                # archivo de entorno reflejan runtime.build y -EnvFile efectivamente resueltos.
                $acciones = @()
                if ($runtime.Build) {
                    $acciones += "Compilar TypeScript localmente (npm ci + tsc)"
                    $acciones += "Empaquetar dist/ + node_modules(prod) + package.json en tar.gz"
                } else {
                    $acciones += "Sin build (runtime.build=false): empaquetar el fuente desde git HEAD + node_modules(prod) en tar.gz"
                }
                $acciones += "Subir tar.gz + '$EnvFile' (se instala como .env en el release) a ${ip}:/tmp/"
                $acciones += "Instalar en ${remoteRoot}/${appName}/releases/${release}/"
                if (@($runtime.SharedPaths).Count -gt 0) {
                    $acciones += "Enlazar sharedPaths [$(@($runtime.SharedPaths) -join ', ')] desde shared/ (falla si no están staged)"
                }
                $acciones += "Actualizar symlink current -> $release"
                $acciones += "Configurar/reiniciar servicio ($processManager)"
                $acciones += "Healthcheck en http://127.0.0.1:$port$apiBasePath/health"

                Write-Host ""
                Write-Host "  ─── Acciones que realizará -Apply ───" -ForegroundColor Cyan
                for ($i = 0; $i -lt $acciones.Count; $i++) {
                    Write-Host "  $($i + 1). $($acciones[$i])" -ForegroundColor White
                }
                Write-Host ""
            }

            # ═══════════════════════════════════════════════════
            # PUSH SHARED — subir/reemplazar (limpio) los sharedPaths en el servidor
            # ═══════════════════════════════════════════════════
            'PushShared' {
                $cwd = (Get-Location).Path
                Ensure-YamlModule

                . "$PSScriptRoot/../Private/PublishHelpers.ps1"
                . "$PSScriptRoot/../Private/Read-SSHConfig.ps1"

                # ─── Config ──────────────────────────────────
                $configResolution = Resolve-PublishConfigPath -ProjectRoot $cwd
                $publishYamlPath = $configResolution.Path
                $packageJsonPath = Join-Path $cwd "package.json"
                $envProdPath = if ([System.IO.Path]::IsPathRooted($EnvFile)) { $EnvFile } else { Join-Path $cwd $EnvFile }

                if (-not $publishYamlPath) { throw "No se encontró publish.yaml. Ejecute 'Publish-NodeApi -Init' primero." }
                if (-not (Test-Path $packageJsonPath)) { throw "No se encontró package.json en $cwd." }
                if (-not (Test-Path $envProdPath)) { throw "No se encontró el env file '$EnvFile' en $cwd." }

                $deployConfig = (Get-Content $publishYamlPath -Raw) | ConvertFrom-Yaml
                $pkg = Get-Content $packageJsonPath -Raw | ConvertFrom-Json
                $appName = $pkg.name

                $runtime = Resolve-NodeRuntime -PublishConfig $deployConfig
                $sharedList = @($runtime.SharedPaths)
                if ($sharedList.Count -eq 0) {
                    throw "publish.yaml no declara runtime.sharedPaths; no hay nada que subir."
                }

                # Destino (mismo mecanismo que -Apply): MACSS_DEPLOY_SERVER del env elegido.
                $envConfig = Read-DotEnv -Path $envProdPath -DefaultPort 8080
                $server = Resolve-DeployTarget -EnvVars $envConfig.Env -EnvFilePath $EnvFile
                if (-not $server) { throw "No se encontró 'MACSS_DEPLOY_SERVER' en '$EnvFile'." }

                $sshConfig = Read-SSHConfig -HostAlias $server
                $user = $sshConfig.User
                $ip = $sshConfig.HostName
                $sshPort = $sshConfig.Port
                $privateKeyPath = $sshConfig.IdentityFile

                $remoteRoot = "/opt/app"
                $sharedDir = "$remoteRoot/$appName/shared"

                # ─── Validación local: cada sharedPath debe existir y no estar vacío ───
                foreach ($p in $sharedList) {
                    $localPath = Join-Path $cwd $p
                    if (-not (Test-Path $localPath)) {
                        throw "El sharedPath '$p' no existe localmente en $cwd. Nada que subir."
                    }
                    $nonEmpty = @(Get-ChildItem -LiteralPath $localPath -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 })
                    if ($nonEmpty.Count -eq 0) {
                        throw "El sharedPath '$p' está vacío localmente (sin archivos con contenido). No se sube."
                    }
                }

                # ─── Probe remoto (read-only): crear vs reemplazar por path ───
                $probeLines = $sharedList | ForEach-Object { "if [ -e '$sharedDir/$_' ]; then echo 'EXISTS:$_'; else echo 'NEW:$_'; fi" }
                $probeScript = "#!/bin/bash`n" + ($probeLines -join "`n") + "`n"
                $tmpProbe = New-UnixTempFile -Content $probeScript -Prefix "psdevops_probe_shared_"
                try {
                    $remoteProbe = "/tmp/$([IO.Path]::GetFileName($tmpProbe))"
                    & scp -i $privateKeyPath -P $sshPort $tmpProbe "$($user)@$($ip):$remoteProbe" 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Error al conectar con el servidor (scp exit: $LASTEXITCODE)" }
                    $probeOut = & ssh -i $privateKeyPath -p $sshPort "$($user)@$($ip)" "bash $remoteProbe; rm -f $remoteProbe" 2>&1
                } finally {
                    Remove-Item -LiteralPath $tmpProbe -ErrorAction SilentlyContinue
                }

                # ─── Reporte (tipo plan) ─────────────────────
                Write-Host "  Proyecto:   $appName" -ForegroundColor Cyan
                Write-Host "  Servidor:   $server ($ip)" -ForegroundColor Cyan
                Write-Host "  Shared dir: $sharedDir" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  ─── sharedPaths a subir (reemplazo limpio) ───" -ForegroundColor Cyan
                foreach ($line in $probeOut) {
                    if ($line -match '^EXISTS:(.+)$') { Write-Host "  $($Matches[1]): existe -> REEMPLAZO LIMPIO" -ForegroundColor Yellow }
                    elseif ($line -match '^NEW:(.+)$') { Write-Host "  $($Matches[1]): nuevo  -> CREAR" -ForegroundColor Green }
                }
                Write-Host ""

                # ─── Confirmación (ADR 0002) ─────────────────
                if (-not (Confirm-MacssChange -Action "Push shared [$($sharedList -join ', ')] a '$server' ($ip), reemplazo limpio" -AutoApprove:$AutoApprove)) {
                    Write-Host "  PushShared cancelado." -ForegroundColor Yellow
                    return
                }

                # ─── Empaquetar el contenido local de los sharedPaths ───
                $tarballName = "${appName}-shared.tar.gz"
                $localTarball = Join-Path $env:TEMP $tarballName
                $remoteTarball = "/tmp/$tarballName"
                Remove-Item -LiteralPath $localTarball -ErrorAction SilentlyContinue
                $tarCmd = "tar.exe -czf `"$localTarball`" -C `"$cwd`" $($sharedList -join ' ')"
                Invoke-Expression $tarCmd 2>&1 | Out-Null
                if (-not (Test-Path $localTarball)) { throw "Error al empaquetar los sharedPaths." }

                try {
                    Write-Host "  Subiendo shared a $ip..." -ForegroundColor Cyan
                    & scp -i $privateKeyPath -P $sshPort $localTarball "$($user)@$($ip):$remoteTarball" 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Error al subir el tarball de shared (scp exit: $LASTEXITCODE)" }

                    $useSudo = if ($deployConfig.runtime -and ($null -ne $deployConfig.runtime.useSudo)) {
                        [bool]$deployConfig.runtime.useSudo
                    } else { $false }

                    $pushScript = Get-BashScript -ScriptName "Push-Shared.sh" -Placeholders @{
                        '__NAME__'         = $appName
                        '__REMOTE_ROOT__'  = $remoteRoot
                        '__SHARED_PATHS__' = ($sharedList -join ' ')
                        '__USE_SUDO__'     = ($(if ($useSudo) { '1' } else { '0' }))
                    }

                    $exitCode = Invoke-RemoteScript -ScriptContent $pushScript `
                                                    -User $user -IP $ip -Port $sshPort `
                                                    -KeyPath $privateKeyPath `
                                                    -ScriptPrefix "psdevops_push_shared_"
                    if ($exitCode -ne 0) { throw "Push-Shared.sh falló con código $exitCode." }

                    Write-Host ""
                    Write-Host "  Shared subido a $server ($ip): [$($sharedList -join ', ')]" -ForegroundColor Green
                    Write-Host ""
                } finally {
                    Remove-Item -LiteralPath $localTarball -ErrorAction SilentlyContinue
                }
            }
        }
    }
}
