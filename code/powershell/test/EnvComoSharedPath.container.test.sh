#!/usr/bin/env bash
# El .env como sharedPath, contra el instalador real (issue #79).
#
# Que se prueba aqui y no en Pester
# ---------------------------------
# Que el release termine leyendo la configuracion que vive en el servidor. Eso son symlinks,
# permisos y orden de pasos dentro de Install-NodeApi.sh: se cae de formas que ninguna prueba
# pura ve. En particular, el paso que copia el .env subido corre ANTES del que enlaza los
# sharedPaths, asi que el orden entre ambos decide cual gana.
#
# Y el sondeo de claves: la garantia de que los valores no salen del servidor tiene que
# cumplirse donde se lee el archivo, no en quien recibe la salida.
#
# Usage: bash EnvComoSharedPath.container.test.sh [path-to-Private/scripts]
# Requires: docker, pwsh.
set -euo pipefail

SCRIPTS_DIR="${1:-$(cd "$(dirname "$0")/../Private/scripts" && pwd)}"
IMG="node:22-bookworm-slim"
echo "Scripts dir: $SCRIPTS_DIR"

aWindows() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1" | tr '\\' '/'; else echo "$1"; fi; }
PRIV_POSIX="$(cd "$(dirname "$0")/../Private" && pwd)"
PRIV_WIN="$(aWindows "$PRIV_POSIX")"

# ── 1. El instalador: el .env se enlaza desde shared/, no se sube ─────────────────────
docker run --rm -v "$SCRIPTS_DIR:/scripts:ro" "$IMG" bash -euo pipefail -c '
  command -v useradd >/dev/null 2>&1 || { apt-get update -qq >/dev/null && apt-get install -y -qq passwd >/dev/null; }
  id -u deployer >/dev/null 2>&1 || useradd -m -s /bin/bash deployer
  mkdir -p /opt/app/tigre && chown -R deployer:deployer /opt/app

  mkdir -p /tmp/fake/node_modules
  echo "console.log(1)" > /tmp/fake/server.js
  echo "{\"name\":\"tigre\",\"version\":\"1.0.0\"}" > /tmp/fake/package.json
  tar -czf /tmp/tigre-v1.0.0.tar.gz -C /tmp/fake server.js node_modules package.json

  # La configuracion vive en el servidor, no la sube nadie. Es el punto entero del cambio:
  # NO se crea /tmp/tigre.env.production.
  mkdir -p /opt/app/tigre/shared
  printf "PORT=3090\nJWT_SECRET=secreto-del-servidor\n" > /opt/app/tigre/shared/.env
  chown -R deployer:deployer /opt/app/tigre

  sed -e "s/__NAME__/tigre/g" -e "s/__VERSION__/1.0.0/g" -e "s#__REMOTE_ROOT__#/opt/app#g" \
      -e "s/__NODE_VERSION__/>=18/g" -e "s/__USER__/deployer/g" -e "s/__USE_SUDO__/0/g" \
      -e "s#__ENTRYPOINT__#server.js#g" -e "s/__SHARED_PATHS__/.env/g" \
      /scripts/Install-NodeApi.sh > /tmp/install.sh
  chown deployer:deployer /tmp/install.sh /tmp/tigre-v1.0.0.tar.gz

  su deployer -c "bash /tmp/install.sh" >/tmp/out 2>&1 || { echo "  FALLO: la instalacion no termino bien"; cat /tmp/out; exit 1; }

  # El release lee la configuracion del servidor...
  test -L /opt/app/tigre/current/.env || { echo "  FALLO: current/.env no es un symlink a shared/"; ls -la /opt/app/tigre/current; exit 1; }
  grep -q "secreto-del-servidor" /opt/app/tigre/current/.env \
    || { echo "  FALLO: el release no lee la configuracion de shared/"; exit 1; }
  echo "  caso 1 (.env enlazado desde shared/, sin subir nada): PASS"

  # ...y no se avisa de un archivo ausente que no tenia por que estar.
  if grep -qi "No se encontro\|No se encontró" /tmp/out; then
    echo "  FALLO caso 2: avisa de un .env ausente que es un sharedPath"; cat /tmp/out; exit 1
  fi
  grep -qi "sharedPath, se enlaza" /tmp/out \
    || { echo "  FALLO caso 2: no dice que la configuracion viene de shared/"; cat /tmp/out; exit 1; }
  echo "  caso 2 (no confunde enlazado con ausente): PASS"
'

# ── 2. Sin el .env en shared/, el instalador no despliega a ciegas ────────────────────
docker run --rm -v "$SCRIPTS_DIR:/scripts:ro" "$IMG" bash -euo pipefail -c '
  command -v useradd >/dev/null 2>&1 || { apt-get update -qq >/dev/null && apt-get install -y -qq passwd >/dev/null; }
  id -u deployer >/dev/null 2>&1 || useradd -m -s /bin/bash deployer
  mkdir -p /opt/app/tigre/shared && chown -R deployer:deployer /opt/app

  mkdir -p /tmp/fake/node_modules
  echo "console.log(1)" > /tmp/fake/server.js
  echo "{\"name\":\"tigre\",\"version\":\"1.0.0\"}" > /tmp/fake/package.json
  tar -czf /tmp/tigre-v1.0.0.tar.gz -C /tmp/fake server.js node_modules package.json
  chown -R deployer:deployer /opt/app/tigre

  sed -e "s/__NAME__/tigre/g" -e "s/__VERSION__/1.0.0/g" -e "s#__REMOTE_ROOT__#/opt/app#g" \
      -e "s/__NODE_VERSION__/>=18/g" -e "s/__USER__/deployer/g" -e "s/__USE_SUDO__/0/g" \
      -e "s#__ENTRYPOINT__#server.js#g" -e "s/__SHARED_PATHS__/.env/g" \
      /scripts/Install-NodeApi.sh > /tmp/install.sh
  chown deployer:deployer /tmp/install.sh /tmp/tigre-v1.0.0.tar.gz

  set +e; su deployer -c "bash /tmp/install.sh" >/tmp/out 2>&1; rc=$?; set -e
  # El guard de sharedPaths ya existia y sigue aplicando: una app sin configuracion arranca
  # en crash-loop, y eso es peor que un despliegue que no empieza.
  [ "$rc" -eq 6 ] || { echo "  FALLO caso 3: esperaba exit 6, obtuvo $rc"; cat /tmp/out; exit 1; }
  grep -qi "PushShared" /tmp/out || { echo "  FALLO caso 3: no dice como poblarlo"; cat /tmp/out; exit 1; }
  echo "  caso 3 (sin shared/.env aborta y dice como poblarlo): PASS"
'

# ── 3. El sondeo de claves: nombres si, valores no ───────────────────────────────────
command -v pwsh >/dev/null 2>&1 || { echo "FALLO: pwsh no esta disponible"; exit 1; }
TMP="$(mktemp -d)"
TMP_WIN="$(aWindows "$TMP")"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/generar.ps1" <<'PS1'
param([string]$Priv, [string]$Out)
. (Join-Path $Priv 'EnvContract.ps1')
$s = "#!/bin/bash`n" + (New-RemoteEnvKeysScript -SharedEnvPath '/srv/.env')
[IO.File]::WriteAllText((Join-Path $Out 'sonda.sh'), ($s -replace "`r`n", "`n"),
                        (New-Object Text.UTF8Encoding $false))
PS1
pwsh -NoProfile -File "$TMP_WIN/generar.ps1" -Priv "$PRIV_WIN" -Out "$TMP_WIN"

cat > "$TMP/.env" <<'ENVF'
# un comentario
PORT=3090
export JWT_SECRET=secreto-que-no-debe-salir
  DB_URL = postgres://user:clave@host/db
NO_ES_UNA_CLAVE
ENVF

SALIDA="$(docker run --rm -v "$TMP_WIN:/srv:ro" "$IMG" bash /srv/sonda.sh)"

for k in PORT JWT_SECRET DB_URL; do
  echo "$SALIDA" | grep -q "ENVKEY:$k" || { echo "FALLO caso 4: no reporto la clave $k"; echo "$SALIDA"; exit 1; }
done
echo "$SALIDA" | grep -q "ENVKEY:NO_ES_UNA_CLAVE" && { echo "FALLO caso 4: reporto una linea que no es una asignacion"; exit 1; }
echo "  caso 4 (reporta los nombres de las claves): PASS"

# La garantia central: el valor no sale del servidor. Si esto falla, los secretos de produccion
# terminan en la salida del ssh y en cualquier log que la capture.
for v in secreto-que-no-debe-salir 3090 clave; do
  echo "$SALIDA" | grep -q "$v" && { echo "FALLO caso 5: un valor salio del servidor ($v)"; echo "$SALIDA"; exit 1; }
done
echo "  caso 5 (ningun valor sale del servidor): PASS"

rm -f "$TMP/.env"
SALIDA_SIN="$(docker run --rm -v "$TMP_WIN:/srv:ro" "$IMG" bash /srv/sonda.sh)"
echo "$SALIDA_SIN" | grep -q "ENVFILE:absent" || { echo "FALLO caso 6: no distingue el archivo ausente"; echo "$SALIDA_SIN"; exit 1; }
echo "  caso 6 (archivo ausente se declara como tal): PASS"

echo "EnvComoSharedPath: PASS"
