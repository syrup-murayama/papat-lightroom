#!/bin/sh
# Build dist/papat-lightroom-<version>.zip and its .sha256 from papat.lrplugin/.
# The ZIP contains two top-level entries: the folder papat.lrplugin/ and the
# instructions はじめにお読みください.txt (package-files/).
#
# Like scripts/build-pkg.sh, papat.lrplugin/bin/papat-fprint (the similarity helper; macOS
# only, no networking — see tools/papat-fprint/main.swift) is built fresh into the staging
# copy, never checked into the repository. Unlike build-pkg.sh's .pkg, this ZIP is never
# notarized, so the binary ships UNSIGNED: on a Mac that downloaded it (quarantined by
# Gatekeeper), running it may be blocked the first time. lib/similarity.lua already treats a
# helper that cannot run as just another "could not refine" outcome — the gallery falls back
# to time groups, and the send itself is never held up either way.
set -eu
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/.*VERSION = { major = \([0-9]*\), minor = \([0-9]*\), revision = \([0-9]*\).*/\1.\2.\3/p' papat.lrplugin/Info.lua)"
[ -n "$VERSION" ] || { echo "could not read the version from papat.lrplugin/Info.lua" >&2; exit 1; }

OUT="dist"
NAME="papat-lightroom-${VERSION}.zip"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/papat-package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$OUT"
rm -f "$OUT/$NAME" "$OUT/$NAME.sha256"

cp -R papat.lrplugin "$STAGE/papat.lrplugin"
find "$STAGE" -name '.DS_Store' -delete

# The similarity helper (universal: arm64 + x86_64), unsigned — see the header comment above.
if [ "$(uname -s)" = "Darwin" ] && command -v xcrun >/dev/null 2>&1 && command -v lipo >/dev/null 2>&1; then
  FPRINT_SRC="tools/papat-fprint/main.swift"
  [ -f "$FPRINT_SRC" ] || { echo "$FPRINT_SRC not found" >&2; exit 1; }
  FPRINT_BIN="$STAGE/papat.lrplugin/bin/papat-fprint"
  mkdir -p "$(dirname "$FPRINT_BIN")"
  xcrun swiftc -O -target arm64-apple-macosx11.0 -o "$STAGE/papat-fprint-arm64" "$FPRINT_SRC"
  xcrun swiftc -O -target x86_64-apple-macosx10.15 -o "$STAGE/papat-fprint-x86_64" "$FPRINT_SRC"
  lipo -create -output "$FPRINT_BIN" "$STAGE/papat-fprint-arm64" "$STAGE/papat-fprint-x86_64"
  chmod 755 "$FPRINT_BIN"
else
  echo "note: not building on macOS with Xcode command line tools; papat.lrplugin/bin/papat-fprint will be missing" >&2
  echo "      (the plug-in still works: no helper = similarity is skipped, galleries use time groups)" >&2
fi

# Fail loudly if a stray non-Lua / hidden file would ship.
UNEXPECTED="$(find "$STAGE/papat.lrplugin" -type f ! -name '*.lua' ! -name LICENSE ! -name papat-fprint)"
if [ -n "$UNEXPECTED" ]; then
  echo "unexpected files in plugin folder:" >&2
  echo "$UNEXPECTED" >&2
  exit 1
fi

INSTRUCTIONS="はじめにお読みください.txt"
[ -f "package-files/$INSTRUCTIONS" ] || { echo "missing package-files/$INSTRUCTIONS" >&2; exit 1; }
cp "package-files/$INSTRUCTIONS" "$STAGE/$INSTRUCTIONS"

ROOT="$(pwd)"
(cd "$STAGE" && zip -qr -X "$ROOT/$OUT/$NAME" papat.lrplugin "$INSTRUCTIONS")

(cd "$OUT" && shasum -a 256 "$NAME" > "$NAME.sha256")

echo "built: $OUT/$NAME"
cat "$OUT/$NAME.sha256"
