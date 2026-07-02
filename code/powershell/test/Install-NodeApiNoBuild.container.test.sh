#!/usr/bin/env bash
# ADR 0003 REQ-7 — Behavioral test of Install-NodeApi.sh in the no-build (build:false)
# runtime, in a clean Linux container (Docker). Proves the real install logic for a
# SOURCE tarball (no dist/), a configurable entrypoint, a v{version}+{sha} release id,
# and the RELEASE provenance file.
#
# Case: rootless (USE_SUDO=0), non-root owner, image WITHOUT sudo, entrypoint=server.js.
#
# Usage: bash Install-NodeApiNoBuild.container.test.sh [path-to-Private/scripts]
# Requires: docker.
set -euo pipefail

SCRIPTS_DIR="${1:-$(cd "$(dirname "$0")/../Private/scripts" && pwd)}"
IMG="node:22-bookworm-slim"
echo "Scripts dir: $SCRIPTS_DIR"

docker run --rm -v "$SCRIPTS_DIR:/scripts:ro" "$IMG" bash -euo pipefail -c '
  command -v useradd >/dev/null 2>&1 || { apt-get update -qq >/dev/null && apt-get install -y -qq passwd >/dev/null; }
  id -u deployer >/dev/null 2>&1 || useradd -m -s /bin/bash deployer
  mkdir -p /opt/app/impulsa && chown -R deployer:deployer /opt/app

  # Fake SOURCE project: server.js at the root (NO dist/), node_modules, package.json.
  mkdir -p /tmp/fake/node_modules /tmp/fake/routes
  cat > /tmp/fake/server.js <<EOF
const http = require("http");
http.createServer((_, r) => r.end("ok")).listen(process.env.PORT || 8080);
EOF
  echo "{\"name\":\"impulsa\",\"version\":\"1.0.0\"}" > /tmp/fake/package.json
  echo "module.exports = {}" > /tmp/fake/routes/index.js

  RELEASE_ID="v1.0.0+abc1234"
  tar -czf "/tmp/impulsa-${RELEASE_ID}.tar.gz" -C /tmp/fake server.js node_modules package.json routes
  printf "PORT=8080\n" > /tmp/impulsa.env.production

  sed -e "s/__NAME__/impulsa/g" -e "s/__VERSION__/1.0.0/g" -e "s#__REMOTE_ROOT__#/opt/app#g" \
      -e "s/__NODE_VERSION__/>=18/g" -e "s/__USER__/deployer/g" -e "s/__USE_SUDO__/0/g" \
      -e "s#__ENTRYPOINT__#server.js#g" -e "s/__RELEASE_ID__/v1.0.0+abc1234/g" -e "s/__GIT_SHA__/abc1234/g" \
      /scripts/Install-NodeApi.sh > /tmp/install.sh
  chown deployer:deployer /tmp/install.sh /tmp/impulsa-${RELEASE_ID}.tar.gz /tmp/impulsa.env.production
  su deployer -c "bash /tmp/install.sh"

  # ── Assertions (REQ-7) ──
  REL="/opt/app/impulsa/releases/v1.0.0+abc1234"
  test -f "$REL/server.js"                                  # source entrypoint installed
  test ! -e "$REL/dist"                                     # no dist/ in a no-build release
  test -L /opt/app/impulsa/current                          # symlink current exists
  [ "$(readlink -f /opt/app/impulsa/current)" = "$REL" ]    # current -> this release
  test -f /opt/app/impulsa/current/.env                     # .env copied
  test -f "$REL/RELEASE"                                    # provenance file present
  grep -q "^sha=abc1234$" "$REL/RELEASE"                    # sha stamped
  grep -q "^release=v1.0.0+abc1234$" "$REL/RELEASE"         # release id stamped
  [ "$(stat -c %U "$REL")" = "deployer" ]                   # owned by deploy user (rootless)
  echo "  no-build source install: PASS"
'
echo "ALL NO-BUILD CONTAINER TESTS PASSED"
