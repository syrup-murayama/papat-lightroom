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
APP_IDENTITY="${PAPAT_APP_IDENTITY:-}"

if [ -n "$PROFILE" ] && [ -z "$IDENTITY" ]; then
  die "PAPAT_NOTARY_PROFILE is set but PAPAT_INSTALLER_IDENTITY is not (notarization needs a signed package)"
fi
# Apple's notary service refuses a package that contains an unsigned Mach-O executable (or one
# without the hardened runtime): "The binary is not signed with a valid Developer ID
# certificate" / "does not have the hardened runtime enabled". papat-fprint is such a binary,
# so once notarization is requested, signing it is no longer optional (docs/guide-signing.md §1b).
if [ -n "$PROFILE" ] && [ -z "$APP_IDENTITY" ]; then
  die "PAPAT_NOTARY_PROFILE is set but PAPAT_APP_IDENTITY is not — notarization rejects an unsigned papat-fprint (docs/guide-signing.md §1b)"
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

# 1b. The similarity helper (Vision feature prints; macOS only, no networking — see
#     tools/papat-fprint/main.swift). Built fresh every time (universal: Apple silicon + Intel,
#     whichever Mac runs this script); never checked into the repo and never present in
#     papat.lrplugin/ outside this payload copy.
command -v xcrun >/dev/null 2>&1 || die "xcrun not found (install the Xcode command line tools)"
command -v lipo >/dev/null 2>&1 || die "lipo not found (install the Xcode command line tools)"
FPRINT_SRC="tools/papat-fprint/main.swift"
[ -f "$FPRINT_SRC" ] || die "$FPRINT_SRC not found"
FPRINT_BIN="$PAYLOAD/papat.lrplugin/bin/papat-fprint"
mkdir -p "$(dirname "$FPRINT_BIN")"
xcrun swiftc -O -target arm64-apple-macosx11.0 -o "$WORK/papat-fprint-arm64" "$FPRINT_SRC"
xcrun swiftc -O -target x86_64-apple-macosx10.15 -o "$WORK/papat-fprint-x86_64" "$FPRINT_SRC"
lipo -create -output "$FPRINT_BIN" "$WORK/papat-fprint-arm64" "$WORK/papat-fprint-x86_64"
chmod 755 "$FPRINT_BIN"

# Signing (Developer ID Application, hardened runtime): a *different* certificate type than
# the outer .pkg's own (PAPAT_INSTALLER_IDENTITY). Required once PAPAT_NOTARY_PROFILE is set
# (checked above); otherwise optional — without it, this binary ships unsigned, fine for local
# inspection. The plug-in's own fallback (no `group` sent) is the same either way (lib/similarity.lua).
if [ -n "$APP_IDENTITY" ]; then
  echo "== signing the similarity helper"
  codesign --force --options runtime --timestamp --sign "$APP_IDENTITY" "$FPRINT_BIN"
  codesign --verify --strict "$FPRINT_BIN"
else
  echo "note: PAPAT_APP_IDENTITY not set; papat-fprint ships unsigned this time (docs/guide-signing.md)" >&2
fi

UNEXPECTED="$(find "$PAYLOAD/papat.lrplugin" -type f ! -name '*.lua' ! -name LICENSE ! -name papat-fprint)"
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
