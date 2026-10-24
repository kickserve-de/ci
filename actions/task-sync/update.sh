#!/usr/bin/env bash
# Writes the entries (entries.json from entries.jq) to the tasks: merge comments, the pinned Commit-Log
# comment and, optionally, moves tasks to a section on merge into main.
#
# Usage: update.sh entries.json
# Env:   TASK_TOKEN     token (Asana PAT or Kickserve Work token)
#        TASK_API       API base, default https://app.asana.com/api/1.0 (Kickserve Work: https://<host>/api/1.0)
#        MAX_ENTRIES    max. entries kept in the Commit-Log (default 50)
#        MERGE_SECTION  section name to move tasks to on merge into main (empty = don't move)
#        PIN            pin the comments (true|false, default true)
set -euo pipefail

ENTRIES=$1
DIR=$(cd "$(dirname "$0")" && pwd)
API=${TASK_API:-https://app.asana.com/api/1.0}
MAX_ENTRIES=${MAX_ENTRIES:-50}
MERGE_SECTION=${MERGE_SECTION:-}
PIN=${PIN:-true}
HEADER="Commit-Log"
NOW=$(TZ=Europe/Berlin date '+%Y-%m-%d %H:%M')
JQ="jq -L $DIR"

[ "$(jq length "$ENTRIES")" -eq 0 ] && { echo "No task IDs found."; exit 0; }

api() {
  local method=$1 path=$2; shift 2
  curl -sS --fail-with-body -X "$method" "$API$path" \
    -H "Authorization: Bearer $TASK_TOKEN" \
    -H "Content-Type: application/json" "$@"
}

# All comments of a task, paginated
comments() {
  local offset="" page
  while :; do
    page=$(api GET "/tasks/$1/stories?limit=100&opt_fields=gid,type,html_text,created_by.gid${offset:+&offset=$offset}")
    jq -c '.data[] | select(.type == "comment")' <<< "$page"
    offset=$(jq -r '.next_page.offset // empty' <<< "$page")
    [ -z "$offset" ] && break
  done
}

# Moves the task into the section named $2 (case-insensitive) in every project that has one.
move_to_section() {
  local task=$1 name=$2 memberships project current section
  memberships=$(api GET "/tasks/$task?opt_fields=memberships.project.gid,memberships.section.name" | jq -c '.data.memberships[]')
  while read -r M; do
    [ -z "$M" ] && continue
    project=$(jq -r '.project.gid' <<< "$M")
    current=$(jq -r '.section.name // ""' <<< "$M")
    [ "$(tr "[:upper:]" "[:lower:]" <<< "$current")" = "$(tr "[:upper:]" "[:lower:]" <<< "$name")" ] && continue
    section=$(api GET "/projects/$project/sections?opt_fields=name" \
      | jq -r --arg n "$name" '[.data[] | select((.name | ascii_downcase) == ($n | ascii_downcase))][0].gid // empty')
    [ -z "$section" ] && continue
    api POST "/sections/$section/addTask" -d "$(jq -n --arg t "$task" '{data: {task: $t}}')" > /dev/null
    echo "Moved to section \"$name\" in project $project"
  done <<< "$memberships"
}

BOT_GID=$(api GET /users/me | jq -r '.data.gid')

for TASK in $(jq -r '[.[].task] | unique[]' "$ENTRIES"); do
  echo "── Task $TASK"

  # 1) Merge into main → a new pinned comment each time (+ optional move)
  while read -r E; do
    [ -z "$E" ] && continue
    HTML=$($JQ -r --arg now "$NOW" -f "$DIR/merge-comment.jq" <<< "$E")
    api POST "/tasks/$TASK/stories" \
      -d "$(jq -n --arg h "$HTML" --argjson pin "$PIN" '{data: {html_text: $h, is_pinned: $pin}}')" > /dev/null
    echo "Merge comment created"
    [ -n "$MERGE_SECTION" ] && move_to_section "$TASK" "$MERGE_SECTION"
  done < <(jq -c --arg t "$TASK" '.[] | select(.task == $t and .type == "MERGED_MAIN")' "$ENTRIES")

  # 2) Everything else → into the pinned Commit-Log comment (newest on top)
  NEW_ITEMS=$($JQ -r --arg t "$TASK" --arg now "$NOW" -f "$DIR/log-items.jq" "$ENTRIES")
  [ -z "$NEW_ITEMS" ] && continue

  STORY=$(comments "$TASK" | jq -sc --arg bot "$BOT_GID" --arg h "$HEADER" \
    '[.[] | select(.created_by.gid == $bot and (.html_text // "" | contains($h)))] | first // empty')

  HTML=$(jq -rn --arg new "$NEW_ITEMS" --argjson old "${STORY:-null}" \
    --argjson max "$MAX_ENTRIES" --arg header "$HEADER" -f "$DIR/commit-log.jq")
  PAYLOAD=$(jq -n --arg h "$HTML" --argjson pin "$PIN" '{data: {html_text: $h, is_pinned: $pin}}')

  if [ -n "$STORY" ]; then
    api PUT "/stories/$(jq -r '.gid' <<< "$STORY")" -d "$PAYLOAD" > /dev/null
    echo "Commit-Log updated"
  else
    api POST "/tasks/$TASK/stories" -d "$PAYLOAD" > /dev/null
    echo "Commit-Log created"
  fi
done
