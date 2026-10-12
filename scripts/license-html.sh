#!/bin/sh
# The installer's licence screens: MIT text from LICENSE, version line from
# installer/license-version.txt, both inserted at build time (never copied by hand).
#
#   license-html.sh embed <template.html> [LICENSE]     rendered screen (stdout)
#   license-html.sh extract <html>                      the text inside <pre id="mit-license">, unescaped
#   license-html.sh verify <rendered.html> [LICENSE]    0 when that text equals LICENSE, byte for byte
#   license-html.sh canonical <html> [LICENSE]          the text whose hash identifies a version: MIT text
#                                                        embedded, version line replaced by its placeholder
#   license-html.sh hash <html> [LICENSE]               sha256 of `canonical`
#   license-html.sh version <html>                      "<version> <date>" shown by a rendered screen
#
# A template has the lines   @@LICENSE_VERSION_LINE@@   and   @@MIT_LICENSE@@   (each on its own).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
META="$ROOT/installer/license-version.txt"
mode="${1:-}"; file="${2:-}"; lic="${3:-$ROOT/LICENSE}"
usage() { echo "usage: $0 embed|extract|verify|canonical|hash|version <html> [LICENSE]" >&2; exit 2; }
[ -f "$file" ] || usage

meta_value() { sed -n "s/^$1=\\(.*\\)\$/\\1/p" "$META" | head -n 1; }

lang_of() { sed -n 's/^<html lang="\([a-z][a-z]*\)".*/\1/p' "$1" | head -n 1; }

# <p id="license-version" data-version=".." data-date="..">第1版　2026年10月12日</p>
version_line() { # lang
  v="$(meta_value version)"; d="$(meta_value date)"
  case "$v" in ''|*[!0-9]*) echo "installer/license-version.txt: bad version '$v'" >&2; return 1 ;; esac
  case "$d" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) echo "installer/license-version.txt: bad date '$d'" >&2; return 1 ;; esac
  y="${d%%-*}"; rest="${d#*-}"; m="${rest%%-*}"; day="${rest#*-}"
  m=$((10#$m)); day=$((10#$day))
  case "$1" in
    ja) label="第${v}版　${y}年${m}月${day}日" ;;
    en)
      set -- "$1" January February March April May June July August September October November December
      shift "$m"
      label="Version ${v} — $1 ${day}, ${y}" ;;
    *) echo "no version-line format for language '$1'" >&2; return 1 ;;
  esac
  printf '<p id="license-version" data-version="%s" data-date="%s">%s</p>\n' "$v" "$d" "$label"
}

# MIT text inserted (HTML-escaped) where @@MIT_LICENSE@@ stands
embed_mit() { # template lic
  awk -v lic="$2" '
    /^@@MIT_LICENSE@@$/ {
      while ((getline line < lic) > 0) {
        gsub(/&/, "\\&amp;", line); gsub(/</, "\\&lt;", line); gsub(/>/, "\\&gt;", line)
        print line
      }
      close(lic); n++; next
    }
    { print }
    END { if (n != 1) { print "template must contain exactly one @@MIT_LICENSE@@ line" > "/dev/stderr"; exit 1 } }
  ' "$1"
}

case "$mode" in
  embed)
    lang="$(lang_of "$file")"
    line="$(version_line "$lang")"
    grep -c '^@@LICENSE_VERSION_LINE@@$' "$file" | grep -qx 1 \
      || { echo "template must contain exactly one @@LICENSE_VERSION_LINE@@ line" >&2; exit 1; }
    embed_mit "$file" "$lic" | awk -v vline="$line" '/^@@LICENSE_VERSION_LINE@@$/ { print vline; next } { print }'
    ;;
  extract)
    awk '
      /^<pre id="mit-license">$/ { on = 1; next }
      /^<\/pre>$/ { if (on) exit }
      on { print }
    ' "$file" | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g'
    ;;
  verify)
    tmp="$(mktemp "${TMPDIR:-/tmp}/papat-license.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    "$0" extract "$file" > "$tmp"
    [ -s "$tmp" ] || { echo "no MIT text in $file" >&2; exit 1; }
    cmp -s "$tmp" "$lic" || { echo "MIT text in $file differs from LICENSE" >&2; exit 1; }
    ;;
  canonical)
    tmp="$(mktemp "${TMPDIR:-/tmp}/papat-license.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    if grep -q '^@@MIT_LICENSE@@$' "$file"; then embed_mit "$file" "$lic" > "$tmp"; else cat "$file" > "$tmp"; fi
    awk '/^<p id="license-version" / { print "@@LICENSE_VERSION_LINE@@"; next } { print }' "$tmp"
    ;;
  hash)
    if command -v shasum >/dev/null 2>&1; then sum="shasum -a 256"; else sum="sha256sum"; fi
    "$0" canonical "$file" "$lic" | $sum | awk '{ print $1 }'
    ;;
  version)
    if grep -q '^@@LICENSE_VERSION_LINE@@$' "$file"; then
      echo "$(meta_value version) $(meta_value date)"
    else
      sed -n 's/^<p id="license-version" data-version="\([0-9]*\)" data-date="\([0-9-]*\)">.*/\1 \2/p' "$file" | head -n 1
    fi
    ;;
  *) usage ;;
esac
