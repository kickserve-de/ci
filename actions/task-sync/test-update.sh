#!/usr/bin/env bash
# Offline integration tests for update.sh. No token or network required.
# Assertions are static shell expressions evaluated by check(), not expanded here.
# shellcheck disable=SC2016
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
ln -s "$DIR/tests/mock-curl.sh" "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" TASK_TOKEN=offline-secret-sentinel
export TASK_API="" MERGE_SECTION="" PIN=true MAX_ENTRIES=50 MAIN_BRANCH=main
PASS=0 FAIL=0
TASK=1219595984767913
export COMMENTS="/tasks/$TASK/stories" RC=0 EXPECTED_METHOD="" EXPECTED_RC=0
ENTRY='[{"task":"1219595984767913","type":"PUSH","author":"dev","repo":"o/r","branch":"feature","link":"https://github.com/o/r/commit/abc","sha":"abc","subject":"fix"}]'
EXISTING='{"data":[{"gid":"42","type":"comment","created_by":{"gid":"7"},"html_text":"<body>Commit-Log<ul><li>old</li></ul></body>"}],"next_page":null}'

check() {
  if eval "$2"; then
    PASS=$((PASS + 1)); echo "ok   $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL $1"
    cat "$MOCK_DIR/out" "$MOCK_DIR/err"
  fi
}
start() {
  export MOCK_DIR="$TMP/case-$((PASS + FAIL))"
  mkdir "$MOCK_DIR"
  : > "$MOCK_DIR/requests"
  printf '%s\n' "$ENTRY" > "$MOCK_DIR/entries.json"
  N=0
  MERGE_SECTION="" TASK_API="" PIN=true
}
respond() {
  N=$((N + 1))
  jq -n --arg body "$1" --arg status "${2:-200}" --argjson rc "${3:-0}" \
    '{body: $body, status: $status, rc: $rc}' > "$MOCK_DIR/$N.json"
}
user() { respond '{"data":{"gid":"7"}}'; }
empty() { respond '{"data":[],"next_page":null}'; }
run() {
  RC=0
  bash "$DIR/update.sh" "$MOCK_DIR/entries.json" > "$MOCK_DIR/out" 2> "$MOCK_DIR/err" || RC=$?
}
no_writes() { jq -se 'all(.[]; .method == "GET")' "$MOCK_DIR/requests" > /dev/null; }
clean_errors() {
  ! grep -Eq 'Cannot iterate|jq: error|parse error|offline-secret-sentinel|Authorization|Bearer' "$MOCK_DIR/err"
}

start; user
respond '{"errors":[{"message":"Forbidden"}]}' 403 22
run
check "403 stops the cascade with context and no jq noise" \
  '[[ $RC == 22 ]] && no_writes && clean_errors && grep -q "GET $COMMENTS.*HTTP 403.*Forbidden" "$MOCK_DIR/err" && grep -q "$TASK" "$MOCK_DIR/err"'

start; user
respond "${EXISTING%\"next_page\":null\}}\"next_page\":{\"offset\":\"next page/+\"}}"
respond '{"errors":[{"message":"Forbidden"}]}' 403 22
run
check "later-page failure cannot update a partial result" '[[ $RC == 22 ]] && no_writes && clean_errors'

start; user
respond "${EXISTING%\"next_page\":null\}}\"next_page\":{\"offset\":\"next\"}}"
respond '{"data":null}' 200
run
check "later-page invalid data discards earlier matching comment" '[[ $RC != 0 ]] && no_writes && clean_errors'

start; user
respond '{"data":[],"next_page":{"offset":"same"}}'
respond '{"data":[],"next_page":{"offset":"same"}}'
run
check "repeated pagination offset fails without writes" \
  '[[ $RC != 0 ]] && no_writes && clean_errors && grep -q "Repeated comments pagination" "$MOCK_DIR/err"'

for body in 'not json' '{}' '{"data":null}' '{"data":{}}' \
  '{"data":[{"type":"comment"}]}' \
  '{"data":[{"gid":"8","type":"comment","created_by":{"gid":7},"html_text":null}],"next_page":null}' \
  '{"data":[],"next_page":{}}' \
  '{"data":[],"next_page":{"offset":7}}' '{"data":[]} {"data":[]}'; do
  start; user; respond "$body"; run
  check "invalid comments rejected: $body" '[[ $RC != 0 ]] && no_writes && clean_errors && grep -q "Invalid API response.*GET" "$MOCK_DIR/err"'
done

for author in null '{}'; do
  for existing in false true; do
    start; user
    respond "$(jq --argjson author "$author" --argjson existing "$existing" '
      .data = (if $existing then .data else [] end) |
      .data += [{gid:"8",type:"comment",html_text:"Commit-Log",created_by:$author}] |
      if $author == {} then del(.data[-1].created_by) else . end
    ' <<< "$EXISTING")"
    respond '{"data":{}}'; run
    if $existing; then EXPECTED_METHOD=PUT; else EXPECTED_METHOD=POST; fi
    check "unknown comment author ($author) allows existing=$existing" \
      '[[ $RC == 0 ]] && [[ ! -s "$MOCK_DIR/err" ]] && jq -se --arg method "$EXPECTED_METHOD" "length == 3 and .[2].method == \$method" "$MOCK_DIR/requests" > /dev/null'
  done
done

for body in 'not json' '{}' '{"data":{"gid":null}}' '{"data":{"gid":7}}'; do
  start; respond "$body"; run
  check "invalid identity rejected: $body" '[[ $RC != 0 ]] && no_writes && clean_errors && [[ $(wc -l < "$MOCK_DIR/requests") == 1 ]]'
done

start; respond '{"errors":[{"message":"Identity denied"}]}' 403 22; run
check "identity HTTP failure stops all task requests" '[[ $RC == 22 ]] && no_writes && clean_errors'

start; user; respond '' 000 6; run
check "transport failure preserves curl exit and request context" \
  '[[ $RC == 6 ]] && no_writes && clean_errors && grep -q "curl exit 6" "$MOCK_DIR/err"'

for status in 403 302 500; do
  start; user; respond '<html>offline-secret-sentinel</html>' "$status" 0; run
  check "HTTP $status fails even without curl failure or JSON body" \
    '[[ $RC != 0 ]] && no_writes && clean_errors && grep -q "HTTP $status" "$MOCK_DIR/err"'
done

for pin in true false; do
  start; PIN=$pin; TASK_API=https://work.example.test/api/1.0
  user; empty; respond '{"data":{"gid":"42"}}'; run
  check "empty comments create once with pin=$pin and custom base" \
    '[[ $RC == 0 ]] && [[ ! -s "$MOCK_DIR/err" ]] && jq -se --arg base "$TASK_API" --argjson pin "$PIN" \
      "length == 3 and all(.[]; .url | startswith(\$base)) and (.[2] | .method == \"POST\" and (.payload | fromjson | .data.is_pinned == \$pin))" "$MOCK_DIR/requests" > /dev/null'
done

start; PIN=false; user; respond "$EXISTING"; respond '{"data":{}}'; run
check "existing comment updates without creation" \
  '[[ $RC == 0 ]] && jq -se "length == 3 and .[2].method == \"PUT\" and (.[2].url | endswith(\"/stories/42\")) and (.[2].payload | fromjson | .data | .is_pinned == false and (.html_text | contains(\"old\")))" "$MOCK_DIR/requests" > /dev/null'

start; user
respond '{"data":[{"gid":"8","type":"system"}],"next_page":{"offset":"next page/+"}}'
respond "$EXISTING"; respond '{"data":{}}'; run
check "pagination encodes offset and finds existing comment" \
  '[[ $RC == 0 ]] && jq -se "length == 4 and (.[2].url | endswith(\"offset=next%20page%2F%2B\")) and .[3].method == \"PUT\"" "$MOCK_DIR/requests" > /dev/null'

for existing in false true; do
  start; user
  if $existing; then respond "$EXISTING"; else empty; fi
  respond '{"errors":[{"message":"Write denied offline-secret-sentinel\nBearer private-header"}]}' 400 22
  run
  check "write failure (existing=$existing) is safe and not retried" \
    '[[ $RC == 22 ]] && [[ $(wc -l < "$MOCK_DIR/requests") == 3 ]] && clean_errors && ! grep -q private-header "$MOCK_DIR/err" && grep -Eq "(POST|PUT).*HTTP 400.*Write denied" "$MOCK_DIR/err" && ! grep -Eq "created|updated" "$MOCK_DIR/out"'
done

# All merge-section reads must succeed before any task mutation.
MERGED=$(jq '.[0].type = "MERGED_MAIN" | .[0] += {source:"feature",number:1}' <<< "$ENTRY")
MEMBERS='{"data":{"memberships":[{"project":{"gid":"9"},"section":{"name":"Todo"}}]}}'
SECTIONS='{"data":[{"gid":"10","name":"Done"}]}'
for read_path in memberships sections comments; do
  start; MERGE_SECTION="done"
  printf '%s\n' "$MERGED" > "$MOCK_DIR/entries.json"
  user
  if [ "$read_path" != memberships ]; then respond "$MEMBERS"; fi
  if [ "$read_path" = comments ]; then respond "$SECTIONS"; fi
  respond '{"errors":[{"message":"Forbidden"}]}' 403 22
  run
  check "failed $read_path prevents all merge-task writes" '[[ $RC == 22 ]] && no_writes && clean_errors'
done

for body in '{}' '{"data":{"memberships":null}}' '{"data":{"memberships":[{"project":{}}]}}' \
  '{"data":{"memberships":[{"project":{"gid":"9"},"section":7}]}}'; do
  start; MERGE_SECTION="done"
  printf '%s\n' "$MERGED" > "$MOCK_DIR/entries.json"
  user; respond "$body"; run
  check "invalid memberships rejected: $body" '[[ $RC != 0 ]] && no_writes && clean_errors'
done
for body in 'not json' '{"data":null}' '{"data":[{"gid":"10","name":7}]}' '{"data":[{"name":"Done"}]}'; do
  start; MERGE_SECTION="done"
  printf '%s\n' "$MERGED" > "$MOCK_DIR/entries.json"
  user; respond "$MEMBERS"; respond "$body"; run
  check "invalid sections rejected: $body" '[[ $RC != 0 ]] && no_writes && clean_errors'
done

start; MERGE_SECTION="done"
printf '%s\n' "$MERGED" > "$MOCK_DIR/entries.json"
user; respond "$MEMBERS"; respond "$SECTIONS"; empty
respond '{"data":{}}'; respond '{"data":{}}'; run
check "merge section remains case-insensitive and writes after reads" \
  '[[ $RC == 0 ]] && jq -se "length == 6 and all(.[0:4][]; .method == \"GET\") and (.[4].url | endswith(\"/sections/10/addTask\")) and (.[4].payload | fromjson | .data.task == \"1219595984767913\") and .[5].method == \"POST\"" "$MOCK_DIR/requests" > /dev/null'

for membership in '{"project":{"gid":"9"}}' '{"project":{"gid":"9"},"section":null}'; do
  start; MERGE_SECTION="done"
  printf '%s\n' "$MERGED" > "$MOCK_DIR/entries.json"
  user; respond "{\"data\":{\"memberships\":[$membership]}}"; respond "$SECTIONS"; empty
  respond '{"data":{}}'; respond '{"data":{}}'; run
  check "absent section permits planned move: $membership" \
    '[[ $RC == 0 ]] && [[ ! -s "$MOCK_DIR/err" ]] && jq -se "length == 6 and (.[4].url | endswith(\"/sections/10/addTask\")) and .[5].method == \"POST\"" "$MOCK_DIR/requests" > /dev/null'
done

start; MERGE_SECTION="done"
printf '%s\n' "$MERGED" > "$MOCK_DIR/entries.json"
user
respond '{"data":{"memberships":[{"project":{"gid":"9"},"section":null},{"project":{"gid":"11"},"section":null}]}}'
respond "$SECTIONS"
respond '{"errors":[{"message":"Forbidden"}]}' 403 22
run
check "later project failure discards previously planned section moves" '[[ $RC == 22 ]] && no_writes && clean_errors'

for memberships in '{"data":{"memberships":[]}}' \
  '{"data":{"memberships":[{"project":{"gid":"9"},"section":{"name":"DONE"}}]}}'; do
  start; MERGE_SECTION="done"
  printf '%s\n' "$MERGED" > "$MOCK_DIR/entries.json"
  user; respond "$memberships"; empty; respond '{"data":{}}'; run
  check "no section move needed still creates comment" \
    '[[ $RC == 0 ]] && jq -se "length == 4 and .[3].method == \"POST\" and (.[3].url | endswith(\"/stories\"))" "$MOCK_DIR/requests" > /dev/null'
done

start; MERGE_SECTION="done"
printf '%s\n' "$MERGED" > "$MOCK_DIR/entries.json"
user; respond "$MEMBERS"; empty; empty; respond '{"data":{}}'; run
check "empty sections are valid and do not block comment creation" \
  '[[ $RC == 0 ]] && jq -se "length == 5 and .[4].method == \"POST\" and (.[4].url | endswith(\"/stories\"))" "$MOCK_DIR/requests" > /dev/null'

start; MERGE_SECTION="done"
printf '%s\n' "$MERGED" > "$MOCK_DIR/entries.json"
user; respond "$MEMBERS"; respond "$SECTIONS"; empty
respond '{"errors":[{"message":"Move denied"}]}' 400 22
run
check "section write failure stops dependent writes and reports endpoint" \
  '[[ $RC == 22 ]] && [[ $(wc -l < "$MOCK_DIR/requests") == 5 ]] && clean_errors && grep -q "POST /sections/10/addTask.*HTTP 400.*Move denied" "$MOCK_DIR/err"'

SECOND_TASK=1219595984767914
for failure in comments later-page malformed memberships sections move-write comment-write; do
  start
  jq --arg second "$SECOND_TASK" '. + [.[0] | .task = $second]' <<< "$MERGED" > "$MOCK_DIR/entries.json"
  user
  case "$failure" in
    memberships|sections|move-write)
      MERGE_SECTION="done"
      if [ "$failure" != memberships ]; then respond "$MEMBERS"; fi
      if [ "$failure" = move-write ]; then respond "$SECTIONS"; empty; fi
      ;;
    later-page) respond '{"data":[],"next_page":{"offset":"next"}}' ;;
    comment-write) empty ;;
  esac
  if [ "$failure" = malformed ]; then
    respond '{"data":null}'
    EXPECTED_RC=1
  else
    respond '{"errors":[{"message":"Forbidden"}]}' 403 22
    EXPECTED_RC=22
  fi
  if [ -n "$MERGE_SECTION" ]; then respond '{"data":{"memberships":[]}}'; fi
  empty; respond '{"data":{}}'; run
  check "$failure failure isolates task A while task B syncs and batch fails" \
    '[[ $RC == "$EXPECTED_RC" ]] && clean_errors && jq -se --arg second "$SECOND_TASK" \
      ".[-1].method == \"POST\" and (.[-1].url | endswith(\"/tasks/\" + \$second + \"/stories\")) and ([.[] | select(.method != \"GET\")] | length == (if \"$failure\" == \"move-write\" or \"$failure\" == \"comment-write\" then 2 else 1 end))" "$MOCK_DIR/requests" > /dev/null'
done

start
jq --arg second "$SECOND_TASK" '. + [.[0] | .task = $second]' <<< "$ENTRY" > "$MOCK_DIR/entries.json"
user; empty; respond '{"data":{}}'; empty; respond '{"data":{}}'; run
check "two successful tasks yield a successful batch" \
  '[[ $RC == 0 ]] && jq -se "[.[] | select(.method == \"POST\")] | length == 2" "$MOCK_DIR/requests" > /dev/null'

start; user; empty; respond '{"data":{}}'
USER=fixture-login MOCK_EXPECT_USER=fixture-login run
check "API child processes retain the exported login USER" '[[ $RC == 0 ]] && [[ ! -s "$MOCK_DIR/err" ]]'

start
jq --arg second "$SECOND_TASK" '. + [.[0] | .task = $second]' <<< "$ENTRY" > "$MOCK_DIR/entries.json"
user; respond '' 000 6; respond '{"data":null}'; run
check "batch retains first failure status after a different later failure" \
  '[[ $RC == 6 ]] && no_writes && clean_errors && [[ $(wc -l < "$MOCK_DIR/requests") == 3 ]]'

start
printf '[]\n' > "$MOCK_DIR/entries.json"
run
check "no entries does not make API requests" '[[ $RC == 0 ]] && [[ ! -s "$MOCK_DIR/requests" ]]'

echo "$PASS passed, $FAIL failed (updater integration)"
[ "$FAIL" -eq 0 ]
