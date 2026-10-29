#!/usr/bin/env bash
# Offline tests for release-tasks: tasks.jq (IDs from commit messages) and update.sh against the
# task-sync curl mock. No token or network required.
# Assertions are static shell expressions evaluated by check(), not expanded here.
# shellcheck disable=SC2016
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
TS="$DIR/../task-sync"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
ln -s "$TS/tests/mock-curl.sh" "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" TASK_TOKEN=offline-secret-sentinel TASK_API=""
export VERSION=14 RELEASE_URL=https://github.com/o/r/releases/tag/14 DONE_SECTION="" READY_SECTION=""
PASS=0 FAIL=0
export RC=0
A=1219595984767913 B=17919966507813712

check() {
  if eval "$2"; then
    PASS=$((PASS + 1)); echo "ok   $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL $1"
    cat "$MOCK_DIR/out" "$MOCK_DIR/err" "$MOCK_DIR/summary" 2> /dev/null || true
  fi
}

echo "── tasks.jq"
ids() { jq -r -L "$TS" -f "$DIR/tasks.jq" <<< "$1" | paste -sd' ' -; }
check "first ID per commit, each once, merge commits via branch" \
  '[[ "$(ids "[\"feat: a ($A)\", \"Merge pull request #3 from o/feat/x-$B\n\nTitle\", \"fix: again $A, see $B\", \"chore: none\"]")" == "$A $B" ]]'
check "task URL yields the task, not the project" \
  '[[ "$(ids "[\"fix: https://app.asana.com/0/9999999999999999/$A/f\"]")" == "$A" ]]'
check "no IDs → nothing" '[[ -z "$(ids "[\"chore: x\"]")" ]]'

echo "── update.sh"
MEMBERS='{"data":{"memberships":[{"project":{"gid":"9"},"section":{"name":"Ready for Deployment"}}]}}'
SECTIONS='{"data":[{"gid":"10","name":"Ready for Deployment"},{"gid":"11","name":"Done"}]}'
EMPTY='{"data":[],"next_page":null}'
POSTED="{\"data\":[{\"gid\":\"5\",\"type\":\"comment\",\"created_by\":{\"gid\":\"7\"},\"html_text\":\"<body>Live mit Version 14: <a href=\\\"$RELEASE_URL\\\">x</a></body>\"}],\"next_page\":null}"

start() {
  export MOCK_DIR="$TMP/case-$((PASS + FAIL))" SUMMARY
  mkdir "$MOCK_DIR"
  : > "$MOCK_DIR/requests"
  SUMMARY="$MOCK_DIR/summary"
  printf '%s\n' "${1-$A}" > "$MOCK_DIR/tasks.txt"
  N=0 DONE_SECTION="" READY_SECTION="" TASK_API=""
}
respond() {
  N=$((N + 1))
  jq -n --arg body "$1" --arg status "${2:-200}" --argjson rc "${3:-0}" \
    '{body: $body, status: $status, rc: $rc}' > "$MOCK_DIR/$N.json"
}
run() {
  RC=0
  bash "$DIR/update.sh" "$MOCK_DIR/tasks.txt" > "$MOCK_DIR/out" 2> "$MOCK_DIR/err" || RC=$?
}
writes() { jq -sc '[.[] | select(.method != "GET") | .url | sub("^https://[^/]+/api/1.0"; "")]' "$MOCK_DIR/requests"; }
clean_errors() { ! grep -Eq 'jq: error|parse error|offline-secret-sentinel|Bearer' "$MOCK_DIR/err"; }

start; respond "$MEMBERS"; respond "$SECTIONS"; respond "$EMPTY"; respond '{"data":{}}'; respond '{"data":{}}'; run
check "moves to Done, then posts the German comment with the release link" \
  '[[ $RC == 0 ]] && [[ $(writes) == "[\"/sections/11/addTask\",\"/tasks/$A/stories\"]" ]] &&
   jq -se --arg url "$RELEASE_URL" ".[4].payload | fromjson | .data.html_text == \"<body>Live mit Version 14: <a href=\\\"\" + \$url + \"\\\">\" + \$url + \"</a></body>\"" "$MOCK_DIR/requests" > /dev/null &&
   grep -q "moved to Done | posted" "$MOCK_DIR/summary" && ! grep -q completed "$MOCK_DIR/requests"'

start; respond '{"data":{"memberships":[{"project":{"gid":"9"},"section":{"name":"done"}}]}}'; respond "$POSTED"; run
check "rerun: already in Done and comment there → no writes" \
  '[[ $RC == 0 ]] && [[ $(writes) == "[]" ]] && grep -q "not moved (.*) | already there" "$MOCK_DIR/summary"'

start; respond '{"data":{"memberships":[{"project":{"gid":"9"},"section":{"name":"In Progress"}},{"project":{"gid":"8"}}]}}'
respond "$EMPTY"; respond '{"data":{}}'; run
check "task outside Ready for Deployment stays, gets the comment, no section reads" \
  '[[ $RC == 0 ]] && [[ $(writes) == "[\"/tasks/$A/stories\"]" ]] && [[ $(wc -l < "$MOCK_DIR/requests" | tr -d " ") == 3 ]] &&
   grep -q "not moved (not in Ready for Deployment, or no Done section) | posted" "$MOCK_DIR/summary"'

start; respond '{"data":{"memberships":[{"project":{"gid":"9"},"section":{"name":"ready for deployment"}}]}}'
respond "$SECTIONS"; respond "$EMPTY"; respond '{"data":{}}'; respond '{"data":{}}'; run
check "ready section matches case-insensitively" '[[ $RC == 0 ]] && [[ $(writes) == "[\"/sections/11/addTask\",\"/tasks/$A/stories\"]" ]]'

start; respond "$MEMBERS"; respond "$SECTIONS"; respond "$POSTED"; respond '{"data":{}}'; run
check "comment there but not moved yet → only the move" '[[ $RC == 0 ]] && [[ $(writes) == "[\"/sections/11/addTask\"]" ]]'

start; DONE_SECTION="Live" READY_SECTION="Approved"; TASK_API=https://work.example.test/api/1.0
respond '{"data":{"memberships":[{"project":{"gid":"9"},"section":{"name":"Approved"}}]}}'
respond '{"data":[{"gid":"12","name":"live"}]}'; respond "$EMPTY"; respond '{"data":{}}'; respond '{"data":{}}'; run
check "custom sections and Kickserve Work base" \
  '[[ $RC == 0 ]] && [[ $(writes) == "[\"/sections/12/addTask\",\"/tasks/$A/stories\"]" ]] &&
   jq -se "all(.[]; .url | startswith(\"https://work.example.test/api/1.0/\"))" "$MOCK_DIR/requests" > /dev/null &&
   grep -q "https://work.example.test/tasks/$A" "$MOCK_DIR/summary"'

start; respond "$MEMBERS"; respond '{"data":[{"gid":"10","name":"Ready for Deployment"}]}'; respond "$EMPTY"; respond '{"data":{}}'; run
check "project without Done section → comment only" '[[ $RC == 0 ]] && [[ $(writes) == "[\"/tasks/$A/stories\"]" ]]'

start "$A"$'\n'"$B"
respond '{"errors":[{"message":"Forbidden"}]}' 403 22
respond "$MEMBERS"; respond "$SECTIONS"; respond "$EMPTY"; respond '{"data":{}}'; respond '{"data":{}}'; run
check "failing task does not stop the next; batch fails; summary lists both" \
  '[[ $RC == 22 ]] && clean_errors && [[ $(writes) == "[\"/sections/11/addTask\",\"/tasks/$B/stories\"]" ]] &&
   grep -q "$A.*failed" "$MOCK_DIR/summary" && grep -q "$B.*posted" "$MOCK_DIR/summary" && grep -q "HTTP 403.*Forbidden" "$MOCK_DIR/err"'

start; respond "$MEMBERS"; respond "$SECTIONS"; respond '{"errors":[{"message":"Forbidden"}]}' 403 22; run
check "failed comment read prevents all writes for the task" '[[ $RC == 22 ]] && [[ $(writes) == "[]" ]] && clean_errors'

start; respond "$MEMBERS"; respond "$SECTIONS"; respond "$EMPTY"; respond '{"errors":[{"message":"Move denied"}]}' 400 22; run
check "failed move posts no comment (a rerun retries both)" \
  '[[ $RC == 22 ]] && [[ $(wc -l < "$MOCK_DIR/requests" | tr -d " ") == 4 ]] && grep -q "release-tasks: task $A: POST /sections/11/addTask.*HTTP 400" "$MOCK_DIR/err"'

start ""; run
check "no task IDs → no requests" '[[ $RC == 0 ]] && [[ ! -s "$MOCK_DIR/requests" ]] && grep -q "No task IDs" "$MOCK_DIR/summary"'

echo "$PASS passed, $FAIL failed (release-tasks)"
[ "$FAIL" -eq 0 ]
