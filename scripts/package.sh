#!/bin/sh
# Build dist/papat-lightroom-<version>.zip and its .sha256 from papat.lrplugin/.
# The ZIP contains two top-level entries: the folder papat.lrplugin/ and the
# instructions はじめにお読みください.txt (package-files/).
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

# Fail loudly if a stray non-Lua / hidden file would ship.
UNEXPECTED="$(find "$STAGE/papat.lrplugin" -type f ! -name '*.lua' ! -name LICENSE)"
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
