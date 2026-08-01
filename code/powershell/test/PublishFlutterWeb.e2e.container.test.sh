#!/usr/bin/env bash
# End-to-end behavioral test del despliegue Flutter Web server-side en un contenedor Linux
# limpio (Docker), con nginx REAL. Ejercita los dos scripts remotos juntos sobre un deploy real:
#   1. Install-FlutterWeb.sh  — extrae el zip, crea releases/v<version>, actualiza symlink current.
#   2. Configure-NginxSite.sh — crea el site nginx (greenfield), valida (nginx -t) y recarga.
# Luego prueba que el sitio SIRVE de verdad (HTTP 200 + version.json + fallback SPA).
#
# Guards de regresión:
#   - DEPLOYED:v<version> aparece EXACTAMENTE una vez (bloquea el bloque de symlink duplicado).
#   - Un segundo Configure-NginxSite.sh reporta NGINX:EXISTS y no re-crea (idempotente).
#
# Nota: los contenedores no tienen systemd; se instala un shim de `systemctl` que traduce
# `systemctl reload nginx` a señales del binario nginx (patrón estándar en contenedores).
#
# Usage: bash PublishFlutterWeb.e2e.container.test.sh [path-to-Private/scripts]
# Requires: docker.
set -euo pipefail

SCRIPTS_DIR="${1:-$(cd "$(dirname "$0")/../Private/scripts" && pwd)}"
IMG="debian:bookworm-slim"
echo "Scripts dir: $SCRIPTS_DIR"

docker run --rm -v "$SCRIPTS_DIR:/scripts:ro" "$IMG" bash -euo pipefail -c '
  # ── Prereqs: nginx real + unzip/zip + ss (iproute2) + curl + sudo ──
  apt-get update -qq >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      nginx-light unzip zip iproute2 curl procps sudo >/dev/null
  nginx -v

  # ── systemctl shim (sin systemd en el contenedor): reload/start -> binario nginx ──
  cat > /usr/local/bin/systemctl <<"SH"
#!/bin/bash
# minimal shim para contenedores: mapea la accion sobre nginx al binario
case "$1" in
  reload)  nginx -t && { nginx -s reload 2>/dev/null || nginx; } ;;
  restart) nginx -s stop 2>/dev/null || true; nginx ;;
  start)   nginx 2>/dev/null || nginx -s reload ;;
  *)       : ;;
esac
SH
  chmod +x /usr/local/bin/systemctl

  NAME=pyme
  VERSION=1.0.0
  PORT=8080

  # ── Artefacto web falso (lo que produciria flutter build web), empaquetado como el zip
  #    que Install-FlutterWeb.sh espera en /tmp/${NAME}_web_v${VERSION}.zip ──
  mkdir -p /tmp/web
  cat > /tmp/web/index.html <<HTML
<!doctype html><html><head><title>pyme</title></head><body>pyme web ok</body></html>
HTML
  echo "{\"app_name\":\"pyme\",\"version\":\"1.0.0\",\"build_number\":\"1\"}" > /tmp/web/version.json
  ( cd /tmp/web && zip -q -r "/tmp/${NAME}_web_v${VERSION}.zip" . )

  # ── 1. Install-FlutterWeb.sh (release + symlink current) ──
  sed -e "s/__NAME__/${NAME}/g" -e "s/__VERSION__/${VERSION}/g" -e "s#__WEB_ROOT__#/var/www#g" \
      /scripts/Install-FlutterWeb.sh > /tmp/install.sh

  bash /tmp/install.sh | tee /tmp/install.out

  # Guard de regresion: DEPLOYED exactamente una vez (bloque de symlink NO duplicado).
  DEPLOYED_COUNT=$(grep -c "^DEPLOYED:v${VERSION}$" /tmp/install.out || true)
  [ "$DEPLOYED_COUNT" -eq 1 ] || { echo "  FAIL: DEPLOYED aparece ${DEPLOYED_COUNT} veces (esperaba 1 - bloque duplicado?)"; exit 1; }
  echo "  install: DEPLOYED x1 OK"

  # Estado esperado tras Install
  REL="/var/www/${NAME}/releases/v${VERSION}"
  test -f "$REL/index.html"                                   || { echo "  FAIL: falta index.html en el release"; exit 1; }
  test "$(readlink -f /var/www/${NAME}/current)" = "$REL"     || { echo "  FAIL: symlink current no apunta al release"; exit 1; }
  test "$(stat -c %U "$REL")" = "www-data"                    || { echo "  FAIL: release no es de www-data"; exit 1; }
  echo "  install: release + current + permisos OK"

  # ── 2. Configure-NginxSite.sh (greenfield: crea site + recarga) ──
  sed -e "s/__NAME__/${NAME}/g" -e "s/__PORT__/${PORT}/g" \
      /scripts/Configure-NginxSite.sh > /tmp/nginx.sh

  bash /tmp/nginx.sh | tee /tmp/nginx.out
  grep -q "^NGINX:CREATED$" /tmp/nginx.out || { echo "  FAIL: esperaba NGINX:CREATED"; cat /tmp/nginx.out; exit 1; }

  # El config generado debe apuntar root a current y usar fallback SPA
  grep -q "root /var/www/${NAME}/current;" /etc/nginx/sites-available/${NAME} || { echo "  FAIL: root no apunta a current"; exit 1; }
  grep -q "try_files .* /index.html;"      /etc/nginx/sites-available/${NAME} || { echo "  FAIL: falta fallback SPA /index.html"; exit 1; }
  test -L /etc/nginx/sites-enabled/${NAME} || { echo "  FAIL: falta symlink en sites-enabled"; exit 1; }
  echo "  nginx: site creado (root->current, SPA fallback) OK"

  # ── 3. El sitio SIRVE de verdad ──
  sleep 1
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/")
  [ "$CODE" = "200" ] || { echo "  FAIL: / respondio $CODE (esperaba 200)"; exit 1; }
  curl -s "http://127.0.0.1:${PORT}/version.json" | grep -q "\"version\":\"1.0.0\"" || { echo "  FAIL: version.json no servido"; exit 1; }
  SPA=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/una/ruta/profunda")
  [ "$SPA" = "200" ] || { echo "  FAIL: fallback SPA respondio $SPA (esperaba 200 via /index.html)"; exit 1; }
  echo "  serve: / -> 200, version.json OK, SPA deep-link -> 200"

  # ── 4. Idempotencia: segundo Configure no re-crea (NGINX:EXISTS) ──
  bash /tmp/nginx.sh > /tmp/nginx2.out 2>&1
  grep -q "^NGINX:EXISTS$" /tmp/nginx2.out || { echo "  FAIL: segundo Configure no reporto NGINX:EXISTS"; cat /tmp/nginx2.out; exit 1; }
  echo "  nginx: segundo run -> NGINX:EXISTS (idempotente) OK"
'
echo "ALL FLUTTERWEB E2E CONTAINER TESTS PASSED"
