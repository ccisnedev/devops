#!/usr/bin/env bash
set -euo pipefail
cd /mnt/d/source/packages/modular_api/template
echo "PWD: $(pwd)"
echo "LS build before:"
ls -la build || true

echo "DART VERSION:"
dart --version || true

echo "Running dart pub get..."
dart pub get

ENTRY=""
if [ -f bin/server.dart ]; then
  ENTRY="bin/server.dart"
elif [ -f bin/main.dart ]; then
  ENTRY="bin/main.dart"
else
  first=$(ls bin/*server*.dart 2>/dev/null | head -n1 || true)
  if [ -n "$first" ]; then
    ENTRY="$first"
  else
    first2=$(ls bin/*.dart 2>/dev/null | head -n1 || true)
    if [ -n "$first2" ]; then
      ENTRY="$first2"
    fi
  fi
fi

echo "ENTRY: $ENTRY"

# Remove temp if exists
rm -f build/server.tmp || true

echo "Compiling to build/server.tmp..."
# Capture compiler output
mkdir -p build

if ! dart compile exe "$ENTRY" -o build/server.tmp 2>&1 | sed 's/^/DART: /'; then
  echo "COMPILATION_FAILED"
fi

echo "After compile, ls build:"
ls -la build || true

if [ -f build/server.tmp ]; then
  echo "Moving server.tmp -> server"
  mv -f build/server.tmp build/server || true
fi

echo "Final ls build/server:"
ls -la build/server || true
