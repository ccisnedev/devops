#!/usr/bin/env bash
# El sondeo del estado del servicio en una sesion NO interactiva (issue #78).
#
# Por que hace falta un contenedor
# --------------------------------
# El defecto no estaba en la logica sino en el entorno: el reporte corre por SSH no interactivo,
# pm2 vive bajo un gestor de versiones de Node que solo se carga en shells interactivos, la
# invocacion fallaba, y el plan concluia que no habia servicio. Sobre un servidor donde la API
# llevaba 4 h 34 min corriendo, el reporte decia "Servicio: se creara".
#
# Ninguna prueba pura puede reproducir eso: hay que tener un pm2 que exista y no se resuelva.
# El caso 3 es exactamente ese.
#
# Usage: bash NodeServiceProbe.container.test.sh [path-to-Private/scripts]
# Requires: docker, pwsh.
set -euo pipefail

IMG="debian:bookworm-slim"
NOMBRE="macss_nodeservice_test"

aWindows() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1" | tr '\\' '/'; else echo "$1"; fi; }

PRIV_POSIX="$(cd "$(dirname "$0")/../Private" && pwd)"
PRIV_WIN="$(aWindows "$PRIV_POSIX")"

command -v pwsh >/dev/null 2>&1 || { echo "FALLO: pwsh no esta disponible"; exit 1; }

TMP="$(mktemp -d)"
TMP_WIN="$(aWindows "$TMP")"
limpiar() { docker rm -f "$NOMBRE" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap limpiar EXIT

echo "Private dir: $PRIV_WIN"

# ── El sondeo lo genera el modulo: si se copiara, se estaria probando la copia ────────
cat > "$TMP/generar.ps1" <<'PS1'
param([string]$Priv, [string]$Out)
. (Join-Path $Priv 'NodeServiceProbe.ps1')
foreach ($pm in 'pm2', 'systemd') {
    # A LF: el modulo vive con CRLF en Windows y bash no ejecuta un script con retornos de carro.
    $s = "#!/bin/bash`n" + (New-NodeServiceProbeScript -ProcessManager $pm -AppName 'impulsa-api')
    [IO.File]::WriteAllText((Join-Path $Out "probe-$pm.sh"), ($s -replace "`r`n", "`n"),
                            (New-Object Text.UTF8Encoding $false))
}
PS1

cat > "$TMP/estado.ps1" <<'PS1'
param([string]$Priv, [string]$Salida, [string]$Pm)
. (Join-Path $Priv 'NodeServiceProbe.ps1')
$s = (Get-Content -LiteralPath $Salida | Where-Object { $_ -match '^SERVICE:' } |
      Select-Object -First 1) -replace '^SERVICE:', ''
$r = ConvertTo-NodeServiceState -Status $s -ProcessManager $Pm
Write-Output "$s|$($r.Level)|$($r.Text)"
PS1

pwsh -NoProfile -File "$TMP_WIN/generar.ps1" -Priv "$PRIV_WIN" -Out "$TMP_WIN"

# ── pm2 de mentira: 'describe' responde segun /tmp/estado-pm2, con la forma de salida real ──
# La real es una tabla; el sondeo lee la columna con awk '{print $4}'.
cat > "$TMP/pm2" <<'SHIM'
#!/bin/bash
if [ "${1:-}" = "describe" ] && [ "$(cat /tmp/estado-pm2 2>/dev/null)" = "online" ]; then
  echo "│ status            │ online             │"
  exit 0
fi
exit 1
SHIM

# El gestor de versiones: su script de carga es lo unico que pone pm2 en el PATH, y solo lo
# ejecutan los shells que cargan el perfil.
cat > "$TMP/nvm.sh" <<'NVM'
export PATH="/opt/nvmbin:$PATH"
NVM

docker run -d --name "$NOMBRE" -v "$TMP_WIN:/srv:ro" "$IMG" sleep infinity >/dev/null
docker exec "$NOMBRE" bash -c '
  mkdir -p /opt/nvmbin /root/.nvm
  cp /srv/pm2 /opt/nvmbin/pm2 && chmod +x /opt/nvmbin/pm2
  cp /srv/nvm.sh /root/.nvm/nvm.sh
  echo online > /tmp/estado-pm2
'

sondear() { # $1 = pm2|systemd  -> imprime la salida cruda
  # HOME explicito: el sondeo busca el gestor de versiones bajo $HOME, y 'docker exec' no
  # siempre lo define. En el uso real lo define ssh.
  docker exec "$NOMBRE" bash -c "export HOME=/root; bash /srv/probe-$1.sh"
}
estado() {  # $1 = pm2|systemd -> imprime 'estado|nivel|texto'
  sondear "$1" > "$TMP/salida.txt"
  pwsh -NoProfile -File "$TMP_WIN/estado.ps1" -Priv "$PRIV_WIN" \
       -Salida "$TMP_WIN/salida.txt" -Pm "$1" | tr -d '\r'
}
fallar() { echo "FALLO $1"; echo "  resultado: $2"; exit 1; }

# ── Caso 1: pm2 en el PATH y el servicio arriba ───────────────────────────────────────
docker exec "$NOMBRE" bash -c 'cp /opt/nvmbin/pm2 /usr/local/bin/pm2'
R="$(estado pm2)"
case "$R" in online\|ok\|*reinici*) : ;; *) fallar "caso 1: un servicio online no se reporto como tal" "$R" ;; esac
echo "  caso 1 (pm2 en el PATH, servicio online): PASS"

# ── Caso 2: pm2 en el PATH y el servicio no existe ────────────────────────────────────
docker exec "$NOMBRE" bash -c 'echo ausente > /tmp/estado-pm2'
R="$(estado pm2)"
case "$R" in not-configured\|*"se cre"*) : ;; *) fallar "caso 2: sin servicio, el plan deberia anunciar que lo creara" "$R" ;; esac
echo "  caso 2 (pm2 en el PATH, sin servicio): PASS"

# ── Caso 3: EL DEFECTO. pm2 existe pero solo se resuelve cargando el perfil ───────────
# Es el servidor de produccion: la API llevaba horas corriendo y el plan decia "se creara".
docker exec "$NOMBRE" bash -c 'rm -f /usr/local/bin/pm2; echo online > /tmp/estado-pm2'
if docker exec "$NOMBRE" bash -c 'command -v pm2 >/dev/null 2>&1'; then
  echo "FALLO caso 3: pm2 sigue en el PATH; el caso no prueba lo que dice probar"; exit 1
fi
R="$(estado pm2)"
case "$R" in online\|ok\|*reinici*) : ;; *) fallar "caso 3: pm2 fuera del PATH no interactivo y el servicio quedo sin detectar" "$R" ;; esac
echo "  caso 3 (pm2 solo bajo el gestor de versiones, servicio online): PASS"

# ── Caso 4: pm2 no se puede ejecutar de ninguna forma ─────────────────────────────────
# 'No se' no es 'no hay': afirmar que se creara un servicio que no se pudo comprobar es la
# afirmacion falsa que este cambio existe para impedir.
docker exec "$NOMBRE" bash -c 'rm -f /root/.nvm/nvm.sh'
R="$(estado pm2)"
[ "${R%%|*}" = "unknown" ] || fallar "caso 4: sin poder ejecutar pm2, el estado deberia ser 'unknown'" "$R"
case "$R" in *"se cre"*) fallar "caso 4: el plan afirmo que creara un servicio que no pudo comprobar" "$R" ;; esac
case "$R" in *"no se pudo comprobar"*) : ;; *) fallar "caso 4: no dice que no pudo comprobarlo" "$R" ;; esac
echo "  caso 4 (pm2 irresoluble: 'no se', no 'no hay'): PASS"

# ── Caso 5: systemd donde no hay systemd ──────────────────────────────────────────────
# La imagen no trae systemctl. Reportar 'not-configured' seria igual de falso.
R="$(estado systemd)"
[ "${R%%|*}" = "unknown" ] || fallar "caso 5: sin systemctl el estado deberia ser 'unknown'" "$R"
echo "  caso 5 (systemd ausente: 'unknown'): PASS"

echo "NodeServiceProbe: PASS"
