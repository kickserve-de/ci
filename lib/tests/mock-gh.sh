#!/usr/bin/env bash
# Offline `gh api` replacement: answers GET <path> from $MOCK_GH_DIR/<path with /?&= as _>.json
# (missing file = HTTP error, exit 1) and applies --jq like gh (raw strings). Requests go to $MOCK_GH_DIR/calls.
set -euo pipefail
[ "${1:-}" = api ] || { echo "mock-gh: only 'gh api' is supported" >&2; exit 2; }
shift
path="" filter=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq) filter=$2; shift 2 ;;
    --paginate) shift ;;
    -*) echo "mock-gh: unsupported option $1" >&2; exit 2 ;;
    *) path=$1; shift ;;
  esac
done
echo "$path" >> "$MOCK_GH_DIR/calls"
file="$MOCK_GH_DIR/$(tr '/?&=' '____' <<< "$path").json"
[ -f "$file" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
if [ -n "$filter" ]; then jq -r "$filter" "$file"; else cat "$file"; fi
