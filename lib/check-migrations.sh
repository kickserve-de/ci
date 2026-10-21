#!/usr/bin/env bash
# Lists the migrations a PR adds and checks what can be checked without a database.
# usage: check-migrations.sh <changed file>...   (paths relative to the repo root)
# Shopware: the number in Migration<n>*.php must match getCreationTimestamp().
# Prints a summary line, then one line per finding (the PR table shows the last line).
# Exit 0 clean (or no migrations), 1 findings, 64 usage.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: check-migrations.sh <changed file>..." >&2; exit 64; }

found=() findings=()
for f in "$@"; do
  [ -f "$f" ] || continue
  case "$f" in
    */Migration/Migration[0-9]*.php)
      found+=("${f##*/}")
      want="$(basename "$f" .php | sed -E 's/^Migration([0-9]+).*/\1/')"
      got="$(grep -A3 'function getCreationTimestamp' "$f" | grep -oE 'return [0-9]+' | head -n1 | cut -d' ' -f2 || true)"
      if [ "$got" != "$want" ]; then
        findings+=("${f##*/}: getCreationTimestamp() returns ${got:-nothing}, file name says $want")
      fi
      ;;
    database/migrations/*.php | */Migrations/Version*.php | */Setup/Patch/*/*.php | */ext_tables.sql)
      found+=("${f##*/}")
      ;;
  esac
done

if [ ${#found[@]} -eq 0 ]; then
  echo "no migrations in this PR"
else
  echo "${#found[@]} in this PR, run on deploy: ${found[*]}"
fi
# Findings last: the PR table shows the last line of a failed check.
[ ${#findings[@]} -eq 0 ] || { printf "%s\n" "${findings[@]}"; exit 1; }
