<#
.SYNOPSIS
ADR 0009 REQ-5 — Test de contenedor del plan de Publish-FlutterWeb contra un servidor SSH REAL.

.DESCRIPTION
Los tests unitarios (FlutterWebPlan.Tests.ps1) cubren `ConvertTo-FlutterWebPlan`, la parte pura.
Aquí se ejercita la otra mitad — `Invoke-FlutterWebProbe`, el sondeo por scp+ssh — contra un
contenedor Linux con sshd real, para probar que el plan refleja el estado VERDADERO del servidor
y no una simulación. Tres escenarios sobre el mismo servidor, mutándolo entre uno y otro:

  A. Greenfield        -> Current '(primer deploy)', Release nueva, nginx se creará. 6 acciones.
  B. Con release+nginx -> Current v0.9.0, Release ya existe (warn), nginx no se toca. 5 acciones.
  C. Puerto ocupado    -> nginx 'PUERTO EN USO' con nivel 'error' => 1 bloqueante.

El escenario C es el que hace que `-Apply` aborte antes de compilar (guard de bloqueantes),
así que se comprueba de punta a punta: proceso real escuchando -> `ss` en el servidor ->
fila 'error' -> `Get-DeployPlanBlocker` devuelve 1.

También verifica REQ-3 sobre un plan real: `Save-DeployPlan` escribe el reporte y el
`.macss/.gitignore` que evita publicar alias e IPs del servidor.

Opt-in: no lo recoge la corrida Pester de CI (igual que los *.container.test.sh).

.NOTES
Requiere: docker, ssh, scp, ssh-keygen. Usa el puerto host 22022.

El sondeo llama a `scp`/`ssh` sin `-o StrictHostKeyChecking`, tal como en producción. Para que
la conexión no se quede esperando confirmación, el test registra la host key del contenedor en
known_hosts y la ELIMINA en el finally (`ssh-keygen -R`), dejando el archivo como estaba.

La host key se lee del propio contenedor (`/etc/ssh/ssh_host_ed25519_key.pub`) en vez de con
`ssh-keyscan`: el cliente OpenSSH de Windows no negocia el KEX sntrup761x25519 que ofrece el
sshd de Debian 12, así que keyscan falla ahí aunque `ssh`/`scp` conecten sin problema.
#>
[CmdletBinding()]
param(
    [int]$SshHostPort = 22022,
    [int]$AppPort = 4020
)

$ErrorActionPreference = 'Stop'

$CONTAINER = 'macss-flutterwebplan-test'
$IMG = 'debian:bookworm-slim'
$APP = 'pyme'
$RELEASE = 'v1.2.3'
$WEBROOT = '/var/www'
$HOSTKEY = "[127.0.0.1]:$SshHostPort"

$workDir = Join-Path ([IO.Path]::GetTempPath()) "fwplan-ctr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$keyPath = Join-Path $workDir 'id_ed25519'

$script:failures = 0

function Fail($msg) {
    Write-Host "  FAIL: $msg" -ForegroundColor Red
    $script:failures++
}
function Pass($msg) { Write-Host "  ok: $msg" -ForegroundColor Green }

function Assert-Equal($actual, $expected, $what) {
    if ($actual -eq $expected) { Pass "$what = '$actual'" }
    else { Fail "${what}: esperaba '$expected', obtuvo '$actual'" }
}

function Get-Row($Plan, [string]$Label) {
    return ConvertTo-DeployPlanRow $Plan.Sections['Estado del servidor'][$Label]
}

function Invoke-InContainer([string]$Script) {
    # Se normalizan los saltos de línea a LF. En Windows una here-string de PowerShell
    # produce CRLF, y bash toma el \r como parte del último argumento de cada línea: el
    # 'mkdir -p .../releases/v1.2.3\r' crea un directorio con el retorno de carro dentro,
    # y el 'ln -sfn' siguiente falla apuntando a una ruta que no existe.
    $lf = ($Script -replace "`r`n", "`n") -replace "`r", "`n"
    docker exec $CONTAINER bash -c $lf
    if ($LASTEXITCODE -ne 0) { throw "docker exec falló (exit $LASTEXITCODE): $lf" }
}

# ── Preflight ──────────────────────────────────────────────────────────────
foreach ($tool in 'docker', 'ssh', 'scp', 'ssh-keygen') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Falta '$tool' en el PATH." }
}

# Las funciones bajo prueba son Private (no exportadas por el módulo): se cargan por dot-source.
. "$PSScriptRoot/../Private/PublishHelpers.ps1"
. "$PSScriptRoot/../Private/DeployPlan.ps1"
. "$PSScriptRoot/../Private/FlutterWebPlan.ps1"

try {
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    # ── 1. Servidor SSH en contenedor ──────────────────────────────────────
    docker rm -f $CONTAINER 2>$null | Out-Null
    Write-Host "==> Arrancando servidor SSH ($IMG) en 127.0.0.1:$SshHostPort..." -ForegroundColor Cyan
    docker run -d --name $CONTAINER -p "${SshHostPort}:22" $IMG sleep infinity | Out-Null

    Invoke-InContainer 'apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server iproute2 netcat-openbsd >/dev/null'

    # -N '' debe ser una cadena REALMENTE vacía: con -N '""' PowerShell pasa dos comillas
    # literales como passphrase y la clave queda cifrada; ssh no puede firmar con BatchMode
    # y el fallo aparece como un confuso "Permission denied (publickey)".
    & ssh-keygen -t ed25519 -N '' -f $keyPath -q
    if (-not (Test-Path "$keyPath.pub")) { throw 'No se generó el par de claves.' }
    & ssh-keygen -y -P '' -f $keyPath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'La clave generada pide passphrase; el test no podría autenticar.' }

    Invoke-InContainer 'mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh'
    docker cp "$keyPath.pub" "${CONTAINER}:/root/.ssh/authorized_keys" | Out-Null
    Invoke-InContainer 'chmod 600 /root/.ssh/authorized_keys && chown root:root /root/.ssh/authorized_keys'
    docker exec -d $CONTAINER /usr/sbin/sshd -D
    Start-Sleep -Seconds 2

    # Registra la host key para que scp/ssh (sin -o StrictHostKeyChecking) no pregunten.
    # Se lee del contenedor, no con ssh-keyscan (ver .NOTES: KEX incompatible en Windows).
    $hostPub = docker exec $CONTAINER cat /etc/ssh/ssh_host_ed25519_key.pub
    if ($LASTEXITCODE -ne 0 -or -not $hostPub) { throw 'No se pudo leer la host key del contenedor.' }
    $hostParts = ($hostPub -split '\s+')
    $knownHosts = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh/known_hosts'
    New-Item -ItemType Directory -Path (Split-Path $knownHosts) -Force | Out-Null
    Add-Content -Path $knownHosts -Value "$HOSTKEY $($hostParts[0]) $($hostParts[1])"

    # Comprueba que el login por clave funciona antes de sondear, para que un fallo de
    # infraestructura no se confunda con un fallo del plan.
    $hello = & ssh -i $keyPath -p $SshHostPort -o BatchMode=yes root@127.0.0.1 'echo READY' 2>&1
    if ($hello -notmatch 'READY') { throw "SSH al contenedor no funciona: $hello" }
    Write-Host "    sshd listo y autenticando por clave." -ForegroundColor Green

    $probeArgs = @{
        AppName        = $APP
        Release        = $RELEASE
        Server         = 'contenedor'
        User           = 'root'
        IP             = '127.0.0.1'
        SshPort        = $SshHostPort
        PrivateKeyPath = $keyPath
        Port           = $AppPort
        RemoteWebRoot  = $WEBROOT
    }

    # ── 2. Escenario A: greenfield ─────────────────────────────────────────
    Write-Host "==> A. Servidor limpio (primer deploy)" -ForegroundColor Cyan
    $planA = Get-FlutterWebPlan @probeArgs

    Assert-Equal (Get-Row $planA 'Current').Text '(primer deploy)' 'A/Current.Text'
    Assert-Equal (Get-Row $planA 'Current').Level 'warn'           'A/Current.Level'
    Assert-Equal (Get-Row $planA 'Release').Text "$RELEASE (nueva)" 'A/Release.Text'
    Assert-Equal (Get-Row $planA 'Release').Level 'ok'             'A/Release.Level'
    Assert-Equal (Get-Row $planA 'Nginx').Level 'ok'               'A/Nginx.Level'
    Assert-Equal $planA.Actions.Count 6                            'A/acciones (incluye crear nginx)'
    Assert-Equal @(Get-DeployPlanBlocker -Plan $planA).Count 0      'A/bloqueantes'
    Assert-Equal $planA.Target 'contenedor (127.0.0.1)'            'A/Target'

    # REQ-3 sobre un plan real: reporte + .gitignore defensivo.
    $projectRoot = Join-Path $workDir 'proyecto'
    New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
    $reportPath = Save-DeployPlan -Plan $planA -ProjectRoot $projectRoot -Timestamp '2026-07-31T10:00:00Z'
    if (Test-Path $reportPath) { Pass "reporte escrito: $(Split-Path -Leaf $reportPath)" }
    else { Fail "no se escribió el reporte en $reportPath" }
    $reportBody = Get-Content $reportPath -Raw
    if ($reportBody -match '# Deploy plan — Publish-FlutterWeb') { Pass 'reporte tiene título' }
    else { Fail 'reporte sin título esperado' }
    if ($reportBody -match [regex]::Escape('(primer deploy)')) { Pass 'reporte refleja el estado sondeado' }
    else { Fail 'el reporte no refleja el estado real del servidor' }
    $gi = Join-Path $projectRoot '.macss/.gitignore'
    if ((Test-Path $gi) -and ((Get-Content $gi -Raw).Trim() -eq '*')) { Pass '.macss/.gitignore creado' }
    else { Fail '.macss/.gitignore ausente o con contenido inesperado' }

    # ── 3. Escenario B: release existente + nginx configurado ──────────────
    Write-Host "==> B. Release ya existe y nginx configurado" -ForegroundColor Cyan
    # El site DEBE declarar 'root .../current': es lo que hace que mover el symlink surta
    # efecto. El fixture solo ponía 'listen', sin root, y desde que un root que no apunta a
    # 'current' pasó a ser bloqueante —el despliegue silencioso detectado en 'micro'— eso
    # ya no describe un nginx bien configurado, sino justamente el caso roto.
    #
    # El escenario contrario ('root-mismatch') está cubierto por FlutterWebPlan.Tests.ps1;
    # aquí lo que se verifica es que una configuración correcta no genere bloqueantes.
    Invoke-InContainer @"
mkdir -p $WEBROOT/$APP/releases/$RELEASE $WEBROOT/$APP/releases/v0.9.0 /etc/nginx/sites-available
ln -sfn $WEBROOT/$APP/releases/v0.9.0 $WEBROOT/$APP/current
printf 'server {\n    listen $AppPort;\n    root $WEBROOT/$APP/current;\n}\n' > /etc/nginx/sites-available/$APP
"@
    $planB = Get-FlutterWebPlan @probeArgs

    Assert-Equal (Get-Row $planB 'Current').Text 'v0.9.0'  'B/Current.Text (symlink real)'
    Assert-Equal (Get-Row $planB 'Current').Level 'info'   'B/Current.Level'
    Assert-Equal (Get-Row $planB 'Release').Level 'warn'   'B/Release.Level (se sobreescribirá)'
    Assert-Equal (Get-Row $planB 'Nginx').Level 'info'     'B/Nginx.Level (config existe)'
    Assert-Equal $planB.Actions.Count 5                    'B/acciones (sin crear nginx)'
    Assert-Equal @(Get-DeployPlanBlocker -Plan $planB).Count 0 'B/bloqueantes'

    # ── 4. Escenario C: puerto ocupado => bloqueante ───────────────────────
    Write-Host "==> C. Sin config nginx y con el puerto $AppPort ocupado" -ForegroundColor Cyan
    Invoke-InContainer "rm -f /etc/nginx/sites-available/$APP"
    docker exec -d $CONTAINER bash -c "nc -l -k -p $AppPort >/dev/null 2>&1"
    Start-Sleep -Seconds 2

    # Confirma que el puerto está realmente escuchando antes de sondear (si no, el test
    # pasaría por el camino 'will-create' y no probaría nada).
    $listening = docker exec $CONTAINER bash -c "ss -tlnH sport = :$AppPort | grep -c ."
    if ([int]$listening -ge 1) { Pass "puerto $AppPort ocupado en el servidor" }
    else { Fail "no se pudo ocupar el puerto $AppPort; el escenario C no es válido" }

    $planC = Get-FlutterWebPlan @probeArgs

    Assert-Equal (Get-Row $planC 'Nginx').Level 'error' 'C/Nginx.Level'
    if ((Get-Row $planC 'Nginx').Text -match "PUERTO $AppPort EN USO") { Pass 'C/Nginx.Text nombra el puerto' }
    else { Fail "C/Nginx.Text inesperado: '$((Get-Row $planC 'Nginx').Text)'" }

    $blockers = @(Get-DeployPlanBlocker -Plan $planC)
    Assert-Equal $blockers.Count 1 'C/bloqueantes'
    if ($blockers.Count -eq 1 -and $blockers[0] -match '^Nginx: ') { Pass 'C/bloqueante etiquetado' }
    else { Fail "C/bloqueante inesperado: '$($blockers -join '; ')'" }

    # El marcador FAIL debe llegar al artefacto markdown, no solo al color de pantalla.
    $mdC = Format-DeployPlanMarkdown -Plan $planC
    if ($mdC -match 'FAIL PUERTO') { Pass 'C/reporte marca la fila como FAIL' }
    else { Fail 'C/el reporte no marca el bloqueante' }
}
finally {
    Write-Host "==> Limpieza..." -ForegroundColor DarkGray
    docker rm -f $CONTAINER 2>$null | Out-Null
    & ssh-keygen -R $HOSTKEY 2>$null | Out-Null
    if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) {
    Write-Host "FALLARON $script:failures ASERCIONES" -ForegroundColor Red
    exit 1
}
Write-Host 'ALL FLUTTERWEB PLAN CONTAINER TESTS PASSED' -ForegroundColor Green
