#!/usr/bin/env bash
# El sondeo post-deploy contra un nginx REAL (issue #76).
#
# Por que hace falta un contenedor
# --------------------------------
# La parte pura ya esta cubierta por Pester, pero el sondeo es bash + curl hablando con nginx, y
# ahi es donde estaba el defecto original: el check viejo pedia 200, y cinco de siete sitios
# devuelven 301 porque el puerto declarado pertenece a un bloque que solo redirige. Ninguna
# prueba sin servidor podia mostrar eso.
#
# Se probo contra un nginx real y aparecio un segundo defecto que ninguna prueba pura habria
# encontrado: cuando la redireccion lleva el puerto explicito ('host:8100'), descartarlo arma el
# --resolve para el puerto por defecto, el --resolve no aplica y curl sale al DNS publico. El
# caso 2 de aqui abajo es exactamente ese, y falla si alguien lo revierte: 'demo.local' no
# resuelve dentro del contenedor, asi que solo pasa si el --resolve se armo bien.
#
# El veredicto se calcula con el modulo, no con grep: la salida cruda del nginx real se lleva
# hasta ConvertTo-WebVerification. Por eso el parseo esta separado del SSH.
#
# Usage: bash WebVerificationSondeo.container.test.sh [path-to-Private/scripts]
# Requires: docker, pwsh.
set -euo pipefail

SCRIPTS_DIR="${1:-$(cd "$(dirname "$0")/../Private/scripts" && pwd)}"
IMG="nginx:1.27-alpine"
NOMBRE="macss_webverify_test"

# pwsh necesita rutas de Windows; bash necesita las suyas. Confundirlas es lo que hacia
# imposible ejecutar estas pruebas en Windows.
aWindows() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1" | tr '\\' '/'; else echo "$1"; fi; }

PRIV_POSIX="$(cd "$(dirname "$0")/../Private" && pwd)"
PRIV_WIN="$(aWindows "$PRIV_POSIX")"

command -v pwsh >/dev/null 2>&1 || { echo "FALLO: pwsh no esta disponible"; exit 1; }

TMP="$(mktemp -d)"
TMP_WIN="$(aWindows "$TMP")"
limpiar() { docker rm -f "$NOMBRE" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap limpiar EXIT

echo "Private dir: $PRIV_WIN"

# ── El sitio: lo desplegado, lo viejo, y uno que no publica version.json ──────────────
mkdir -p "$TMP/actual" "$TMP/viejo" "$TMP/sin-version"
echo '{"version":"1.7.3","build_number":"349"}' > "$TMP/actual/version.json"
echo '{"version":"1.7.1","build_number":"301"}' > "$TMP/viejo/version.json"
for d in actual viejo sin-version; do echo "<html>$d</html>" > "$TMP/$d/index.html"; done

# 8099 reproduce la forma de produccion: el puerto declarado en publish.yaml solo redirige, y
# la web la sirve otro bloque. El destino lleva el puerto explicito a proposito.
cat > "$TMP/default.conf" <<'CONF'
server {
    listen 8080;
    root /srv/actual;
    location / { try_files $uri $uri/ /index.html; }
}
server {
    listen 8081;
    root /srv/viejo;
    location / { try_files $uri $uri/ /index.html; }
}
server {
    listen 8082;
    root /srv/sin-version;
    location / { try_files $uri $uri/ /index.html; }
}
server {
    listen 8099;
    return 301 http://demo.local:8100$request_uri;
}
server {
    listen 8100;
    server_name demo.local;
    root /srv/actual;
    location / { try_files $uri $uri/ /index.html; }
}
CONF

# ── El sondeo lo genera el modulo, no esta prueba: si se copiara, se estaria probando la copia ──
cat > "$TMP/generar.ps1" <<'PS1'
# Los puertos llegan como una sola cadena: 'pwsh -File' no arma arreglos, liga el primer valor
# y los demas quedan como posicionales.
param([string]$Priv, [string]$Out, [string]$Puertos)
. (Join-Path $Priv 'WebVerification.ps1')
foreach ($p in [int[]]($Puertos -split ',')) {
    # A LF: el modulo vive con CRLF en Windows y bash no ejecuta un script con retornos de carro.
    $s = (New-WebVerificationScript -Port $p) -replace "`r`n", "`n"
    [IO.File]::WriteAllText((Join-Path $Out "probe-$p.sh"), $s, (New-Object Text.UTF8Encoding $false))
}
PS1

cat > "$TMP/veredicto.ps1" <<'PS1'
param([string]$Priv, [string]$Salida, [string]$Esperada)
. (Join-Path $Priv 'WebVerification.ps1')
$probe = ConvertFrom-WebProbeOutput -Lines (Get-Content -LiteralPath $Salida)
$r = ConvertTo-WebVerification -Probe $probe -ExpectedVersion $Esperada
Write-Output "$($r.Level)|$($r.Text)"
PS1

pwsh -NoProfile -File "$TMP_WIN/generar.ps1" -Priv "$PRIV_WIN" -Out "$TMP_WIN" -Puertos "8080,8081,8082,8090,8099"

docker run -d --name "$NOMBRE" \
  -v "$TMP_WIN:/srv:ro" \
  -v "$TMP_WIN/default.conf:/etc/nginx/conf.d/default.conf:ro" \
  "$IMG" >/dev/null
docker exec "$NOMBRE" apk add --no-cache bash curl >/dev/null 2>&1 \
  || { echo "FALLO: no se pudo instalar bash/curl en el contenedor"; exit 1; }

# nginx tiene que estar sirviendo antes de sondear, o el resultado dice mas del arranque que
# del despliegue.
for _ in $(seq 1 20); do
  docker exec "$NOMBRE" sh -c 'curl -sf -o /dev/null http://127.0.0.1:8080/' && break
  sleep 0.5
done

sondear() {   # $1 = puerto  -> imprime la salida cruda del sondeo
  docker exec "$NOMBRE" bash "/srv/probe-$1.sh"
}
veredicto() { # $1 = puerto, $2 = version esperada -> imprime 'nivel|texto'
  sondear "$1" > "$TMP/salida.txt"
  pwsh -NoProfile -File "$TMP_WIN/veredicto.ps1" -Priv "$PRIV_WIN" \
       -Salida "$TMP_WIN/salida.txt" -Esperada "$2" | tr -d '\r'
}

fallar() { echo "FALLO $1"; echo "  veredicto: $2"; echo "  sondeo:"; sed 's/^/    /' "$TMP/salida.txt"; exit 1; }

# ── Caso 1: 200 directo sirviendo lo desplegado ───────────────────────────────────────
R="$(veredicto 8080 '1.7.3')"
[ "${R%%|*}" = "ok" ] || fallar "caso 1: un sitio correcto no dio 'ok'" "$R"
echo "  caso 1 (200 directo con la version desplegada): PASS"

# ── Caso 2: 301 al bloque que sirve de verdad, con el puerto explicito ────────────────
# La forma de produccion. Y la unica prueba posible del --resolve: 'demo.local' no existe en
# el DNS del contenedor, asi que si el --resolve no se arma con el puerto del destino, curl
# no llega a ninguna parte y esto queda en 'error'.
R="$(veredicto 8099 '1.7.3')"
[ "${R%%|*}" = "ok" ] || fallar "caso 2: la redireccion con puerto explicito no se siguio" "$R"
grep -q "LOCATION:http://demo.local:8100" "$TMP/salida.txt" \
  || fallar "caso 2: no hubo redireccion; el caso no probo lo que dice probar" "$R"
echo "  caso 2 (301 a otro bloque, puerto explicito, --resolve): PASS"

# ── Caso 3: responde bien pero sirve lo viejo ─────────────────────────────────────────
# El caso de 'micro': el sitio contesta perfecto desde donde siempre, y el despliegue no
# cambio nada. El check anterior lo daba por bueno.
R="$(veredicto 8081 '1.7.3')"
[ "${R%%|*}" = "error" ] || fallar "caso 3: sirviendo una version vieja no dio 'error'" "$R"
case "$R" in *1.7.1*1.7.3*|*1.7.3*1.7.1*) : ;; *) fallar "caso 3: el mensaje no nombra ambas versiones" "$R" ;; esac
echo "  caso 3 (200 sano sirviendo la version anterior): PASS"

# ── Caso 4: sin version.json no se puede afirmar nada ─────────────────────────────────
R="$(veredicto 8082 '1.7.3')"
[ "${R%%|*}" = "warn" ] || fallar "caso 4: la ausencia de version.json no es motivo para fallar" "$R"
echo "  caso 4 (sin version.json: avisa, no falla): PASS"

# ── Caso 5: nada escuchando ───────────────────────────────────────────────────────────
R="$(veredicto 8090 '1.7.3')"
[ "${R%%|*}" = "error" ] || fallar "caso 5: un puerto muerto no dio 'error'" "$R"
# Y tiene que decirlo en castellano, no escupir el codigo. Cuando curl falla imprime su propio
# '000' y ademas sale con error: encadenar '|| echo 000' daba '000000', que no es ningun codigo
# HTTP, y el mensaje al operador quedaba en 'HTTP 000000'.
case "$R" in *"sin respuesta"*) : ;; *) fallar "caso 5: el mensaje no dice que no hubo respuesta" "$R" ;; esac
echo "  caso 5 (nada escuchando: 'sin respuesta', no un codigo inventado): PASS"

# ── Caso 6: el build number de Dart no puede provocar un desajuste falso ──────────────
# version.json solo lleva 'version'; la version desplegada llega como '1.7.3+349'.
R="$(veredicto 8080 '1.7.3+349')"
[ "${R%%|*}" = "ok" ] || fallar "caso 6: el build number provoco un desajuste falso" "$R"
echo "  caso 6 (el build number no cuenta en la comparacion): PASS"

echo "WebVerificationSondeo: PASS"
