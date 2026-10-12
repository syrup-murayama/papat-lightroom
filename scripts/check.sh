#!/bin/sh
# Syntax check (luac -p) + unit tests + smoke tests. Run from anywhere.
set -eu
cd "$(dirname "$0")/.."

if ! command -v luac >/dev/null 2>&1; then
  echo "luac not found (brew install lua)" >&2
  exit 1
fi

echo "== luac -p"
find papat.lrplugin -name '*.lua' -print0 | xargs -0 -n1 luac -p
echo "ok"

echo "== unit tests"
lua tests/run.lua
echo "== smoke tests"
lua tests/smoke.lua

echo "== installer licence screens (version, history, MIT text)"
scripts/check-license.sh
