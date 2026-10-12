#!/bin/sh
# Inspect a papat .pkg without installing it: payload location, scripts, domains.
#   scripts/verify-pkg.sh dist/unsigned/papat-lightroom-<version>-unsigned.pkg
set -eu
cd "$(dirname "$0")/.."

PKG="${1:-}"
[ -f "$PKG" ] || { echo "usage: $0 <file.pkg>" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/papat-verify-pkg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FAILED=0
ok()   { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; FAILED=1; }

pkgutil --expand-full "$PKG" "$WORK/expanded"
COMP="$WORK/expanded/component.pkg"
[ -d "$COMP" ] || { echo "component.pkg not found in $PKG" >&2; exit 1; }

echo "== distribution"
DIST="$WORK/expanded/Distribution"
grep -q 'enable_currentUserHome="true"' "$DIST" && ok 'enable_currentUserHome="true"' || fail 'enable_currentUserHome is not true'
grep -q 'enable_localSystem="false"' "$DIST" && ok 'enable_localSystem="false"' || fail 'enable_localSystem is not false'
grep -q 'enable_anywhere="false"' "$DIST" && ok 'enable_anywhere="false"' || fail 'enable_anywhere is not false'
grep -q '<title>papat for Lightroom Classic</title>' "$DIST" && ok 'title' || fail 'title'
grep -q 'conclusion' "$DIST" && ok 'conclusion screen' || fail 'conclusion screen'
grep -q '<license file="license.html"' "$DIST" && ok 'licence screen' || fail 'licence screen (<license>) missing'

echo "== component"
INFO="$COMP/PackageInfo"
grep -q 'identifier="app.papat.lightroom.pkg"' "$INFO" && ok 'identifier app.papat.lightroom.pkg' || fail 'identifier'
grep -q 'install-location="/Library/Application Support/Adobe/Lightroom/Modules"' "$INFO" \
  && ok 'install-location = /Library/Application Support/Adobe/Lightroom/Modules (home-relative in a user install)' \
  || fail 'install-location'
sed -n 's/.*<pkg-info .* version="\([^"]*\)" format-version.*/        version=\1/p' "$INFO" | head -n 1

echo "== payload"
if [ -f "$COMP/Payload/papat.lrplugin/Info.lua" ]; then ok 'papat.lrplugin/Info.lua'; else fail 'papat.lrplugin/Info.lua missing'; fi
if [ -f "$COMP/Payload/papat.lrplugin/lib/api.lua" ]; then ok 'papat.lrplugin/lib/api.lua'; else fail 'lib/api.lua missing'; fi
OTHER="$(cd "$COMP/Payload" && find . -mindepth 1 -maxdepth 1 ! -name papat.lrplugin)"
[ -z "$OTHER" ] && ok 'payload contains only papat.lrplugin' || fail "unexpected payload entries: $OTHER"
STRAY="$(find "$COMP/Payload" \( -name '.DS_Store' -o -name '._*' \))"
[ -z "$STRAY" ] && ok 'no .DS_Store / AppleDouble files' || fail "stray files: $STRAY"
NONLUA="$(find "$COMP/Payload/papat.lrplugin" -type f ! -name '*.lua' ! -name LICENSE)"
[ -z "$NONLUA" ] && ok 'only .lua files and LICENSE' || fail "unexpected files: $NONLUA"

echo "== scripts"
for s in preinstall postinstall; do
  F="$COMP/Scripts/$s"
  if [ -x "$F" ]; then ok "$s is present and executable"; else fail "$s missing or not executable"; fi
done
grep -q 'papat-lightroom-backups' "$COMP/Scripts/preinstall" && ok 'preinstall backs up an existing copy' || fail 'preinstall backup'
grep -q 'sudo' "$COMP/Scripts/preinstall" "$COMP/Scripts/postinstall" && fail 'scripts mention sudo' || ok 'no sudo in scripts'

echo "== resources"
for f in ja.lproj/welcome.html ja.lproj/license.html ja.lproj/conclusion.html \
         en.lproj/welcome.html en.lproj/license.html en.lproj/conclusion.html; do
  [ -f "$WORK/expanded/Resources/$f" ] && ok "$f" || fail "$f missing"
done

echo "== licence text"
# the MIT text on the licence screens is LICENSE, byte for byte (also: nothing left to fill in)
for lang in ja en; do
  f="$WORK/expanded/Resources/$lang.lproj/license.html"
  [ -f "$f" ] || continue
  if scripts/license-html.sh verify "$f" LICENSE 2>/dev/null; then ok "$lang licence screen = LICENSE"; else fail "$lang licence screen differs from LICENSE"; fi
  grep -q '@@MIT_LICENSE@@' "$f" && fail "$lang licence screen still has the placeholder" || ok "$lang licence screen: no placeholder"
done
# version line, history row and hashes of what is really inside the .pkg
if [ -f "$WORK/expanded/Resources/ja.lproj/license.html" ] && [ -f "$WORK/expanded/Resources/en.lproj/license.html" ]; then
  if scripts/check-license.sh --rendered "$WORK/expanded/Resources/ja.lproj/license.html" "$WORK/expanded/Resources/en.lproj/license.html" > "$WORK/license-check.txt" 2>&1; then
    ok "licence text: $(scripts/license-html.sh version "$WORK/expanded/Resources/ja.lproj/license.html" | sed 's/ / (/;s/$/)/') matches docs/license-history.md"
  else
    sed 's/^/        /' "$WORK/license-check.txt"; fail "licence text: version / history check failed"
  fi
fi
if [ -f "$COMP/Payload/papat.lrplugin/LICENSE" ]; then
  cmp -s "$COMP/Payload/papat.lrplugin/LICENSE" LICENSE && ok 'payload LICENSE = LICENSE' || fail 'payload LICENSE differs from LICENSE'
fi

echo "== signature"
pkgutil --check-signature "$PKG" 2>&1 | sed 's/^/        /' || true

if [ "$FAILED" -ne 0 ]; then
  echo "RESULT: FAILED"
  exit 1
fi
echo "RESULT: ok"
