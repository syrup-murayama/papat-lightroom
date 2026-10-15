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
echo "== grouping (cross-check against the gallery's JS; skipped without node)"
lua tests/grouping.lua

echo "== installer licence screens (version, history, MIT text)"
scripts/check-license.sh

echo "== build-pkg.sh: PAPAT_APP_IDENTITY is required once notarizing (audit 15 §1.5)"
BUILDPKG_OUT="$(mktemp "${TMPDIR:-/tmp}/papat-buildpkg-check.XXXXXX")"
trap 'rm -f "$BUILDPKG_OUT"' EXIT
if PAPAT_INSTALLER_IDENTITY=x PAPAT_NOTARY_PROFILE=y scripts/build-pkg.sh >"$BUILDPKG_OUT" 2>&1; then
  echo "expected scripts/build-pkg.sh to refuse (PAPAT_APP_IDENTITY missing) but it built something:" >&2
  cat "$BUILDPKG_OUT" >&2
  exit 1
fi
grep -q 'PAPAT_APP_IDENTITY' "$BUILDPKG_OUT" || {
  echo "scripts/build-pkg.sh refused, but not for the expected reason:" >&2
  cat "$BUILDPKG_OUT" >&2
  exit 1
}
rm -f "$BUILDPKG_OUT"
trap - EXIT
echo "ok"
