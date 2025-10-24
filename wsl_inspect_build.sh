#!/usr/bin/env bash
set -euo pipefail
cd /mnt/d/source/packages/modular_api/template
echo 'PWD:' $(pwd)
echo 'LS all in project:'
ls -la .
echo 'CHECK build entry:'
if [ -e build ]; then
  echo 'build exists'
  echo 'ls -lad build:'
  ls -lad build || true
  echo 'stat build:'
  stat build || true
  echo 'file build:'
  file build || true
  echo 'readlink build:'
  readlink build || true
else
  echo 'build does not exist'
fi
