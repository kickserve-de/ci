#!/usr/bin/env bash
# Compares snippet translation files per directory.
# usage: check-translations.sh <dir>...
# Files are grouped by the name before the locale (storefront.de-DE.json -> storefront).
# Prints "missing <locale> <file> <key>", "empty <locale> <file> <key>", "invalid <file>".
# Exit 0 clean, 1 findings, 64 usage.

{ set +x; } 2>/dev/null

usage() { echo "usage: check-translations.sh <dir>..." >&2; exit 64; }

[ "$#" -ge 1 ] || usage
for d in "$@"; do [ -d "$d" ] || { echo "not a directory: $d" >&2; exit 64; }; done

flat() { jq -r 'paths(scalars) as $p | ($p | map(tostring) | join("."))' "$1"; }

rc=0
for dir in "$@"; do
  dir="${dir%/}"
  groups=""
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    b="${f##*/}"; b="${b%.json}"
    loc="${b##*.}"
    case "$loc" in [a-z][a-z]-[A-Z][A-Z]) ;; *) continue ;; esac
    g="${b%.*}"
    groups="$groups
$g"
  done
  for g in $(printf '%s\n' "$groups" | grep . | sort -u); do
    files=""; union=""
    for f in "$dir/$g".*.json; do
      b="${f##*/}"; b="${b%.json}"; loc="${b##*.}"
      case "$loc" in [a-z][a-z]-[A-Z][A-Z]) ;; *) continue ;; esac
      [ "${b%.*}" = "$g" ] || continue
      if ! jq -e . "$f" >/dev/null 2>&1; then
        echo "invalid $f"; rc=1; continue
      fi
      files="$files
$f"
      union="$union
$(flat "$f")"
    done
    union="$(printf '%s\n' "$union" | grep . | sort -u)"
    for f in $(printf '%s\n' "$files" | grep .); do
      b="${f##*/}"; loc="${b%.json}"; loc="${loc##*.}"
      keys="$(flat "$f" | sort -u)"
      while IFS= read -r k; do
        [ -n "$k" ] || continue
        echo "missing $loc $f $k"; rc=1
      done < <(comm -13 <(printf '%s\n' "$keys") <(printf '%s\n' "$union"))
      while IFS= read -r k; do
        [ -n "$k" ] || continue
        echo "empty $loc $f $k"; rc=1
      done < <(jq -r 'paths(scalars) as $p | select(getpath($p) == "") | ($p | map(tostring) | join("."))' "$f")
    done
  done
done
exit "$rc"
