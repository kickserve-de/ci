#!/usr/bin/env bash
# Offline curl replacement: consume one queued response per request.
set -euo pipefail
if [ -n "${MOCK_EXPECT_USER:-}" ] && [ "${USER:-}" != "$MOCK_EXPECT_USER" ]; then
  exit 2
fi
method=GET url="" payload="" write_out=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    -H) shift 2 ;;
    -d) payload=$2; shift 2 ;;
    -w|--write-out) write_out=true; shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
jq -nc --arg method "$method" --arg url "$url" --arg payload "$payload" \
  '{method: $method, url: $url, payload: $payload}' >> "$MOCK_DIR/requests"
n=$(wc -l < "$MOCK_DIR/requests")
response="$MOCK_DIR/$n.json"
if [ ! -f "$response" ]; then
  printf '{"errors":[{"message":"Unexpected request"}]}'
  $write_out && printf '\n400'
  exit 22
fi
jq -jr '.body' "$response"
$write_out && jq -jr '"\n" + .status' "$response"
# Deliberately unsafe curl stderr must never be copied into updater diagnostics.
rc=$(jq -r '.rc' "$response")
if [ "$rc" -ne 0 ]; then
  printf 'curl failure: %s %s\n' 'Authorization: Bearer' "$TASK_TOKEN" >&2
fi
exit "$rc"
