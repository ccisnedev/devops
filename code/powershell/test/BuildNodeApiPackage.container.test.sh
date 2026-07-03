#!/usr/bin/env bash
# ADR 0003 (build:false) — Behavioral test of Build-NodeApiPackage.sh in a clean
# Linux container (Docker). Proves the packaging logic:
#   - builds production node_modules in an EPHEMERAL dir (mktemp), never touching
#     the source working tree (no devDependency wipe, no node_modules left behind);
#   - honours --omit=dev (devDependencies absent from the package);
#   - packages the versioned source + node_modules into the output tarball;
#   - rejects an entrypoint that is not part of the source (exit 3).
#
# Usage: bash BuildNodeApiPackage.container.test.sh [path-to-Private/scripts]
# Requires: docker.
set -euo pipefail

SCRIPTS_DIR="${1:-$(cd "$(dirname "$0")/../Private/scripts" && pwd)}"
IMG="node:22-bookworm-slim"
echo "Scripts dir: $SCRIPTS_DIR"

docker run --rm -v "$SCRIPTS_DIR:/scripts:ro" "$IMG" bash -euo pipefail -c '
  command -v git >/dev/null 2>&1 || { apt-get update -qq >/dev/null && apt-get install -y -qq git >/dev/null; }
  git config --global user.email t@t.io; git config --global user.name t; git config --global init.defaultBranch main

  # ── Fake SOURCE project: a prod dep (is-number) and a dev dep (left-pad) ──
  PROJ=/tmp/proj
  mkdir -p "$PROJ"; cd "$PROJ"
  cat > package.json <<EOF
{
  "name": "demo-api",
  "version": "1.0.0",
  "dependencies": { "is-number": "7.0.0" },
  "devDependencies": { "left-pad": "1.3.0" }
}
EOF
  cat > server.js <<EOF
const http = require("http");
http.createServer((_, r) => r.end("ok")).listen(process.env.PORT || 8080);
EOF
  # Generate the lockfile npm ci requires, then drop node_modules so the source
  # tree mirrors a real repo (node_modules gitignored, only the lock tracked).
  npm install --silent >/dev/null 2>&1
  rm -rf node_modules
  git init -q && git add -A && git commit -qm init
  git archive --format=tar -o /tmp/src.tar HEAD

  # ── Run the packaging script (as the cmdlet does: stdin via bash -s + args) ──
  bash -s -- /tmp/src.tar server.js /tmp/out.tar.gz < /scripts/Build-NodeApiPackage.sh

  # ── Assertions ──
  test -f /tmp/out.tar.gz                                   # tarball produced
  test ! -e "$PROJ/node_modules"                            # source tree NOT mutated (ephemeral build)

  mkdir -p /tmp/unpack && tar -xzf /tmp/out.tar.gz -C /tmp/unpack
  test -f /tmp/unpack/server.js                             # source entrypoint packaged
  test -f /tmp/unpack/package.json                          # manifest packaged
  test -d /tmp/unpack/node_modules/is-number               # prod dependency present
  test ! -e /tmp/unpack/node_modules/left-pad              # dev dependency omitted (--omit=dev)
  echo "  build + omit-dev + working-tree-intact: PASS"

  # ── Entrypoint validation: a non-versioned entrypoint must fail (exit 3) ──
  set +e
  bash -s -- /tmp/src.tar does-not-exist.js /tmp/out2.tar.gz < /scripts/Build-NodeApiPackage.sh >/dev/null 2>&1
  rc=$?
  set -e
  test "$rc" -eq 3                                          # rejects missing entrypoint
  test ! -e /tmp/out2.tar.gz                                # no tarball on failure
  echo "  entrypoint validation (exit 3): PASS"
'
echo "ALL BUILD-PACKAGE CONTAINER TESTS PASSED"
