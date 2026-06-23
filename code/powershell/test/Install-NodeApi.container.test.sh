#!/usr/bin/env bash
# Behavioral test of Install-NodeApi.sh in a clean Linux container (Docker).
# Proves the actual install logic, not just source text:
#   Case 1 - rootless (USE_SUDO=0): a non-root user that OWNS the app dir installs
#            successfully in an image WITHOUT sudo. If the script tried sudo it would
#            fail ("sudo: command not found").
#   Case 2 - sudo opt-in (USE_SUDO=1): a user with passwordless sudo installs into a
#            root-owned app dir.
#
# Usage: bash Install-NodeApi.container.test.sh [path-to-Private/scripts]
# Requires: docker.
set -euo pipefail

SCRIPTS_DIR="${1:-$(cd "$(dirname "$0")/../Private/scripts" && pwd)}"
IMG="node:22-bookworm-slim"
echo "Scripts dir: $SCRIPTS_DIR"

run_case() {
  local label="$1" use_sudo="$2" with_sudo_pkg="$3" app_owner="$4"
  docker run --rm -v "$SCRIPTS_DIR:/scripts:ro" \
    -e USE_SUDO="$use_sudo" -e WITH_SUDO="$with_sudo_pkg" -e APP_OWNER="$app_owner" \
    "$IMG" bash -euo pipefail -c '
      command -v useradd >/dev/null 2>&1 || { apt-get update -qq >/dev/null && apt-get install -y -qq passwd >/dev/null; }
      if [ "$WITH_SUDO" = "1" ]; then apt-get update -qq >/dev/null && apt-get install -y -qq sudo >/dev/null; fi
      id -u deployer >/dev/null 2>&1 || useradd -m -s /bin/bash deployer
      [ "$WITH_SUDO" = "1" ] && echo "deployer ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/deployer
      mkdir -p /opt/app
      if [ "$APP_OWNER" = "deployer" ]; then mkdir -p /opt/app/fotos; chown -R deployer:deployer /opt/app; else chown root:root /opt/app; fi
      mkdir -p /tmp/fake/dist /tmp/fake/node_modules
      echo ok > /tmp/fake/dist/main.js; echo "{}" > /tmp/fake/package.json
      tar -czf /tmp/fotos-v1.0.0.tar.gz -C /tmp/fake dist node_modules package.json
      printf "PORT=4044\n" > /tmp/fotos.env.production
      sed -e "s/__NAME__/fotos/g" -e "s/__VERSION__/1.0.0/g" -e "s#__REMOTE_ROOT__#/opt/app#g" \
          -e "s/__NODE_VERSION__/>=18/g" -e "s/__USER__/deployer/g" -e "s/__USE_SUDO__/$USE_SUDO/g" \
          /scripts/Install-NodeApi.sh > /tmp/install.sh
      chown deployer:deployer /tmp/install.sh /tmp/fotos-v1.0.0.tar.gz /tmp/fotos.env.production
      su deployer -c "bash /tmp/install.sh"
      test -f /opt/app/fotos/releases/v1.0.0/dist/main.js
      test -L /opt/app/fotos/current
      test -f /opt/app/fotos/current/.env
      [ "$(stat -c %U /opt/app/fotos/releases/v1.0.0)" = "deployer" ]
    '
  echo "  $label: PASS"
}

echo "== Case 1: rootless (USE_SUDO=0, image without sudo, app dir owned by deployer) =="
run_case "rootless" 0 0 deployer
echo "== Case 2: sudo opt-in (USE_SUDO=1, app dir root-owned) =="
run_case "sudo-optin" 1 1 root
echo "ALL CONTAINER TESTS PASSED"
