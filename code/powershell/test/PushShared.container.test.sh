#!/usr/bin/env bash
# Behavioral test de Push-Shared.sh (server-side del -PushShared) en contenedor limpio.
# Reemplazo LIMPIO e idempotente del contenido de shared/<path> desde un tarball subido:
#   fresco   -> crea shared/<path> con el contenido local.
#   existe   -> reemplazo limpio: archivos viejos extra desaparecen, queda solo lo nuevo.
#   local vacio -> exit 8 y NO toca el remoto (nunca reemplaza con vacio).
#
# Usage: bash PushShared.container.test.sh [path-to-Private/scripts]
# Requires: docker.
set -euo pipefail

SCRIPTS_DIR="${1:-$(cd "$(dirname "$0")/../Private/scripts" && pwd)}"
IMG="node:22-bookworm-slim"
echo "Scripts dir: $SCRIPTS_DIR"

# mode: fresh | replace | empty
run_case() {
  local label="$1" mode="$2"
  docker run --rm -v "$SCRIPTS_DIR:/scripts:ro" -e MODE="$mode" "$IMG" bash -euo pipefail -c '
    command -v useradd >/dev/null 2>&1 || { apt-get update -qq >/dev/null && apt-get install -y -qq passwd >/dev/null; }
    id -u deployer >/dev/null 2>&1 || useradd -m -s /bin/bash deployer
    mkdir -p /opt/app/tigre/shared && chown -R deployer:deployer /opt/app

    SD=/opt/app/tigre/shared/key
    case "$MODE" in
      replace) mkdir -p "$SD"; echo "OLD" > "$SD/privatekey.pem"; echo "STALE" > "$SD/STALE.pem" ;;
      empty)   mkdir -p "$SD"; echo "REAL" > "$SD/privatekey.pem" ;;
    esac
    chown -R deployer:deployer /opt/app/tigre

    # Contenido local a subir (tarball con la carpeta key/)
    mkdir -p /tmp/local/key
    if [ "$MODE" = "empty" ]; then
      : > /tmp/local/key/privatekey.pem
    else
      echo "NEWKEY" > /tmp/local/key/privatekey.pem
      echo "NEWPUB" > /tmp/local/key/publickey.pem
    fi
    tar -czf /tmp/tigre-shared.tar.gz -C /tmp/local key

    sed -e "s/__NAME__/tigre/g" -e "s#__REMOTE_ROOT__#/opt/app#g" \
        -e "s/__SHARED_PATHS__/key/g" -e "s/__USE_SUDO__/0/g" \
        /scripts/Push-Shared.sh > /tmp/push.sh
    chown deployer:deployer /tmp/push.sh /tmp/tigre-shared.tar.gz

    set +e
    su deployer -c "bash /tmp/push.sh" >/tmp/out 2>&1
    rc=$?
    set -e

    case "$MODE" in
      fresh)
        [ "$rc" -eq 0 ] || { echo "  FAIL rc=$rc"; cat /tmp/out; exit 1; }
        test -s "$SD/privatekey.pem" || { echo "  FAIL: falta privatekey"; cat /tmp/out; exit 1; }
        test -s "$SD/publickey.pem"  || { echo "  FAIL: falta publickey"; exit 1; }
        grep -q "creando" /tmp/out   || { echo "  FAIL: esperaba 'creando'"; cat /tmp/out; exit 1; }
        ;;
      replace)
        [ "$rc" -eq 0 ] || { echo "  FAIL rc=$rc"; cat /tmp/out; exit 1; }
        grep -q "NEWKEY" "$SD/privatekey.pem" || { echo "  FAIL: no se actualizo privatekey"; exit 1; }
        test ! -e "$SD/STALE.pem" || { echo "  FAIL: STALE.pem sigue (no fue reemplazo limpio)"; exit 1; }
        grep -q "reemplazando" /tmp/out || { echo "  FAIL: esperaba 'reemplazando'"; cat /tmp/out; exit 1; }
        ;;
      empty)
        [ "$rc" -eq 8 ] || { echo "  FAIL: esperaba exit 8, obtuvo $rc"; cat /tmp/out; exit 1; }
        grep -q "REAL" "$SD/privatekey.pem" || { echo "  FAIL: el remoto fue tocado pese al contenido vacio"; exit 1; }
        ;;
    esac
  '
  echo "  $label: PASS"
}

echo "== Push-Shared.sh (reemplazo limpio) =="
run_case "fresco      -> crea" fresh
run_case "existe      -> reemplazo limpio (stale removido)" replace
run_case "local vacio -> exit 8, remoto intacto" empty
echo "ALL PUSH-SHARED CONTAINER TESTS PASSED"
