#!/usr/bin/env bash
# Behavioral test of Manage-NodeProcess.sh port-handoff guard in a clean Linux container.
#
# Regression it guards (incidente 2026-07-22): durante un cutover, un proceso AJENO (el micro
# git-clone/legacy) seguia reteniendo :3020 cuando el nuevo micro arrancaba. pm2 reintento el
# arranque 254 veces (EADDRINUSE) hasta que el puerto se libero -> ~1h de fotos caidas para los
# consumidores del file server (impulsa/tigre) que se sirven via ese :3020.
#
# El guard: antes de 'pm2 start', esperar (acotado) a que el PORT se libere; si un proceso ajeno
# lo retiene mas alla del timeout, FALLAR LIMPIO nombrando el puerto, en vez de crash-loopear.
#
# Assertion (falla contra el script SIN guard, que llamaria pm2 start -> EADDRINUSE):
#   con un holder ajeno en el PORT, el script sale != 0 con el mensaje del guard, rapido.
#
# Usage: bash ManageNodeProcessPortGuard.container.test.sh [path-to-Private/scripts]
# Requires: docker.
set -euo pipefail

SCRIPTS_DIR="${1:-$(cd "$(dirname "$0")/../Private/scripts" && pwd)}"
IMG="node:22-bookworm-slim"
echo "Scripts dir: $SCRIPTS_DIR"

docker run --rm -v "$SCRIPTS_DIR:/scripts:ro" "$IMG" bash -euo pipefail -c '
  npm install -g pm2 >/dev/null 2>&1

  PORT=3999
  # Holder AJENO: un proceso que NO es pm2 y retiene el puerto (simula el micro legacy/git-clone).
  node -e "require(\"http\").createServer((_,r)=>r.end(\"x\")).listen(3999,\"0.0.0.0\")" &
  HOLDER=$!
  sleep 1

  # Proyecto minimo para el Direct path (sin ecosystem.config.*).
  D="/opt/app/demo/current"; mkdir -p "$D"
  echo "const http=require(\"http\");http.createServer((_,r)=>r.end(\"ok\")).listen(process.env.PORT||3999);" > "$D/server.js"
  : > "$D/.env"

  sed -e "s/__NAME__/demo/g" -e "s/__PROCESS_MANAGER__/pm2/g" \
      -e "s#__ENTRY_PATH__#$D/server.js#g" -e "s#__WORKING_DIR__#$D#g" \
      -e "s#__ENV_FILE__#$D/.env#g" -e "s/__PORT__/$PORT/g" -e "s/__USER__/root/g" \
      /scripts/Manage-NodeProcess.sh > /tmp/manage.sh

  # Timeout corto para el test (env que el guard respeta).
  export PORT_FREE_TIMEOUT=3

  set +e
  OUT="$(timeout 40 bash /tmp/manage.sh 2>&1)"
  RC=$?
  set -e
  kill "$HOLDER" 2>/dev/null || true

  echo "---- salida del manage script (rc=$RC) ----"
  echo "$OUT" | tail -8

  if [ "$RC" -eq 0 ]; then
    echo "FAIL: el script salio 0 pese al puerto ocupado por un proceso ajeno" >&2; exit 1
  fi
  if ! echo "$OUT" | grep -qiE "puerto :?3999 sigue ocupado|puerto.*ocupado"; then
    echo "FAIL: no aparece el mensaje del guard de puerto (el script no protegio el handoff)" >&2; exit 1
  fi
  echo "  guard de puerto: falla limpio con mensaje claro (no crash-loop): PASS"
  echo "ALL PASS"
'
