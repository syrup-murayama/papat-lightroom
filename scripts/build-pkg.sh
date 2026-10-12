#!/bin/sh
# Build the macOS installer package: papat-lightroom-<version>.pkg
#
#   scripts/build-pkg.sh
#       -> unsigned package for local inspection only:
#          dist/unsigned/papat-lightroom-<version>-unsigned.pkg
#
#   PAPAT_INSTALLER_IDENTITY="Developer ID Installer: …" \
#   PAPAT_NOTARY_PROFILE="<notarytool keychain profile>" \
#   scripts/build-pkg.sh
#       -> signed + notarized + stapled release package:
#          dist/papat-lightroom-<version>.pkg and .pkg.sha256
#
# Secrets: this script never contains or prints a certificate, key, Apple ID or
# password. The identity *name* and the notarytool *profile name* come from the
# environment; the credentials stay in the macOS keychain (see docs/guide-signing.md).
set -eu
cd "$(dirname "$0")/.."

IDENTIFIER="app.papat.lightroom.pkg"
INSTALL_LOCATION="/Library/Application Support/Adobe/Lightroom/Modules"
PKG_NAME_BASE="papat-lightroom"

die() { echo "error: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS is required (pkgbuild / productbuild)"
for tool in pkgbuild productbuild pkgutil ditto shasum; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done
[ -f papat.lrplugin/Info.lua ] || die "papat.lrplugin/Info.lua not found"

VERSION="$(sed -n 's/.*VERSION = { major = \([0-9]*\), minor = \([0-9]*\), revision = \([0-9]*\).*/\1.\2.\3/p' papat.lrplugin/Info.lua)"
[ -n "$VERSION" ] || die "could not read the version from papat.lrplugin/Info.lua"

IDENTITY="${PAPAT_INSTALLER_IDENTITY:-}"
PROFILE="${PAPAT_NOTARY_PROFILE:-}"

if [ -n "$PROFILE" ] && [ -z "$IDENTITY" ]; then
  die "PAPAT_NOTARY_PROFILE is set but PAPAT_INSTALLER_IDENTITY is not (notarization needs a signed package)"
fi

OUT="dist"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/papat-pkg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

echo "== papat for Lightroom Classic $VERSION"

# 1. Payload: a clean copy of the plug-in (no extended attributes / resource forks)
PAYLOAD="$WORK/payload"
mkdir -p "$PAYLOAD"
ditto --norsrc --noextattr --noqtn papat.lrplugin "$PAYLOAD/papat.lrplugin"
find "$PAYLOAD" -name '.DS_Store' -delete
find "$PAYLOAD" -type d -exec chmod 755 {} +
find "$PAYLOAD" -type f -exec chmod 644 {} +

UNEXPECTED="$(find "$PAYLOAD/papat.lrplugin" -type f ! -name '*.lua' ! -name LICENSE)"
if [ -n "$UNEXPECTED" ]; then
  echo "unexpected files in the plug-in folder:" >&2
  echo "$UNEXPECTED" >&2
  exit 1
fi

# 2. Component package: installs <install-location>/papat.lrplugin, runs the scripts
COMPONENT="$WORK/component.pkg"
pkgbuild \
  --root "$PAYLOAD" \
  --install-location "$INSTALL_LOCATION" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --scripts installer/scripts \
  --ownership recommended \
  "$COMPONENT" >/dev/null

# 3. Product archive: distribution (current-user home only) + localized screens.
#    The licence screens carry the MIT text taken from LICENSE (scripts/license-html.sh);
#    the plug-in's own LICENSE copy must be the same file.
cmp -s LICENSE papat.lrplugin/LICENSE || die "papat.lrplugin/LICENSE differs from LICENSE"
RESOURCES="$WORK/resources"
cp -R installer/resources "$RESOURCES"
for lang in ja en; do
  template="installer/resources/$lang.lproj/license.html"
  [ -f "$template" ] || die "$template not found"
  scripts/license-html.sh embed "$template" > "$RESOURCES/$lang.lproj/license.html"
  scripts/license-html.sh verify "$RESOURCES/$lang.lproj/license.html" \
    || die "the licence screen ($lang) does not carry LICENSE"
done
# version / history / hashes (fails when the text changed under the same version)
scripts/check-license.sh --rendered "$RESOURCES/ja.lproj/license.html" "$RESOURCES/en.lproj/license.html" \
  || die "the licence text is not consistent with its version (docs/license-history.md)"
sed "s/@VERSION@/$VERSION/g" installer/distribution.xml.in > "$WORK/distribution.xml"
UNSIGNED="$WORK/unsigned.pkg"
productbuild \
  --distribution "$WORK/distribution.xml" \
  --resources "$RESOURCES" \
  --package-path "$WORK" \
  --version "$VERSION" \
  "$UNSIGNED" >/dev/null

# 4. Without a signing identity: stop here (local inspection only)
if [ -z "$IDENTITY" ]; then
  mkdir -p "$OUT/unsigned"
  DEST="$OUT/unsigned/$PKG_NAME_BASE-$VERSION-unsigned.pkg"
  cp "$UNSIGNED" "$DEST"
  echo "built (UNSIGNED, not for distribution): $DEST"
  echo "inspect it with:  scripts/verify-pkg.sh \"$DEST\""
  echo "to sign + notarize: set PAPAT_INSTALLER_IDENTITY and PAPAT_NOTARY_PROFILE (docs/guide-signing.md)"
  exit 0
fi

# 5. Sign (Developer ID Installer)
SIGNED="$WORK/signed.pkg"
echo "== signing"
productsign --sign "$IDENTITY" "$UNSIGNED" "$SIGNED"
pkgutil --check-signature "$SIGNED"

# 6. Notarize
if [ -z "$PROFILE" ]; then
  mkdir -p "$OUT/not-notarized"
  DEST="$OUT/not-notarized/$PKG_NAME_BASE-$VERSION-signed-not-notarized.pkg"
  cp "$SIGNED" "$DEST"
  echo "built (signed, NOT notarized, not for distribution): $DEST"
  echo "set PAPAT_NOTARY_PROFILE to notarize (docs/guide-signing.md)"
  exit 0
fi

LOGDIR="$OUT/notary-logs/$VERSION-$STAMP"
mkdir -p "$LOGDIR"
SUBMIT_JSON="$LOGDIR/submit.json"

echo "== notarizing (this waits for Apple; usually a few minutes)"
set +e
xcrun notarytool submit "$SIGNED" \
  --keychain-profile "$PROFILE" \
  --wait \
  --output-format json > "$SUBMIT_JSON"
SUBMIT_RC=$?
set -e

json_value() {
  # $1 = key, $2 = file. plutil reads JSON; fall back to a plain grep.
  plutil -extract "$1" raw -o - "$2" 2>/dev/null \
    || sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p" "$2" | head -n 1
}

SUBMISSION_ID="$(json_value id "$SUBMIT_JSON" || true)"
STATUS="$(json_value status "$SUBMIT_JSON" || true)"
echo "submission: ${SUBMISSION_ID:-unknown}  status: ${STATUS:-unknown}"

if [ "$SUBMIT_RC" -ne 0 ] || [ "$STATUS" != "Accepted" ]; then
  echo "notarization did not succeed. Fetching Apple's log:" >&2
  if [ -n "$SUBMISSION_ID" ]; then
    xcrun notarytool log "$SUBMISSION_ID" "$LOGDIR/notary-log.json" \
      --keychain-profile "$PROFILE" || true
    echo "log saved to: $LOGDIR/notary-log.json" >&2
  fi
  echo "submit output saved to: $SUBMIT_JSON" >&2
  exit 1
fi

# 7. Staple the ticket so it also verifies offline, then verify
echo "== stapling"
xcrun stapler staple "$SIGNED"
xcrun stapler validate "$SIGNED"

echo "== verification"
pkgutil --check-signature "$SIGNED"
spctl -a -vv -t install "$SIGNED"

# 8. Release artefacts (checksum is computed after stapling)
DEST="$OUT/$PKG_NAME_BASE-$VERSION.pkg"
cp "$SIGNED" "$DEST"
(cd "$OUT" && shasum -a 256 "$PKG_NAME_BASE-$VERSION.pkg" > "$PKG_NAME_BASE-$VERSION.pkg.sha256")

echo "built: $DEST"
cat "$OUT/$PKG_NAME_BASE-$VERSION.pkg.sha256"
