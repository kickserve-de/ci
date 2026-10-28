#!/usr/bin/env bash
# Writes the entries (entries.json from entries.jq) to the tasks: one pinned Commit-Log comment per task
# (pushes, PRs and merges of all repos) and, optionally, moves tasks to a section on merge into main.
#
# Usage: update.sh entries.json
# Env:   TASK_TOKEN     token (Asana PAT or Kickserve Work token)
#        TASK_API       API base, default https://app.asana.com/api/1.0 (Kickserve Work: https://<host>/api/1.0)
#        MAX_ENTRIES    max. entries kept in the Commit-Log (default 50)
#        MERGE_SECTION  section name to move tasks to on merge into main (empty = don't move)
#        PIN            pin the comment (true|false, default true)
#        MAIN_BRANCH    branch whose PRs always stay in the Commit-Log (default main)
set -euo pipefail

ENTRIES=$1
DIR=$(cd "$(dirname "$0")" && pwd)
API=${TASK_API:-https://app.asana.com/api/1.0}
MAX_ENTRIES=${MAX_ENTRIES:-50}
MERGE_SECTION=${MERGE_SECTION:-}
PIN=${PIN:-true}
MAIN_BRANCH=${MAIN_BRANCH:-main}
HEADER="Commit-Log"
NOW=$(TZ=Europe/Berlin date '+%Y-%m-%d %H:%M')
JQ="jq -L $DIR"

[ "$(jq length "$ENTRIES")" -eq 0 ] && { echo "No task IDs found."; exit 0; }

api() {
  local method=$1 path=$2; shift 2
  local response body status rc=0 message
  # Keep error bodies and curl diagnostics out of the successful data stream.
  response=$(curl -s --fail-with-body -w $'\n%{http_code}' -X "$method" "$API$path" \
    -H "Authorization: Bearer $TASK_TOKEN" \
    -H "Content-Type: application/json" "$@" 2>/dev/null) || rc=$?
  status=${response##*$'\n'}
  body=${response%$'\n'*}
  [[ "$status" =~ ^[0-9]{3}$ ]] || status=unknown
  if [ "$rc" -ne 0 ] || [[ "$status" != 2[0-9][0-9] ]]; then
    message=$(jq -rs --arg token "$TASK_TOKEN" '
      [.[0].errors[]?.message | select(type == "string")] | join("; ")
      | if $token != "" then split($token) | join("[redacted]") else . end
      | gsub("(?i)(authorization|bearer)[^\r\n]*"; "[redacted]")
      | gsub("[[:cntrl:]]"; " ") | .[:300]
    ' <<< "$body" 2>/dev/null) || message=""
    printf 'task-sync: task %s: %s %s: HTTP %s, curl exit %s%s\n' \
      "${TASK:-initialization}" "$method" "$path" "$status" "$rc" "${message:+: $message}" >&2
    if [ "$status" = 403 ]; then
      echo "Check that the configured token has access to the target task, workspace and project." >&2
    fi
    [ "$rc" -ne 0 ] || rc=1
    return "$rc"
  fi
  printf '%s\n' "$body"
}

# Validate one complete JSON response before any caller can use it.
read_api() {
  local path=$1 schema=$2 response
  response=$(api GET "$path") || return $?
  if ! jq -e -s "
    def id: type == \"string\" and test(\"^[A-Za-z0-9_-]+$\");
    length == 1 and (.[0] | type == \"object\" and ($schema))
  " <<< "$response" > /dev/null 2>&1; then
    printf 'task-sync: task %s: Invalid API response for GET %s (malformed JSON or missing/wrongly typed data)\n' \
      "${TASK:-initialization}" "$path" >&2
    return 1
  fi
  printf '%s\n' "$response"
}

# All comments of a task, paginated
comments() {
  local offset="" page seen="|" path
  while :; do
    path="/tasks/$1/stories?limit=100&opt_fields=gid,type,html_text,created_by.gid${offset:+&offset=$offset}"
    page=$(read_api "$path" '
      (.data | type == "array") and
      all(.data[]; type == "object" and (.type | type == "string") and
        if .type == "comment" then
          (.gid | id) and (.created_by.gid | id) and has("html_text") and
          (.html_text | type == "string" or type == "null")
        else true end) and
      has("next_page") and (.next_page == null or
        (.next_page | type == "object" and (.offset | type == "string" and length > 0)))
    ') || return $?
    jq -c '.data[] | select(.type == "comment")' <<< "$page" || return $?
    offset=$(jq -r '.next_page.offset // empty | @uri' <<< "$page") || return $?
    [ -z "$offset" ] && break
    if [[ "$seen" == *"|$offset|"* ]]; then
      printf 'task-sync: task %s: Repeated comments pagination offset\n' "$1" >&2
      return 1
    fi
    seen+="$offset|"
  done
}

# Plan moves first: no mutation until all reads for this task have succeeded.
section_moves() {
  local task=$1 name=$2 memberships project current section response M
  response=$(read_api "/tasks/$task?opt_fields=memberships.project.gid,memberships.section.name" '
    (.data | type == "object") and (.data.memberships | type == "array") and
    all(.data.memberships[]; type == "object" and (.project.gid | id) and has("section") and
      (.section == null or (.section | type == "object" and (.name | type == "string"))))
  ') || return $?
  memberships=$(jq -c '.data.memberships[]' <<< "$response") || return $?
  while read -r M; do
    [ -z "$M" ] && continue
    project=$(jq -r '.project.gid' <<< "$M") || return $?
    current=$(jq -r '.section.name // ""' <<< "$M") || return $?
    [ "$(tr "[:upper:]" "[:lower:]" <<< "$current")" = "$(tr "[:upper:]" "[:lower:]" <<< "$name")" ] && continue
    response=$(read_api "/projects/$project/sections?opt_fields=name" '
      (.data | type == "array") and
      all(.data[]; type == "object" and (.gid | id) and (.name | type == "string"))
    ') || return $?
    section=$(jq -r --arg n "$name" \
      '[.data[] | select((.name | ascii_downcase) == ($n | ascii_downcase))][0].gid // empty' <<< "$response") || return $?
    [ -z "$section" ] && continue
    printf '%s %s\n' "$section" "$project"
  done <<< "$memberships"
}

USER=$(read_api /users/me '(.data | type == "object") and (.data.gid | id)') || exit $?
BOT_GID=$(jq -r '.data.gid' <<< "$USER") || exit $?

for TASK in $(jq -r '[.[].task] | unique[]' "$ENTRIES"); do
  echo "── Task $TASK"

  # Merge into main → optionally move the task
  MOVES=""
  if [ -n "$MERGE_SECTION" ] && jq -e --arg t "$TASK" 'any(.[]; .task == $t and .type == "MERGED_MAIN")' "$ENTRIES" > /dev/null; then
    MOVES=$(section_moves "$TASK" "$MERGE_SECTION") || exit $?
  fi

  # Everything → into the pinned Commit-Log comment (newest on top)
  NEW_ITEMS=$($JQ -r --arg t "$TASK" --arg now "$NOW" -f "$DIR/log-items.jq" "$ENTRIES") || exit $?
  if [ -n "$NEW_ITEMS" ]; then
    COMMENTS=$(comments "$TASK") || exit $?
    STORY=$(jq -sc --arg bot "$BOT_GID" --arg h "$HEADER" \
      '[.[] | select(.created_by.gid == $bot and (.html_text // "" | contains($h)))] | first // empty' \
      <<< "$COMMENTS") || exit $?

    HTML=$(jq -rn --arg new "$NEW_ITEMS" --argjson old "${STORY:-null}" \
      --argjson max "$MAX_ENTRIES" --arg header "$HEADER" --arg main "$MAIN_BRANCH" -f "$DIR/commit-log.jq") || exit $?
    PAYLOAD=$(jq -n --arg h "$HTML" --argjson pin "$PIN" '{data: {html_text: $h, is_pinned: $pin}}') || exit $?
  fi

  while read -r SECTION PROJECT; do
    [ -z "$SECTION" ] && continue
    MOVE_PAYLOAD=$(jq -n --arg t "$TASK" '{data: {task: $t}}') || exit $?
    api POST "/sections/$SECTION/addTask" -d "$MOVE_PAYLOAD" > /dev/null || exit $?
    echo "Moved to section \"$MERGE_SECTION\" in project $PROJECT"
  done <<< "$MOVES"
  [ -z "$NEW_ITEMS" ] && continue

  if [ -n "$STORY" ]; then
    STORY_GID=$(jq -r '.gid' <<< "$STORY") || exit $?
    api PUT "/stories/$STORY_GID" -d "$PAYLOAD" > /dev/null || exit $?
    echo "Commit-Log updated"
  else
    api POST "/tasks/$TASK/stories" -d "$PAYLOAD" > /dev/null || exit $?
    echo "Commit-Log created"
  fi
done
