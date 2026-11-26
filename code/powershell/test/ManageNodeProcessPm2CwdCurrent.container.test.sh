#!/usr/bin/env bash
# Prueba de comportamiento de Manage-NodeProcess.sh (pm2 + ecosystem) en un contenedor limpio.
# Regresion de ccisnedev/devops#110: el app debe quedar registrado en pm2 con el symlink
# 'current', no con el directorio fisico del release.
#
# Sin cwd en el ecosystem, pm2 resuelve cwd y script contra process.cwd() del CLI, y Node lo
# entrega ya resuelto (getcwd). El deploy funciona igual (delete + start), pero el proceso queda
# anclado: tras cambiar 'current' a otro release, 'pm2 restart' y 'pm2 resurrect' siguen
# corriendo el release viejo, sin ningun aviso.
#
# Casos:
#   1. ecosystem.config.json CON cwd=current (lo que genera New-Pm2EcosystemJson -WorkingDir):
#      pm_cwd = .../current y un 'pm2 restart' tras el swap corre el release nuevo.
#   2. ecosystem.config.js escrito a mano SIN cwd: arranca (no rompe el deploy), pero el script
#      avisa que el app quedo anclado al release y como corregirlo.
#   3. ecosystem.config.json CON cwd=current: no emite el aviso.
#
# Uso: bash ManageNodeProcessPm2CwdCurrent.container.test.sh [ruta-a-Private/scripts]
# Requiere: docker.
set -euo pipefail

SCRIPTS_DIR="${1:-$(cd "$(dirname "$0")/../Private/scripts" && pwd)}"
IMG="node:22-bookworm-slim"
echo "Scripts dir: $SCRIPTS_DIR"

docker run --rm -v "$SCRIPTS_DIR:/scripts:ro" "$IMG" bash -euo pipefail -c '
  command -v curl >/dev/null 2>&1 || { apt-get update -qq >/dev/null && apt-get install -y -qq curl >/dev/null; }
  npm install -g pm2 >/dev/null 2>&1

  # Dos releases con el mismo server.js; solo cambia MARKER. La letra que responde el proceso
  # vivo dice desde que release corre.
  mk_app() {
    local app="$1" port="$2"
    for R in A B; do
      D="/opt/app/$app/releases/rel$R"
      mkdir -p "$D"
      printf "%s" "$R" > "$D/MARKER"
      cat > "$D/server.js" <<EOF
const fs = require("fs");
const marker = fs.readFileSync(require("path").join(__dirname, "MARKER"), "utf8").trim();
require("http").createServer((_, res) => res.end(marker)).listen($port, "127.0.0.1");
EOF
      : > "$D/.env"
    done
    ln -sfn "/opt/app/$app/releases/relA" "/opt/app/$app/current"
  }

  run_manage() { # $1 app  $2 port  -> salida del script en /tmp/<app>.out
    local app="$1" port="$2"
    sed -e "s/__NAME__/$app/g" -e "s/__PROCESS_MANAGER__/pm2/g" \
        -e "s#__ENTRY_PATH__#/opt/app/$app/current/server.js#g" \
        -e "s#__WORKING_DIR__#/opt/app/$app/current#g" \
        -e "s#__ENV_FILE__#/opt/app/$app/current/.env#g" \
        -e "s/__PORT__/$port/g" -e "s/__USER__/root/g" \
        /scripts/Manage-NodeProcess.sh > "/tmp/manage-$app.sh"
    bash "/tmp/manage-$app.sh" > "/tmp/$app.out" 2>&1 || { cat "/tmp/$app.out" >&2; return 1; }
  }

  pm_cwd() {
    pm2 jlist | node -e "for (const p of JSON.parse(require(\"fs\").readFileSync(0))) if (p.name === process.argv[1]) console.log(p.pm2_env.pm_cwd)" "$1"
  }

  # ── 1. JSON con cwd=current ──
  mk_app json 3991
  for R in A B; do
    echo "{\"apps\":[{\"name\":\"json\",\"script\":\"server.js\",\"cwd\":\"/opt/app/json/current\"}]}" \
      > "/opt/app/json/releases/rel$R/ecosystem.config.json"
  done
  run_manage json 3991
  [ "$(pm_cwd json)" = "/opt/app/json/current" ] || { echo "FAIL 1: pm_cwd=[$(pm_cwd json)], esperaba /opt/app/json/current" >&2; exit 1; }
  echo "  1a. ecosystem con cwd=current -> pm_cwd=current: PASS"
  ln -sfn /opt/app/json/releases/relB /opt/app/json/current
  pm2 restart json >/dev/null; sleep 2
  GOT="$(curl -s http://127.0.0.1:3991)"
  [ "$GOT" = "B" ] || { echo "FAIL 1b: tras swap + pm2 restart sirve [$GOT], esperaba B" >&2; exit 1; }
  echo "  1b. swap de current + pm2 restart -> corre el release nuevo: PASS"

  # ── 2. .js a mano sin cwd: arranca, pero avisa ──
  mk_app legacy 3992
  echo "module.exports = { apps: [{ name: \"legacy\", script: \"server.js\" }] };" \
    > /opt/app/legacy/releases/relA/ecosystem.config.js
  run_manage legacy 3992
  [ "$(curl -s http://127.0.0.1:3992)" = "A" ] || { echo "FAIL 2a: el app legacy no arranco" >&2; exit 1; }
  echo "  2a. ecosystem .js sin cwd -> el deploy no se rompe: PASS"
  grep -q "AVISO" /tmp/legacy.out && grep -q "releases/relA" /tmp/legacy.out && grep -q "cwd" /tmp/legacy.out \
    || { echo "FAIL 2b: no se emitio el aviso de app anclado al release. Salida:" >&2; cat /tmp/legacy.out >&2; exit 1; }
  echo "  2b. ecosystem .js sin cwd -> aviso de app anclado al release: PASS"

  # ── 3. JSON con cwd=current: sin aviso ──
  if grep -q "AVISO" /tmp/json.out; then echo "FAIL 3: aviso falso con cwd=current:" >&2; cat /tmp/json.out >&2; exit 1; fi
  echo "  3.  ecosystem con cwd=current -> sin aviso: PASS"

  pm2 delete all >/dev/null 2>&1 || true
'
echo "ALL PM2-CWD-CURRENT CONTAINER TESTS PASSED"
