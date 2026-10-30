#!/usr/bin/env bash
# Offline tests for deploy.sh: curl is replaced by a mock that answers from a queue.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fail=0

# run <name> <expected exit> <expected output part> <response>...
run() {
  local name=$1 want_rc=$2 want_out=$3; shift 3
  local dir; dir=$(mktemp -d)
  mkdir "$dir/bin"
  cat > "$dir/bin/curl" <<'MOCK'
#!/usr/bin/env bash
n=$(( $(cat "$MOCK_DIR/n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$MOCK_DIR/n"
echo "$*" >> "$MOCK_DIR/requests"
[ -f "$MOCK_DIR/$n" ] || exit 22
cat "$MOCK_DIR/$n"
MOCK
  chmod +x "$dir/bin/curl"
  local i=1
  for response in "$@"; do printf '%s' "$response" > "$dir/$i"; i=$((i + 1)); done
  local out rc=0
  out=$(PATH="$dir/bin:$PATH" MOCK_DIR=$dir DEPLOY_HOOK='https://forge.test/deploy/2?token=x' FORGE_API_TOKEN=t ORGANIZATION=kickserve SERVER=1 SITE=2 \
    SHA=abc1234 TIMEOUT=60 POLL=0 bash "$here/deploy.sh" 2>&1) || rc=$?
  if [ "$rc" != "$want_rc" ] || [[ "$out" != *"$want_out"* ]]; then
    echo "FAIL $name (exit $rc)"; echo "$out"; fail=1
  else
    echo "ok   $name"
  fi
  rm -rf "$dir"
}

# Responses in order: deployment list before the hook, hook, then list and status polls.
list() { if [ -n "${1:-}" ]; then printf '{"data":[{"id":"%s"}]}' "$1"; else printf '{"data":[]}'; fi; }
state() { printf '{"data":{"attributes":{"status":"%s","commit":{"hash":"%s"}}}}' "$1" "${2:-abc1234}"; }

run "finished" 0 "Forge deployed abc1234" "$(list 6)" "OK" "$(list 7)" "$(state queued)" "$(state deploying)" "$(state finished)"
run "first deployment of the site" 0 "Forge deployed abc1234" "$(list)" "OK" "$(list 7)" "$(state finished)"
run "deployment shows up later" 0 "Forge deployment 7 started" "$(list 6)" "OK" "$(list 6)" "$(list 7)" "$(state finished)"
run "failed build" 1 "failed-build" "$(list 6)" "OK" "$(list 7)" "$(state failed-build)"
run "cancelled" 1 "cancelled" "$(list 6)" "OK" "$(list 7)" "$(state cancelled)"
run "other commit" 1 "instead of abc1234" "$(list 6)" "OK" "$(list 7)" "$(state finished def5678)"
run "hook fails" 1 "deploy hook of site 2 failed" "$(list 6)"
run "api fails" 1 "did not list the deployments"
run "status error then finished" 0 "Forge deployed" "$(list 6)" "OK" "$(list 7)" "" "$(state finished)"

exit $fail
