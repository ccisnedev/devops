#!/usr/bin/env bash
# Deploy-DockerStack.sh — el despliegue debe ABORTAR si lo que corre no es lo que instalo.
#
# El healthcheck pregunta "¿el servicio responde?", y el servicio viejo responde perfecto. Nunca
# pregunta "¿esta corriendo el release que acabo de instalar?". Esa diferencia dejo pasar en
# produccion un despliegue en verde con la configuracion anterior.
#
# La comprobacion es directa y no depende de relojes ni de heuristicas de fecha: ningun mount de
# los contenedores del proyecto puede apuntar a un directorio de release distinto del instalado.
# Detecta la clase entera del problema sin importar la causa, incluido un compose con rutas
# absolutas a 'current', que un --force-recreate habria tapado.
#
# Usage: bash DockerStackVerificaLoDesplegado.container.test.sh [path-to-Private/scripts]
# Requires: docker.
set -euo pipefail

SCRIPTS_DIR="${1:-$(cd "$(dirname "$0")/../Private/scripts" && pwd)}"
IMG="debian:bookworm-slim"
echo "Scripts dir: $SCRIPTS_DIR"

docker run --rm -v "$SCRIPTS_DIR:/scripts:ro" "$IMG" bash -euo pipefail -c '
  STACK=/opt/stacks/demo

  # ── docker de mentira: 'compose' no hace nada; 'ps' e 'inspect' devuelven lo que dicte
  # ── /tmp/mounts.txt, que es lo que cada caso configura para simular el estado real.
  mkdir -p /usr/local/bin
  cat > /usr/local/bin/docker <<"SHIM"
#!/usr/bin/env bash
case "${1:-}" in
  ps)      echo "contenedor001" ;;
  inspect) cat /tmp/mounts.txt ;;
  *)       : ;;   # compose u otros: no-op
esac
exit 0
SHIM
  chmod +x /usr/local/bin/docker

  desplegar() {   # $1 = release; usa /tmp/mounts.txt ya escrito. Devuelve el codigo de salida.
    rm -rf /tmp/fuente && mkdir -p /tmp/fuente/conf
    echo "x: 1" > /tmp/fuente/conf/regla.yml
    printf "services:\n  demo:\n    image: alpine\n    volumes:\n      - ./conf:/etc/conf:ro\n" \
      > /tmp/fuente/docker-compose.yml
    tar -czf /tmp/demo.tar.gz -C /tmp/fuente .
    printf "FOO=bar\n" > /tmp/demo.env

    sed -e "s#__NAME__#demo#g" \
        -e "s#__STACK_DIR__#$STACK#g" \
        -e "s#__RELEASE_DIR__#$STACK/releases/$1#g" \
        -e "s#__CURRENT_LINK__#$STACK/current#g" \
        -e "s#__TARBALL__#/tmp/demo.tar.gz#g" \
        -e "s#__REMOTE_ENV__#/tmp/demo.env#g" \
        -e "s#__COMPOSE_FILE__#docker-compose.yml#g" \
        -e "s#__BUILD_FLAG__##g" \
        -e "s#__RELEASE_ID__#$1#g" \
        /scripts/Deploy-DockerStack.sh > /tmp/deploy.sh
    set +e; bash /tmp/deploy.sh > /tmp/salida.txt 2>&1; local rc=$?; set -e
    return $rc
  }

  # ── Caso 1: lo que corre es lo instalado -> el despliegue termina bien ──
  printf "%s\n" "$STACK/releases/v2/conf" "/var/lib/docker/volumes/demo_datos/_data" > /tmp/mounts.txt
  if desplegar v2; then
    echo "  caso 1 (mounts del release instalado): PASS"
  else
    echo "FALLO caso 1: aborto un despliegue correcto"; cat /tmp/salida.txt; exit 1
  fi

  # ── Caso 2: un contenedor quedo montando a traves del symlink -> debe abortar ──
  # Es la huella exacta del defecto corregido en 6.2.2, y la que tenia produccion.
  printf "%s\n" "$STACK/current/conf" > /tmp/mounts.txt
  if desplegar v3; then
    echo "FALLO caso 2: no aborto con un mount a traves de current"; cat /tmp/salida.txt; exit 1
  fi
  grep -qi "current/conf" /tmp/salida.txt \
    || { echo "FALLO caso 2: aborto sin decir que ruta lo delata"; cat /tmp/salida.txt; exit 1; }
  # El remedio debe ser el correcto: recrear NO arregla un mount contra el symlink.
  grep -qi "recrear NO alcanza" /tmp/salida.txt \
    || { echo "FALLO caso 2: aconseja recrear, que no arregla este caso"; cat /tmp/salida.txt; exit 1; }
  echo "  caso 2 (mount a traves de current, con el remedio correcto): PASS"

  # ── Caso 3: un contenedor quedo en un release anterior -> debe abortar ──
  printf "%s\n" "$STACK/releases/v1/conf" > /tmp/mounts.txt
  if desplegar v4; then
    echo "FALLO caso 3: no aborto con un mount de un release anterior"; cat /tmp/salida.txt; exit 1
  fi
  grep -qi "releases/v1/conf" /tmp/salida.txt \
    || { echo "FALLO caso 3: aborto sin decir que ruta lo delata"; cat /tmp/salida.txt; exit 1; }
  grep -qi "force-recreate" /tmp/salida.txt \
    || { echo "FALLO caso 3: no indica el remedio, que aqui si es recrear"; cat /tmp/salida.txt; exit 1; }
  echo "  caso 3 (mount de un release anterior, con el remedio correcto): PASS"

  # ── Caso 4b: el exito tiene que DECIRSE, no solo no fallar ──
  # Un despliegue que no dice nada no distingue "verifique y esta bien" de "ni siquiera corri".
  # Paso de verdad: la salida no menciono la verificacion porque la sesion tenia cargada una
  # version anterior del modulo, y eso solo se descubrio por otro detalle de la salida.
  printf "%s
" "$STACK/releases/v6/conf" > /tmp/mounts.txt
  if ! desplegar v6; then
    echo "FALLO caso 4b: aborto un despliegue correcto"; cat /tmp/salida.txt; exit 1
  fi
  grep -qi "verificado" /tmp/salida.txt     || { echo "FALLO caso 4b: la verificacion paso en silencio"; cat /tmp/salida.txt; exit 1; }
  # Y lo que afirma tiene que ser comprobable: cuantos contenedores y contra que release.
  grep -q "v6" /tmp/salida.txt     || { echo "FALLO caso 4b: no dice contra que release verifico"; cat /tmp/salida.txt; exit 1; }
  echo "  caso 4b (el exito se afirma, con release y cantidad): PASS"

  # ── Caso 4: los mounts ajenos al stack no son asunto suyo ──
  # Un volumen con nombre o un socket del host no dicen nada sobre que release corre.
  printf "%s\n" "/var/run/docker.sock" "/var/lib/docker/volumes/demo_datos/_data" > /tmp/mounts.txt
  if desplegar v5; then
    echo "  caso 4 (mounts fuera del stack se ignoran): PASS"
  else
    echo "FALLO caso 4: aborto por mounts que no son del stack"; cat /tmp/salida.txt; exit 1
  fi
'

echo "DockerStackVerificaLoDesplegado: PASS"
