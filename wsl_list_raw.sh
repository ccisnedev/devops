#!/usr/bin/env bash
set -euo pipefail
cd /mnt/d/source/packages/modular_api/template
echo "PWD: $(pwd)"
echo "Raw listing (including hidden) with visible bytes for names:"
for f in .* *; do
  if [ -e "$f" ]; then
  printf -- "---\nFilename (raw): %s\nHex: " "$f"
  printf -- '%s' "$f" | xxd -p -c 256; echo
  printf -- 'Bytes: '; printf -- '%s' "$f" | xxd -g 1 -c 256; echo
  ls -lad -- "$f" 2>/dev/null || true
  fi
done

echo "\nGlobbing results for build*:" 
ls -la -b build* 2>&1 || true
