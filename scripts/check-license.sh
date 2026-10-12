#!/bin/sh
# Versioning of the installer's licence text ("使用許諾").
#
#   scripts/check-license.sh                       check the templates (installer/resources/*.lproj/license.html)
#   scripts/check-license.sh --rendered JA EN      check rendered screens (the files inside a built .pkg)
#   scripts/check-license.sh --hashes              print the hashes to put into docs/license-history.md
#
# Fails when
#   - the text changed (any character, or LICENSE) but the version in installer/license-version.txt did not,
#   - the Japanese and English screens show different versions / dates,
#   - docs/license-history.md has no row for the current version (or its date / hashes differ),
#   - the MIT text on a screen is not LICENSE, byte for byte,
#   - the CHANGELOG section of the plug-in version does not say "使用許諾：第N版".
set -eu
cd "$(dirname "$0")/.."

TOOL=scripts/license-html.sh
HIST=docs/license-history.md
META=installer/license-version.txt
FAILED=0
fail() { echo "  FAIL  $*" >&2; FAILED=1; }
ok()   { echo "  ok    $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/papat-license-check.XXXXXX")"
cleanup() { rm -f "$TMP"/* 2>/dev/null; rmdir "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

if [ "${1:-}" = "--hashes" ]; then
  for lang in ja en; do
    echo "$lang $($TOOL hash installer/resources/$lang.lproj/license.html)"
  done
  exit 0
fi

if [ "${1:-}" = "--rendered" ]; then
  JA="${2:-}"; EN="${3:-}"
  [ -f "$JA" ] && [ -f "$EN" ] || { echo "usage: $0 --rendered <ja.html> <en.html>" >&2; exit 2; }
else
  for lang in ja en; do
    t="installer/resources/$lang.lproj/license.html"
    [ -f "$t" ] || { fail "$t missing"; continue; }
    $TOOL embed "$t" > "$TMP/$lang.html" || fail "$t: cannot be rendered"
  done
  JA="$TMP/ja.html"; EN="$TMP/en.html"
fi
[ "$FAILED" -eq 0 ] || exit 1

# the version the repository declares
V="$(sed -n 's/^version=\([0-9][0-9]*\)$/\1/p' "$META")"
D="$(sed -n 's/^date=\([0-9-]*\)$/\1/p' "$META")"
[ -n "$V" ] && [ -n "$D" ] || { fail "$META: version / date missing"; exit 1; }
echo "== licence text: version $V ($D)"

# 1. MIT text = LICENSE, nothing left to fill in
for pair in "ja:$JA" "en:$EN"; do
  lang="${pair%%:*}"; f="${pair#*:}"
  if $TOOL verify "$f" LICENSE 2>/dev/null; then ok "$lang: MIT text = LICENSE"; else fail "$lang: MIT text differs from LICENSE"; fi
  if grep -q '@@' "$f"; then fail "$lang: placeholder left in the screen"; else ok "$lang: no placeholder"; fi
done
cmp -s LICENSE papat.lrplugin/LICENSE && ok "papat.lrplugin/LICENSE = LICENSE" || fail "papat.lrplugin/LICENSE differs from LICENSE"

# 2. the same version and date in both languages, and the one declared
VJA="$($TOOL version "$JA")"; VEN="$($TOOL version "$EN")"
if [ "$VJA" = "$VEN" ]; then ok "ja = en: version/date '$VJA'"; else fail "ja shows '$VJA', en shows '$VEN'"; fi
if [ "$VJA" = "$V $D" ]; then ok "screens show the declared version ($V, $D)"; else fail "screens show '$VJA', $META says '$V $D'"; fi

# 3. history
if [ ! -f "$HIST" ]; then fail "$HIST missing"; exit 1; fi
ROWS="$TMP/rows"
awk -F'|' '
  function trim(s) { gsub(/^[ \t`]+|[ \t`]+$/, "", s); return s }
  $2 ~ /^[ \t]*[0-9]+[ \t]*$/ { print trim($2) "\t" trim($3) "\t" trim($4) "\t" trim($5) "\t" trim($6) }
' "$HIST" > "$ROWS"
[ -s "$ROWS" ] || { fail "$HIST has no version rows"; exit 1; }

n=0; prev_date=""
while IFS="$(printf '\t')" read -r rv rdate rja ren rplugin; do
  n=$((n + 1))
  [ "$rv" = "$n" ] || fail "$HIST: versions must be 1, 2, 3 … without gaps (row $n says $rv)"
  case "$rdate" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) fail "$HIST: version $rv: bad date '$rdate'" ;; esac
  if [ -n "$prev_date" ] && [ "$rdate" \< "$prev_date" ]; then fail "$HIST: version $rv is dated before version $((rv - 1))"; fi
  prev_date="$rdate"
  [ -n "$rplugin" ] || fail "$HIST: version $rv: the plug-in version that first carried it is missing"
done < "$ROWS"
LAST="$n"
[ "$LAST" -eq "$V" ] || fail "$HIST ends at version $LAST, $META says $V (raise the version and add the row, or the reverse)"

row="$(awk -F'\t' -v v="$V" '$1 == v' "$ROWS")"
if [ -z "$row" ]; then
  fail "$HIST has no row for version $V"
else
  rdate="$(echo "$row" | cut -f2)"; rja="$(echo "$row" | cut -f3)"; ren="$(echo "$row" | cut -f4)"
  [ "$rdate" = "$D" ] && ok "history: date of version $V" || fail "history says $rdate for version $V, $META says $D"
  hja="$($TOOL hash "$JA" LICENSE)"; hen="$($TOOL hash "$EN" LICENSE)"
  if [ "$hja" = "$rja" ]; then ok "history: ja text unchanged since version $V"; else
    fail "ja text changed but still version $V (hash $hja, history $rja): raise the version and add a row to $HIST"; fi
  if [ "$hen" = "$ren" ]; then ok "history: en text unchanged since version $V"; else
    fail "en text changed but still version $V (hash $hen, history $ren): raise the version and add a row to $HIST"; fi
fi

# 4. CHANGELOG: the plug-in version's section names the licence version
PV="$(sed -n 's/.*VERSION = { major = \([0-9]*\), minor = \([0-9]*\), revision = \([0-9]*\).*/\1.\2.\3/p' papat.lrplugin/Info.lua)"
if awk -v h="## $PV" -v want="使用許諾：第${V}版" '
      $0 == h { on = 1; next }
      /^## / { on = 0 }
      on && index($0, want) { found = 1 }
      END { exit found ? 0 : 1 }' CHANGELOG.md; then
  ok "CHANGELOG $PV: 使用許諾：第${V}版"
else
  fail "CHANGELOG.md section $PV does not say 「使用許諾：第${V}版」"
fi

if [ "$FAILED" -ne 0 ]; then echo "licence text check: FAILED" >&2; exit 1; fi
echo "licence text check: ok"
