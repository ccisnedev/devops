#!/usr/bin/env bash
# Build-NodeApiPackage.sh (ADR 0003, build:false)
# Builds the deploy package for a no-build Node API in an EPHEMERAL temp dir
# (mktemp -d), so it never mutates the user's working tree and never runs the
# heavy npm ci over drvfs (/mnt/c) when invoked from WSL on a Windows host.
#
# Read from stdin (bash -s). Positional args:
#   $1 = SRC_TAR      path to the source tar (git archive HEAD, tracked files only)
#   $2 = ENTRYPOINT   entrypoint relative path (e.g. server.js); validated as versioned
#   $3 = OUT_TARBALL  output .tar.gz path (source + production node_modules)
#
# The only filesystem touch points on drvfs (when in WSL) are reading SRC_TAR and
# writing OUT_TARBALL: two single-file operations. All the npm ci churn stays on
# the native (ext4) filesystem under mktemp.
set -euo pipefail

SRC_TAR="${1:?missing SRC_TAR}"
ENTRYPOINT="${2:?missing ENTRYPOINT}"
OUT_TARBALL="${3:?missing OUT_TARBALL}"

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# 1. Unpack the versioned source into the ephemeral build dir.
tar -xf "$SRC_TAR" -C "$BUILD_DIR"

# 2. The entrypoint must be a tracked file (present in the git archive).
if [ ! -f "$BUILD_DIR/$ENTRYPOINT" ]; then
  echo "ERROR: entrypoint '$ENTRYPOINT' is not versioned in git (absent from HEAD)." >&2
  exit 3
fi

# 3. Production node_modules, built natively (ext4) for the Linux target.
cd "$BUILD_DIR"
npm ci --omit=dev

if [ ! -d node_modules ]; then
  echo "ERROR: node_modules missing after 'npm ci --omit=dev'." >&2
  exit 4
fi

# 4. Package source + node_modules into the output tarball.
tar -czf "$OUT_TARBALL" .
echo "OK: package built at $OUT_TARBALL"
