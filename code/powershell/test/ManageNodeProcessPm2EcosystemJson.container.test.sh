#!/usr/bin/env bash
# Behavioral test of Manage-NodeProcess.sh (pm2 config-as-code, JSON ecosystem) in a clean
# Linux container (Docker). Proves the config-as-code path works in a `type:module` (ESM)
# project via a GENERATED ecosystem.config.json — the artifact Publish-NodeApi renders from
# publish.yaml (ADR 0005).
#
# Regression it guards: a hand-written ecosystem.config.js is ESM under type:module; pm2
# require()-loads it as CommonJS and dies with "No script path". The fix (ADR 0005) is to
# render an ecosystem.config.json (pm2 loads JSON natively, no CJS/ESM trap) and resolve the
# config-as-code file by precedence: .json -> .cjs -> .js.
#
# Discriminating assertions (fail against the OLD script, which only looks for
# ecosystem.config.js and would fall back to the Direct path):
#   1. The running app is named "worker" (from the JSON), NOT the CLI $NAME ("demo").
#   2. The process serves "worker" — proving BOTH the ESM server.js ran AND env.ROLE from the
#      JSON was applied.
#
# Usage: bash ManageNodeProcessPm2EcosystemJson.container.test.sh [path-to-Private/scripts]
# Requires: docker.
set -euo pipefail

SCRIPTS_DIR="${1:-$(cd "$(dirname "$0")/../Private/scripts" && pwd)}"
IMG="node:22-bookworm-slim"
echo "Scripts dir: $SCRIPTS_DIR"

docker run --rm -v "$SCRIPTS_DIR:/scripts:ro" "$IMG" bash -euo pipefail -c '
  command -v curl >/dev/null 2>&1 || { apt-get update -qq >/dev/null && apt-get install -y -qq curl >/dev/null; }
  npm install -g pm2 >/dev/null 2>&1

  # ── One release: a type:module (ESM) project with a GENERATED ecosystem.config.json ──
  D="/opt/app/demo/releases/rel1"
  mkdir -p "$D"

  # ESM: import syntax + type:module. Serves its own ROLE env var so we can prove the JSON
  # env block was applied (Direct path would leave ROLE unset -> "unset").
  echo "{ \"type\": \"module\" }" > "$D/package.json"
  cat > "$D/server.js" <<EOF
import http from "http";
const role = process.env.ROLE || "unset";
http.createServer((_, res) => res.end(role)).listen(3999, "127.0.0.1");
EOF

  # The artifact Publish-NodeApi renders from publish.yaml (name + script + env as DATA).
  cat > "$D/ecosystem.config.json" <<EOF
{ "apps": [ { "name": "worker", "script": "server.js", "env": { "ROLE": "worker" } } ] }
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

  # 1. App name comes from the JSON ("worker"), not the CLI $NAME ("demo").
  if ! pm2 describe worker >/dev/null 2>&1; then
    echo "FAIL: no existe app pm2 llamada \"worker\" (la config-as-code JSON no se uso)" >&2
    pm2 list >&2
    exit 1
  fi
  echo "  app pm2 \"worker\" (nombre del JSON): PASS"

  # 2. Serves "worker": ESM server.js corrio Y env.ROLE del JSON se aplico.
  GOT="$(curl -s http://127.0.0.1:3999)"
  if [ "$GOT" != "worker" ]; then
    echo "FAIL: el proceso sirve [$GOT], esperaba \"worker\" (ESM + env del JSON)" >&2
    exit 1
  fi
  echo "  proceso ESM sirve env.ROLE del JSON: PASS"

  echo "ALL PASS"
'
