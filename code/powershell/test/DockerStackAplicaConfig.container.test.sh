#!/usr/bin/env bash
# Deploy-DockerStack.sh — un despliegue debe APLICAR los cambios de configuracion.
#
# El defecto que fija este test: el script hacia `cd` al symlink `current` antes de invocar a
# compose. Compose toma ese directorio como raiz del proyecto, asi que un bind mount escrito
# `./prometheus/rules` resuelve siempre a `.../current/prometheus/rules` — una cadena que NO
# cambia entre releases. Compose compara imagen, variables y la cadena de los mounts, no ve
# diferencia y no recrea el contenedor. El symlink ya movido no lo alcanza: el kernel lo
# resolvio al crear el contenedor. Resultado: "Deploy completado", healthcheck en verde y la
# configuracion vieja corriendo.
#
# Se verifica sobre el directorio de trabajo con el que se invoca a compose, que es la causa
# raiz, en vez de sobre el contenido del contenedor, que exigiria un docker dentro de docker.
#
# Usage: bash DockerStackAplicaConfig.container.test.sh [path-to-Private/scripts]
# Requires: docker.
set -euo pipefail

SCRIPTS_DIR="${1:-$(cd "$(dirname "$0")/../Private/scripts" && pwd)}"
IMG="debian:bookworm-slim"
echo "Scripts dir: $SCRIPTS_DIR"

docker run --rm -v "$SCRIPTS_DIR:/scripts:ro" "$IMG" bash -euo pipefail -c '
  STACK=/opt/stacks/demo

  # ── Un docker de mentira: registra desde que directorio lo llaman y no hace nada ──
  # Es lo unico que hace falta para observar la causa raiz sin levantar contenedores.
  mkdir -p /usr/local/bin
  cat > /usr/local/bin/docker <<"SHIM"
#!/usr/bin/env bash
echo "$PWD" >> /tmp/invocaciones.log
exit 0
SHIM
  chmod +x /usr/local/bin/docker

  desplegar() {   # $1 = id de release, $2 = contenido del archivo de configuracion
    rm -rf /tmp/fuente && mkdir -p /tmp/fuente/conf
    echo "$2" > /tmp/fuente/conf/regla.yml
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
    bash /tmp/deploy.sh > /dev/null
  }

  # ── Dos despliegues consecutivos que solo difieren en la configuracion ──
  desplegar v1 "umbral: 900"
  desplegar v2 "umbral: 3600"

  # El symlink queda bien apuntado; eso nunca fue el problema.
  [ "$(readlink -f $STACK/current)" = "$STACK/releases/v2" ] \
    || { echo "FALLO: current no apunta a la release nueva"; exit 1; }

  primera=$(sed -n 1p /tmp/invocaciones.log)
  ultima=$(tail -n1 /tmp/invocaciones.log)

  # ── Caso 1: compose se invoca desde el directorio de la release, no desde el symlink ──
  if [ "$ultima" = "$STACK/current" ]; then
    echo "FALLO caso 1: compose se invoco desde el symlink ($ultima)."
    echo "  La ruta del bind mount no cambia entre releases, asi que Compose no recrea nada"
    echo "  y el contenedor sigue montando la configuracion de la release anterior."
    exit 1
  fi
  [ "$ultima" = "$STACK/releases/v2" ] \
    || { echo "FALLO caso 1: compose se invoco desde $ultima, se esperaba $STACK/releases/v2"; exit 1; }
  echo "  caso 1 (compose corre desde la release): PASS"

  # ── Caso 2: dos releases distintas => dos rutas distintas, que es lo que Compose compara ──
  [ "$primera" != "$ultima" ] \
    || { echo "FALLO caso 2: ambas releases se desplegaron desde la misma ruta ($primera)"; exit 1; }
  echo "  caso 2 (cada release cambia la ruta que compara Compose): PASS"
'

echo "DockerStackAplicaConfig: PASS"
