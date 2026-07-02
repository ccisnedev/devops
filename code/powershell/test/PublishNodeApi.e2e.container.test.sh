#!/usr/bin/env bash
# ADR 0003 REQ-9 — End-to-end behavioral test of the no-build (build:false) runtime in a
# clean Linux container (Docker). Proves a REAL running process, not just files:
#   1. Install-NodeApi.sh installs a SOURCE tarball (server.js, no dist/), entrypoint=server.js.
#   2. Manage-NodeProcess.sh starts it under pm2 (real process manager).
#   3. Healthcheck.sh gets a successful HTTP 200 on /health against the live process.
# Exercises three remote scripts together on a real deploy.
#
# Usage: bash PublishNodeApi.e2e.container.test.sh [path-to-Private/scripts]
# Requires: docker.
set -euo pipefail

SCRIPTS_DIR="${1:-$(cd "$(dirname "$0")/../Private/scripts" && pwd)}"
IMG="node:22-bookworm-slim"
echo "Scripts dir: $SCRIPTS_DIR"

docker run --rm -v "$SCRIPTS_DIR:/scripts:ro" "$IMG" bash -euo pipefail -c '
  # ── Prereqs: curl (healthcheck) + pm2 (process manager), a non-root deploy user ──
  apt-get update -qq >/dev/null && apt-get install -y -qq curl passwd >/dev/null
  npm install -g pm2 >/dev/null 2>&1
  id -u deployer >/dev/null 2>&1 || useradd -m -s /bin/bash deployer
  mkdir -p /opt/app/impulsa && chown -R deployer:deployer /opt/app

  # ── Fake SOURCE project: server.js exposes /health, listens on $PORT (no dist/, no deps) ──
  mkdir -p /tmp/fake/node_modules
  cat > /tmp/fake/server.js <<EOF
const http = require("http");
const port = process.env.PORT || 8080;
http.createServer((req, res) => {
  if (req.url === "/health") { res.writeHead(200, {"content-type":"application/json"}); res.end(JSON.stringify({status:"ok"})); return; }
  res.writeHead(404); res.end();
}).listen(port, () => console.log("listening on " + port));
EOF
  echo "{\"name\":\"impulsa\",\"version\":\"1.0.0\"}" > /tmp/fake/package.json

  RELEASE_ID="v1.0.0+deadbee"
  tar -czf "/tmp/impulsa-${RELEASE_ID}.tar.gz" -C /tmp/fake server.js node_modules package.json
  printf "PORT=8080\n" > /tmp/impulsa.env.production

  # ── 1. Install (build:false, entrypoint=server.js) ──
  sed -e "s/__NAME__/impulsa/g" -e "s/__VERSION__/1.0.0/g" -e "s#__REMOTE_ROOT__#/opt/app#g" \
      -e "s/__NODE_VERSION__/>=18/g" -e "s/__USER__/deployer/g" -e "s/__USE_SUDO__/0/g" \
      -e "s#__ENTRYPOINT__#server.js#g" -e "s/__RELEASE_ID__/v1.0.0+deadbee/g" -e "s/__GIT_SHA__/deadbee/g" \
      /scripts/Install-NodeApi.sh > /tmp/install.sh

  # ── 2. Manage under pm2 (real process manager) ──
  CUR="/opt/app/impulsa/current"
  sed -e "s/__NAME__/impulsa/g" -e "s/__PROCESS_MANAGER__/pm2/g" \
      -e "s#__ENTRY_PATH__#$CUR/server.js#g" -e "s#__WORKING_DIR__#$CUR#g" -e "s#__ENV_FILE__#$CUR/.env#g" \
      -e "s/__PORT__/8080/g" -e "s/__USER__/deployer/g" \
      /scripts/Manage-NodeProcess.sh > /tmp/manage.sh

  # ── 3. Healthcheck against the live process ──
  sed -e "s#__HEALTHURL__#http://127.0.0.1:8080/health#g" /scripts/Healthcheck.sh > /tmp/health.sh

  chown deployer:deployer /tmp/install.sh /tmp/manage.sh /tmp/health.sh \
        /tmp/impulsa-${RELEASE_ID}.tar.gz /tmp/impulsa.env.production

  su deployer -c "bash /tmp/install.sh"
  su deployer -c "bash /tmp/manage.sh"
  su deployer -c "bash /tmp/health.sh"

  # ── Independent assertions on the live state ──
  REL="/opt/app/impulsa/releases/v1.0.0+deadbee"
  test -f "$REL/server.js"
  grep -q "^sha=deadbee$" "$REL/RELEASE"
  su deployer -c "pm2 describe impulsa" | grep -q "online"
  code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/health)
  [ "$code" = "200" ]
  echo "  live /health -> HTTP $code, pm2 online, RELEASE sha stamped: PASS"

  su deployer -c "pm2 delete impulsa >/dev/null 2>&1 || true"
'
echo "ALL E2E CONTAINER TESTS PASSED"
