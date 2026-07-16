#!/usr/bin/env bash
# Behavioral test del guard de sharedPaths en Install-NodeApi.sh, en un contenedor limpio.
# Endurecimiento: un sharedPath declarado debe tener CONTENIDO USABLE, no solo existir.
# Falla claro (exit 6) si el sharedPath:
#   - no existe               (comportamiento previo; guard de regresion)
#   - es carpeta vacia        (nuevo: symlink a vacio -> crypto rota en runtime)
#   - es carpeta con solo archivos de 0 bytes (nuevo)
# y tiene exito (symlink current/<path>) si la carpeta tiene un archivo regular no-vacio.
#
# Usage: bash InstallNodeApiSharedPaths.container.test.sh [path-to-Private/scripts]
# Requires: docker.
set -euo pipefail

SCRIPTS_DIR="${1:-$(cd "$(dirname "$0")/../Private/scripts" && pwd)}"
IMG="node:22-bookworm-slim"
echo "Scripts dir: $SCRIPTS_DIR"

# shared_setup: missing | empty | zerobyte | nonempty ; expect: 6 | ok
run_case() {
  local label="$1" shared_setup="$2" expect="$3"
  docker run --rm -v "$SCRIPTS_DIR:/scripts:ro" \
    -e SHARED_SETUP="$shared_setup" -e EXPECT="$expect" \
    "$IMG" bash -euo pipefail -c '
      command -v useradd >/dev/null 2>&1 || { apt-get update -qq >/dev/null && apt-get install -y -qq passwd >/dev/null; }
      id -u deployer >/dev/null 2>&1 || useradd -m -s /bin/bash deployer
      mkdir -p /opt/app/tigre && chown -R deployer:deployer /opt/app

      # Proyecto SOURCE falso (build:false): server.js + package.json, sin dist/ ni deps
      mkdir -p /tmp/fake/node_modules
      echo "console.log(1)" > /tmp/fake/server.js
      echo "{\"name\":\"tigre\",\"version\":\"1.0.0\"}" > /tmp/fake/package.json
      tar -czf /tmp/tigre-v1.0.0.tar.gz -C /tmp/fake server.js node_modules package.json
      printf "PORT=3090\n" > /tmp/tigre.env.production

      # Estado de shared/key segun el caso
      SD=/opt/app/tigre/shared/key
      case "$SHARED_SETUP" in
        missing)  : ;;
        empty)    mkdir -p "$SD" ;;
        zerobyte) mkdir -p "$SD"; : > "$SD/privatekey.pem" ;;
        nonempty) mkdir -p "$SD"; echo "KEYDATA" > "$SD/privatekey.pem" ;;
      esac
      chown -R deployer:deployer /opt/app/tigre

      sed -e "s/__NAME__/tigre/g" -e "s/__VERSION__/1.0.0/g" -e "s#__REMOTE_ROOT__#/opt/app#g" \
          -e "s/__NODE_VERSION__/>=18/g" -e "s/__USER__/deployer/g" -e "s/__USE_SUDO__/0/g" \
          -e "s#__ENTRYPOINT__#server.js#g" -e "s/__SHARED_PATHS__/key/g" \
          /scripts/Install-NodeApi.sh > /tmp/install.sh
      chown deployer:deployer /tmp/install.sh /tmp/tigre-v1.0.0.tar.gz /tmp/tigre.env.production

      set +e
      su deployer -c "bash /tmp/install.sh" >/tmp/out 2>&1
      rc=$?
      set -e

      if [ "$EXPECT" = "6" ]; then
        if [ "$rc" -ne 6 ]; then echo "  FAIL: esperaba exit 6, obtuvo $rc"; cat /tmp/out; exit 1; fi
      else
        if [ "$rc" -ne 0 ]; then echo "  FAIL: esperaba exito, obtuvo $rc"; cat /tmp/out; exit 1; fi
        test -L /opt/app/tigre/current/key || { echo "  FAIL: falta symlink current/key"; exit 1; }
        test -s /opt/app/tigre/current/key/privatekey.pem || { echo "  FAIL: pem vacio tras symlink"; exit 1; }
      fi
    '
  echo "  $label: PASS"
}

echo "== guard de sharedPaths (Install-NodeApi.sh) =="
run_case "no existe        -> exit 6" missing  6
run_case "carpeta vacia    -> exit 6" empty    6
run_case "solo 0-byte      -> exit 6" zerobyte 6
run_case "con pem no-vacio -> exito + symlink" nonempty ok
echo "ALL SHAREDPATHS CONTAINER TESTS PASSED"
