#!/usr/bin/env bash
# ADR 0005 — Behavioral test of Install-NodeApi.sh block 4a (generated ecosystem.config.json)
# in a clean Linux container (Docker). Publish-NodeApi renders the ecosystem from publish.yaml
# and stages it at /tmp/<NAME>.ecosystem.json (same rail as the .env); the installer must copy
# it into the release as ecosystem.config.json. Opt-in: if not staged, none is created.
#
# Usage: bash InstallNodeApiEcosystem.container.test.sh [path-to-Private/scripts]
# Requires: docker.
set -euo pipefail

SCRIPTS_DIR="${1:-$(cd "$(dirname "$0")/../Private/scripts" && pwd)}"
IMG="node:22-bookworm-slim"
echo "Scripts dir: $SCRIPTS_DIR"

docker run --rm -v "$SCRIPTS_DIR:/scripts:ro" "$IMG" bash -euo pipefail -c '
  mkdir -p /opt/app/demo

  # Fake SOURCE project + tarball.
  mkdir -p /tmp/fake
  echo "const http=require(\"http\");http.createServer((_,r)=>r.end(\"ok\")).listen(8080);" > /tmp/fake/server.js
  echo "{\"name\":\"demo\",\"version\":\"1.0.0\"}" > /tmp/fake/package.json

  render_install() {  # $1 = release id, $2 = sha
    tar -czf "/tmp/demo-$1.tar.gz" -C /tmp/fake server.js package.json
    printf "PORT=8080\n" > /tmp/demo.env.production
    sed -e "s/__NAME__/demo/g" -e "s/__VERSION__/1.0.0/g" -e "s#__REMOTE_ROOT__#/opt/app#g" \
        -e "s/__NODE_VERSION__/>=18/g" -e "s/__USER__/root/g" -e "s/__USE_SUDO__/0/g" \
        -e "s#__ENTRYPOINT__#server.js#g" -e "s/__RELEASE_ID__/$1/g" -e "s/__GIT_SHA__/$2/g" \
        /scripts/Install-NodeApi.sh > /tmp/install.sh
    bash /tmp/install.sh >/dev/null 2>&1
  }

  # ── Case 1: ecosystem staged -> copiado como ecosystem.config.json ──
  echo "{ \"apps\": [ { \"name\": \"demo\", \"script\": \"server.js\" } ] }" > /tmp/demo.ecosystem.json
  render_install "v1.0.0+aaa1111" "aaa1111"
  REL1="/opt/app/demo/releases/v1.0.0+aaa1111"
  if [ ! -f "$REL1/ecosystem.config.json" ]; then
    echo "FAIL: no se copio ecosystem.config.json al release" >&2; exit 1
  fi
  grep -q "\"name\": \"demo\"" "$REL1/ecosystem.config.json" || { echo "FAIL: contenido del ecosystem no coincide" >&2; exit 1; }
  [ ! -f /tmp/demo.ecosystem.json ] || { echo "FAIL: el staged /tmp/demo.ecosystem.json no se limpio" >&2; exit 1; }
  echo "  ecosystem staged -> copiado + limpiado: PASS"

  # ── Case 2: sin staging -> NO se crea (opt-in, retrocompat) ──
  render_install "v1.0.0+bbb2222" "bbb2222"
  REL2="/opt/app/demo/releases/v1.0.0+bbb2222"
  if [ -f "$REL2/ecosystem.config.json" ]; then
    echo "FAIL: se creo ecosystem.config.json sin staging (deberia ser opt-in)" >&2; exit 1
  fi
  echo "  sin staging -> no se crea (opt-in): PASS"

  echo "ALL PASS"
'
