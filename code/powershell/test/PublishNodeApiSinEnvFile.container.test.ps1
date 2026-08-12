<#
.SYNOPSIS
Publish-NodeApi -Plan sin env file local, contra un servidor SSH REAL (issues #75, #79, #83).

.DESCRIPTION
Es la prueba de que la API se puede desplegar desde CI. Un runner no tiene env file --está
gitignoreado, así que tras `actions/checkout` no existe-- y hasta ahora el cmdlet moría en la
primera línea útil. Tres piezas tenían que encajar para levantarlo:

  #75  el destino sale de la variable de entorno, con precedencia dotenv
  #79  la configuración de runtime vive en shared/.env del servidor
  #83  el puerto sale de esa misma configuración, no del archivo local

Cada una está probada por separado en Pester. Ninguna de esas pruebas puede decir si el cmdlet
COMPLETO corre sin el archivo, que es lo único que importa aquí. Por eso esto ejecuta el cmdlet
de verdad contra un sshd real, con un ~/.ssh/config falso y sin ningún .env en el proyecto.

Escenarios sobre el mismo servidor:

  A. Sin archivo local          -> el plan corre, y el puerto sale del servidor (3050)
  B. Archivo local que discrepa -> bloqueante que nombra los dos valores
  C. Clave que falta en el servidor -> bloqueante del contrato

.NOTES
Requiere: docker, ssh, scp, ssh-keygen. Usa el puerto host 22023.

Se sustituye USERPROFILE por un directorio temporal: Read-SSHConfig resuelve ~/.ssh/config
desde ahí, y así el test declara su propio alias sin tocar el del operador. Se restaura en el
finally.
#>
[CmdletBinding()]
param(
    [int]$SshHostPort = 22023
)

$ErrorActionPreference = 'Stop'

$CONTAINER = 'macss-nodeapi-sinenv-test'
$IMG = 'debian:bookworm-slim'
$APP = 'demoapi'
$PUERTO_SERVIDOR = 3050
$HOSTKEY = "[127.0.0.1]:$SshHostPort"

$workDir = Join-Path ([IO.Path]::GetTempPath()) "nodeapi-sinenv-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$keyPath = Join-Path $workDir 'id_ed25519'
$homeFalso = Join-Path $workDir 'home'
$proyecto = Join-Path $workDir 'proyecto'

$script:failures = 0
function Fail($msg) { Write-Host "  FALLO: $msg" -ForegroundColor Red; $script:failures++ }
function Pass($msg) { Write-Host "  ok: $msg" -ForegroundColor Green }

function Invoke-InContainer([string]$Script) {
    # Saltos a LF: en Windows una here-string produce CRLF y bash toma el \r como parte del
    # último argumento de cada línea.
    $lf = ($Script -replace "`r`n", "`n") -replace "`r", "`n"
    docker exec $CONTAINER bash -c $lf
    if ($LASTEXITCODE -ne 0) { throw "docker exec falló (exit $LASTEXITCODE): $lf" }
}

# Ejecuta el cmdlet y devuelve TODO lo que dijo, haya terminado bien o no: en este test el
# mensaje importa tanto como el resultado.
function Invoke-Plan {
    $salida = & {
        try { Publish-NodeApi -Plan *>&1 } catch { "EXCEPCION: $($_.Exception.Message)" }
    }
    return (@($salida) | ForEach-Object { "$_" }) -join "`n"
}

foreach ($tool in 'docker', 'ssh', 'scp', 'ssh-keygen') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Falta '$tool' en el PATH." }
}

$userProfilePrevio = $env:USERPROFILE
$aliasPrevio = $env:MACSS_DEPLOY_SSH_ALIAS
$cwdPrevio = (Get-Location).Path

try {
    New-Item -ItemType Directory -Path $workDir, $homeFalso, $proyecto -Force | Out-Null

    # ── 1. Servidor SSH ────────────────────────────────────────────────────
    docker rm -f $CONTAINER 2>$null | Out-Null
    Write-Host "==> Arrancando servidor SSH ($IMG) en 127.0.0.1:$SshHostPort..." -ForegroundColor Cyan
    docker run -d --name $CONTAINER -p "${SshHostPort}:22" $IMG sleep infinity | Out-Null
    Invoke-InContainer 'apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null'

    & ssh-keygen -t ed25519 -N '' -f $keyPath -q
    if (-not (Test-Path "$keyPath.pub")) { throw 'No se generó el par de claves.' }

    Invoke-InContainer 'mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh'
    docker cp "$keyPath.pub" "${CONTAINER}:/root/.ssh/authorized_keys" | Out-Null
    Invoke-InContainer 'chmod 600 /root/.ssh/authorized_keys && chown root:root /root/.ssh/authorized_keys'
    docker exec -d $CONTAINER /usr/sbin/sshd -D
    Start-Sleep -Seconds 2

    $hostPub = docker exec $CONTAINER cat /etc/ssh/ssh_host_ed25519_key.pub
    if ($LASTEXITCODE -ne 0 -or -not $hostPub) { throw 'No se pudo leer la host key del contenedor.' }
    $hostParts = ($hostPub -split '\s+')
    $knownHosts = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh/known_hosts'
    New-Item -ItemType Directory -Path (Split-Path $knownHosts) -Force | Out-Null
    Add-Content -Path $knownHosts -Value "$HOSTKEY $($hostParts[0]) $($hostParts[1])"

    $hello = & ssh -i $keyPath -p $SshHostPort -o BatchMode=yes root@127.0.0.1 'echo READY' 2>&1
    if ($hello -notmatch 'READY') { throw "SSH al contenedor no funciona: $hello" }
    Write-Host "    sshd listo y autenticando por clave." -ForegroundColor Green

    # ── 2. El ~/.ssh/config que el cmdlet va a leer ────────────────────────
    New-Item -ItemType Directory -Path (Join-Path $homeFalso '.ssh') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $homeFalso '.ssh/config') -Value @(
        "Host contenedor"
        "    HostName 127.0.0.1"
        "    User root"
        "    Port $SshHostPort"
        "    IdentityFile $keyPath"
    )
    $env:USERPROFILE = $homeFalso

    # ── 3. La configuración de runtime, en el servidor ─────────────────────
    Invoke-InContainer @"
mkdir -p /opt/app/$APP/shared
cat > /opt/app/$APP/shared/.env <<'EOF'
PORT=$PUERTO_SERVIDOR
DB_HOST=interno
JWT_SECRET=secreto-del-servidor
EOF
"@

    # ── 4. El proyecto: SIN .env, como tras un checkout ────────────────────
    Set-Content -LiteralPath (Join-Path $proyecto 'package.json') -Value "{`"name`":`"$APP`",`"version`":`"1.4.0`"}"
    Set-Content -LiteralPath (Join-Path $proyecto 'publish.yaml') -Value @(
        'runtime:'
        '  build: false'
        '  entrypoint: server.js'
        '  processManager: pm2'
        '  sharedPaths:'
        '    - .env'
    )
    Set-Content -LiteralPath (Join-Path $proyecto '.env.example') -Value @('PORT=', 'DB_HOST=', 'JWT_SECRET=')

    Import-Module "$PSScriptRoot\..\macss-devops.psd1" -Force
    Set-Location $proyecto
    $env:MACSS_DEPLOY_SSH_ALIAS = 'contenedor'

    # ── A. Sin archivo local ───────────────────────────────────────────────
    Write-Host "==> A. Sin env file, con el destino en el entorno" -ForegroundColor Cyan
    $salidaA = Invoke-Plan

    if ($salidaA -match 'No se encontró el env file') { Fail "A/el cmdlet sigue exigiendo el env file:`n$salidaA" }
    else { Pass 'A/no exige el env file' }

    if ($salidaA -match 'variable de entorno') { Pass 'A/el destino salió del entorno, y lo dice' }
    else { Fail "A/no declaró el origen del destino:`n$salidaA" }

    # Lo que este issue existe para arreglar: el puerto es el del servidor, no un 8080 inventado.
    if ($salidaA -match "PORT=$PUERTO_SERVIDOR" -and $salidaA -match 'servidor') {
        Pass "A/el puerto salió de shared/.env ($PUERTO_SERVIDOR)"
    } else { Fail "A/el puerto no salió del servidor:`n$salidaA" }

    if ($salidaA -match 'EXCEPCION') { Fail "A/el plan no llegó a completarse:`n$salidaA" }
    else { Pass 'A/el plan corrió completo' }

    # El contrato se cumple: las tres claves del ejemplo están en el servidor.
    if ($salidaA -match 'OK: el servidor tiene las 3 clave') { Pass 'A/el contrato de .env.example se cumple' }
    else { Fail "A/el contrato no se evaluó como se esperaba:`n$salidaA" }

    # ── B. El archivo local declara otro puerto ────────────────────────────
    Write-Host "==> B. Un .env local que discrepa del servidor" -ForegroundColor Cyan
    Set-Content -LiteralPath (Join-Path $proyecto '.env') -Value @('PORT=8080', 'MACSS_DEPLOY_SSH_ALIAS=contenedor')
    $salidaB = Invoke-Plan

    if ($salidaB -match 'BLOQUEANTE' -and $salidaB -match '8080' -and $salidaB -match "$PUERTO_SERVIDOR") {
        Pass 'B/el desajuste de puerto bloquea y nombra los dos valores'
    } else { Fail "B/no detectó el desajuste de puerto:`n$salidaB" }

    Remove-Item -LiteralPath (Join-Path $proyecto '.env') -Force

    # ── C. Una clave que el servidor no tiene ──────────────────────────────
    Write-Host "==> C. Una variable nueva que el servidor no tiene" -ForegroundColor Cyan
    Add-Content -LiteralPath (Join-Path $proyecto '.env.example') -Value 'OTP_SERVICE_URL='
    $salidaC = Invoke-Plan

    if ($salidaC -match 'BLOQUEANTE' -and $salidaC -match 'OTP_SERVICE_URL') {
        Pass 'C/la clave ausente bloquea y se nombra'
    } else { Fail "C/no detectó la clave ausente:`n$salidaC" }
}
finally {
    Set-Location $cwdPrevio
    Write-Host "==> Limpieza..." -ForegroundColor DarkGray
    docker rm -f $CONTAINER 2>$null | Out-Null
    & ssh-keygen -R $HOSTKEY 2>$null | Out-Null
    if ($userProfilePrevio) { $env:USERPROFILE = $userProfilePrevio }
    if ($aliasPrevio) { $env:MACSS_DEPLOY_SSH_ALIAS = $aliasPrevio }
    else { Remove-Item Env:MACSS_DEPLOY_SSH_ALIAS -ErrorAction SilentlyContinue }
    if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue }
}

if ($script:failures -gt 0) {
    Write-Host "FALLARON $script:failures ASERCIONES" -ForegroundColor Red
    exit 1
}
Write-Host 'ALL NODEAPI SIN ENV FILE CONTAINER TESTS PASSED' -ForegroundColor Green
