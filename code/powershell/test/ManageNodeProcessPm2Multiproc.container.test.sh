#!/usr/bin/env bash
# ADR 0005 — api + worker: un ecosystem.config.json con DOS apps arranca dos procesos pm2
# en un proyecto type:module (ESM), cada uno con su script y su env. Prueba end-to-end el
# patron multi-proceso que renderiza Publish-NodeApi desde runtime.processes.
#
# Usage: bash ManageNodeProcessPm2Multiproc.container.test.sh [path-to-Private/scripts]
# Requires: docker.
set -euo pipefail

SCRIPTS_DIR="${1:-$(cd "$(dirname "$0")/../Private/scripts" && pwd)}"
IMG="node:22-bookworm-slim"
echo "Scripts dir: $SCRIPTS_DIR"

docker run --rm -v "$SCRIPTS_DIR:/scripts:ro" "$IMG" bash -euo pipefail -c '
  command -v curl >/dev/null 2>&1 || { apt-get update -qq >/dev/null && apt-get install -y -qq curl >/dev/null; }
  npm install -g pm2 >/dev/null 2>&1

  D="/opt/app/demo/releases/rel1"
  mkdir -p "$D"
  echo "{ \"type\": \"module\" }" > "$D/package.json"

  # api sirve su ROLE en :3999; worker en :4000. ESM (import).
  cat > "$D/server.js" <<EOF
import http from "http";
http.createServer((_, res) => res.end(process.env.ROLE || "unset")).listen(3999, "127.0.0.1");
EOF
  cat > "$D/worker.js" <<EOF
import http from "http";
http.createServer((_, res) => res.end(process.env.ROLE || "unset")).listen(4000, "127.0.0.1");
EOF

  # El artefacto que renderiza Publish-NodeApi desde runtime.processes (api + worker).
  cat > "$D/ecosystem.config.json" <<EOF
{ "apps": [
  { "name": "api",    "script": "server.js", "env": { "ROLE": "api" } },
  { "name": "worker", "script": "worker.js", "env": { "ROLE": "worker" } }
] }
EOF
  : > "$D/.env"
  ln -sfn /opt/app/demo/releases/rel1 /opt/app/demo/current

  sed -e "s/__NAME__/demo/g" -e "s/__PROCESS_MANAGER__/pm2/g" \
      -e "s#__ENTRY_PATH__#/opt/app/demo/current/server.js#g" \
      -e "s#__WORKING_DIR__#/opt/app/demo/current#g" \
      -e "s#__ENV_FILE__#/opt/app/demo/current/.env#g" \
      -e "s/__PORT__/3999/g" -e "s/__USER__/root/g" \
      /scripts/Manage-NodeProcess.sh > /tmp/manage.sh
  bash /tmp/manage.sh
  sleep 2

  pm2 describe api    >/dev/null 2>&1 || { echo "FAIL: no existe app pm2 \"api\"" >&2; pm2 list >&2; exit 1; }
  pm2 describe worker >/dev/null 2>&1 || { echo "FAIL: no existe app pm2 \"worker\"" >&2; pm2 list >&2; exit 1; }
  echo "  api + worker online (2 apps del JSON): PASS"

  [ "$(curl -s http://127.0.0.1:3999)" = "api" ]    || { echo "FAIL: :3999 no sirve api" >&2; exit 1; }
  [ "$(curl -s http://127.0.0.1:4000)" = "worker" ] || { echo "FAIL: :4000 no sirve worker" >&2; exit 1; }
  echo "  cada proceso con su script + su env: PASS"

  echo "ALL PASS"
'
