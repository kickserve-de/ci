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

# api, read_api, comments, section_moves
# shellcheck source=actions/task-sync/api.sh
source "$DIR/api.sh"

ME=$(read_api /users/me '(.data | type == "object") and (.data.gid | id)') || exit $?
BOT_GID=$(jq -r '.data.gid' <<< "$ME") || exit $?

sync_task() {
  local TASK=$1 MOVES NEW_ITEMS COMMENTS STORY HTML PAYLOAD SECTION PROJECT MOVE_PAYLOAD STORY_GID
  echo "── Task $TASK"

  # Merge into main → optionally move the task
  MOVES=""
  if [ -n "$MERGE_SECTION" ] && jq -e --arg t "$TASK" 'any(.[]; .task == $t and .type == "MERGED_MAIN")' "$ENTRIES" > /dev/null; then
    MOVES=$(section_moves "$TASK" "$MERGE_SECTION") || return $?
  fi

  # Everything → into the pinned Commit-Log comment (newest on top)
  NEW_ITEMS=$($JQ -r --arg t "$TASK" --arg now "$NOW" -f "$DIR/log-items.jq" "$ENTRIES") || return $?
  if [ -n "$NEW_ITEMS" ]; then
    COMMENTS=$(comments "$TASK") || return $?
    STORY=$(jq -sc --arg bot "$BOT_GID" --arg h "$HEADER" \
      '[.[] | select(.created_by.gid == $bot and (.html_text // "" | contains($h)))] | first // empty' \
      <<< "$COMMENTS") || return $?

    HTML=$(jq -rn --arg new "$NEW_ITEMS" --argjson old "${STORY:-null}" \
      --argjson max "$MAX_ENTRIES" --arg header "$HEADER" --arg main "$MAIN_BRANCH" -f "$DIR/commit-log.jq") || return $?
    PAYLOAD=$(jq -n --arg h "$HTML" --argjson pin "$PIN" '{data: {html_text: $h, is_pinned: $pin}}') || return $?
  fi

  while read -r SECTION PROJECT; do
    [ -z "$SECTION" ] && continue
    MOVE_PAYLOAD=$(jq -n --arg t "$TASK" '{data: {task: $t}}') || return $?
    api POST "/sections/$SECTION/addTask" -d "$MOVE_PAYLOAD" > /dev/null || return $?
    echo "Moved to section \"$MERGE_SECTION\" in project $PROJECT"
  done <<< "$MOVES"
  [ -z "$NEW_ITEMS" ] && return 0

  if [ -n "$STORY" ]; then
    STORY_GID=$(jq -r '.gid' <<< "$STORY") || return $?
    api PUT "/stories/$STORY_GID" -d "$PAYLOAD" > /dev/null || return $?
    echo "Commit-Log updated"
  else
    api POST "/tasks/$TASK/stories" -d "$PAYLOAD" > /dev/null || return $?
    echo "Commit-Log created"
  fi
}

STATUS=0
TASKS=$(jq -r '[.[].task] | unique[]' "$ENTRIES") || exit $?
for TASK in $TASKS; do
  sync_task "$TASK" || {
    RC=$?
    [ "$STATUS" -ne 0 ] || STATUS=$RC
  }
done
exit "$STATUS"
