#!/usr/bin/env bash
# Behavioral test of Manage-NodeProcess.sh (pm2 + ecosystem.config.js path) in a clean
# Linux container (Docker). Reproduces the immutable-deploy symlink swap and proves the
# RUNNING pm2 process follows the NEW release after 'current' is repointed.
#
# Regression: 'pm2 startOrReload' kept each app's already-resolved script realpath (the
# PREVIOUS release), so swapping the 'current' symlink left the old code running. The fix
# is delete + start, which re-resolves the script through the updated symlink.
#
# Two releases share an identical server.js that serves the content of its own MARKER file
# (A vs B). Which letter the live process returns tells us which release dir it runs from.
#
# Usage: bash ManageNodeProcessPm2Symlink.container.test.sh [path-to-Private/scripts]
# Requires: docker.
set -euo pipefail

SCRIPTS_DIR="${1:-$(cd "$(dirname "$0")/../Private/scripts" && pwd)}"
IMG="node:22-bookworm-slim"
echo "Scripts dir: $SCRIPTS_DIR"

docker run --rm -v "$SCRIPTS_DIR:/scripts:ro" "$IMG" bash -euo pipefail -c '
  command -v curl >/dev/null 2>&1 || { apt-get update -qq >/dev/null && apt-get install -y -qq curl >/dev/null; }
  npm install -g pm2 >/dev/null 2>&1

  # ── Two releases with identical server.js; only MARKER differs ──
  for R in A B; do
    D="/opt/app/demo/releases/rel$R"
    mkdir -p "$D"
    printf "%s" "$R" > "$D/MARKER"
    cat > "$D/server.js" <<EOF
const fs = require("fs");
const marker = fs.readFileSync(require("path").join(__dirname, "MARKER"), "utf8").trim();
require("http").createServer((_, res) => res.end(marker)).listen(3999, "127.0.0.1");
EOF
    echo "module.exports = { apps: [{ name: \"demo\", script: \"server.js\" }] };" > "$D/ecosystem.config.js"
    : > "$D/.env"
  done

  render_and_run() {
    sed -e "s/__NAME__/demo/g" -e "s/__PROCESS_MANAGER__/pm2/g" \
        -e "s#__ENTRY_PATH__#/opt/app/demo/current/server.js#g" \
        -e "s#__WORKING_DIR__#/opt/app/demo/current#g" \
        -e "s#__ENV_FILE__#/opt/app/demo/current/.env#g" \
        -e "s/__PORT__/3999/g" -e "s/__USER__/root/g" \
        /scripts/Manage-NodeProcess.sh > /tmp/manage.sh
    bash /tmp/manage.sh >/dev/null 2>&1
  }

  # ── Deploy A ──
  ln -sfn /opt/app/demo/releases/relA /opt/app/demo/current
  render_and_run
  sleep 2
  GOT_A="$(curl -s http://127.0.0.1:3999)"
  [ "$GOT_A" = "A" ] || { echo "FAIL: tras deploy A el proceso sirve [$GOT_A], esperaba A" >&2; exit 1; }
  echo "  deploy A -> proceso sirve A: PASS"

  # ── Deploy B (symlink swap) — el proceso DEBE seguir el nuevo release ──
  ln -sfn /opt/app/demo/releases/relB /opt/app/demo/current
  render_and_run
  sleep 2
  GOT_B="$(curl -s http://127.0.0.1:3999)"
  [ "$GOT_B" = "B" ] || { echo "FAIL: tras swap a B el proceso sirve [$GOT_B] (corre el release viejo)" >&2; exit 1; }
  echo "  deploy B (swap symlink) -> proceso sirve B: PASS"

  pm2 delete all >/dev/null 2>&1 || true
'
echo "ALL PM2-SYMLINK CONTAINER TESTS PASSED"
