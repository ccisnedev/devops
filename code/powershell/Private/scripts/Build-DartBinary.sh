#!/bin/bash
# Build-DartBinary.sh
# Compila un proyecto Dart a binario nativo ELF en un directorio temporal /tmp
# para evitar problemas con permisos/locking en /mnt (WSL mount)
#
# Variables reemplazadas por PowerShell:
#   __WSLPROJECT__ : Ruta WSL del proyecto fuente
#   __WSLWINOUT__  : Ruta WSL donde copiar el binario resultante (temp Windows)

set -e

SRC='__WSLPROJECT__'
OUT='__WSLWINOUT__'

# Crear directorio temporal en filesystem nativo de Linux
TMPDIR=$(mktemp -d /tmp/psdevops_build.XXXXXX)
echo "Using TMPDIR=$TMPDIR"

# Copiar proyecto completo al tmpdir
mkdir -p "$TMPDIR/src"
cp -a "$SRC/." "$TMPDIR/src/"
cd "$TMPDIR/src"

# Verificar versión de Dart
dart --version

# Obtener dependencias
dart pub get

# Crear directorio de salida
mkdir -p build

# Auto-detectar entrypoint (en orden de preferencia)
ENTRY_CANDIDATE=""
if [ -f bin/server.dart ]; then
    ENTRY_CANDIDATE="bin/server.dart"
elif [ -f bin/main.dart ]; then
    ENTRY_CANDIDATE="bin/main.dart"
else
    # Buscar cualquier archivo *server*.dart
    first=$(ls bin/*server*.dart 2>/dev/null | head -n1 || true)
    if [ -n "$first" ]; then
        ENTRY_CANDIDATE="$first"
    else
        # Como último recurso, tomar el primer .dart en bin/
        first2=$(ls bin/*.dart 2>/dev/null | head -n1 || true)
        if [ -n "$first2" ]; then
            ENTRY_CANDIDATE="$first2"
        fi
    fi
fi

if [ -z "$ENTRY_CANDIDATE" ]; then
    echo "ERROR: No se encontró ningún archivo bin/*.dart. No se puede compilar." >&2
    exit 2
fi

echo "Usando entrypoint: $ENTRY_CANDIDATE"

# Compilar a ejecutable nativo
if ! dart compile exe "$ENTRY_CANDIDATE" -o build/server; then
    echo "ERROR: dart compile exe falló para $ENTRY_CANDIDATE" >&2
    exit 3
fi

# Verificar que el binario existe
if [ ! -f build/server ]; then
    echo "ERROR: build/server no existe después de compilar" >&2
    exit 4
fi

# Verificar tamaño mínimo (>100KB indica compilación completa)
size=$(stat -c%s build/server 2>/dev/null || stat -f%z build/server 2>/dev/null || echo 0)
if [ "$size" -lt 100000 ]; then
    echo "ERROR: build/server parece incompleto (tamaño: $size bytes)" >&2
    exit 5
fi

echo "Binario generado exitosamente (tamaño: $size bytes)"

# CRÍTICO: NO usar strip - destruye el snapshot AOT embebido en binarios Dart

# Verificar que el binario arranca correctamente ANTES de copiarlo
echo "Verificando que el binario arranca..."
tmp_verify=$(mktemp)
set +e
# Pasar PORT temporal para evitar error si la app requiere variables de entorno
PORT=8080 timeout 3 ./build/server >"$tmp_verify" 2>&1
verify_status=$?
set -e

# timeout retorna 124 si el proceso fue terminado por timeout (esperado)
if [ "$verify_status" -ne 124 ]; then
    echo "ERROR: El binario no arranca correctamente (exit=$verify_status)" >&2
    cat "$tmp_verify" >&2
    rm -f "$tmp_verify"
    exit 7
fi
rm -f "$tmp_verify"
echo "Verificación exitosa: binario arranca correctamente"

# Informar ruta nativa del binario antes de moverlo
echo "BUILT_NATIVE:$TMPDIR/src/build/server"

# Copiar el binario al path Windows temporal (convertido a /mnt/...)
mkdir -p "$(dirname "$OUT")"
cp build/server "$OUT"
chmod +x "$OUT"

# Señal de éxito con ruta del binario
echo "BUILT:$OUT"
