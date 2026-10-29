#!/usr/bin/env bash
# Marks the tasks of a deployed version as live: a task in the "Ready for Deployment" section of a
# project moves to its Done section (never sets completed; tasks in other sections stay), and every
# task gets the comment "Live mit Version N: <release URL>" once.
# Rerunning is safe: a moved task is no longer in the ready section, a comment with the release URL
# is not posted again. A failing task does not stop the others; the exit status is the first failure.
#
# Usage: update.sh tasks.txt   (one task ID per line)
# Env:   TASK_TOKEN     token (Asana PAT or Kickserve Work token)
#        TASK_API       API base, default https://app.asana.com/api/1.0 (Kickserve Work: https://<host>/api/1.0)
#        VERSION        version number
#        RELEASE_URL    GitHub release of the version
#        DONE_SECTION   section the tasks move to (case-insensitive, default Done)
#        READY_SECTION  only tasks in this section move (case-insensitive, default Ready for Deployment)
#        SUMMARY        file the result table is appended to (default $GITHUB_STEP_SUMMARY, else none)
set -euo pipefail

TASKS_FILE=$1
DIR=$(cd "$(dirname "$0")" && pwd)
API=${TASK_API:-https://app.asana.com/api/1.0}
DONE_SECTION=${DONE_SECTION:-Done}
READY_SECTION=${READY_SECTION:-Ready for Deployment}
SUMMARY=${SUMMARY:-${GITHUB_STEP_SUMMARY:-/dev/null}}
LOG_PREFIX=release-tasks
# api, read_api, comments, section_moves
# shellcheck source=actions/task-sync/api.sh
source "$DIR/../task-sync/api.sh"

TASKS=$(grep -E '^[0-9]+$' "$TASKS_FILE" || true)
if [ -z "$TASKS" ]; then
  echo "No task IDs in version $VERSION."
  echo "No task IDs in the commits of version $VERSION." >> "$SUMMARY"
  exit 0
fi

COMMENT=$(jq -n --arg v "$VERSION" --arg url "$RELEASE_URL" \
  '{data: {html_text: "<body>Live mit Version \($v | @html): <a href=\"\($url | @html)\">\($url | @html)</a></body>"}}')
if [ -n "${TASK_API:-}" ]; then LINK_BASE="${TASK_API%/api/1.0}/tasks/"; else LINK_BASE="https://app.asana.com/0/0/"; fi

# Reads first (section moves, existing comments), then the writes; prints what happened.
release_task() {
  local TASK=$1 MOVES COMMENTS POSTED SECTION PROJECT MOVED=0
  MOVES=$(section_moves "$TASK" "$DONE_SECTION" "$READY_SECTION") || return $?
  COMMENTS=$(comments "$TASK") || return $?
  POSTED=$(jq -s --arg url "$RELEASE_URL" 'any(.[]; .html_text // "" | contains($url))' <<< "$COMMENTS") || return $?

  while read -r SECTION PROJECT; do
    [ -z "$SECTION" ] && continue
    api POST "/sections/$SECTION/addTask" -d "$(jq -n --arg t "$TASK" '{data: {task: $t}}')" > /dev/null || return $?
    echo "Moved to section \"$DONE_SECTION\" in project $PROJECT" >&2
    MOVED=$((MOVED + 1))
  done <<< "$MOVES"

  if [ "$POSTED" = true ]; then
    echo "Comment for version $VERSION already there" >&2
  else
    api POST "/tasks/$TASK/stories" -d "$COMMENT" > /dev/null || return $?
    echo "Comment posted" >&2
    POSTED=new
  fi
  printf '%s | %s\n' \
    "$([ "$MOVED" -gt 0 ] && echo "moved to $DONE_SECTION" || echo "not moved (not in $READY_SECTION, or no $DONE_SECTION section)")" \
    "$([ "$POSTED" = new ] && echo "posted" || echo "already there")"
}

STATUS=0
{
  echo "### Tasks of version $VERSION"
  echo
  echo "| Task | Section | Comment |"
  echo "|---|---|---|"
} >> "$SUMMARY"
for TASK in $TASKS; do
  echo "── Task $TASK"
  if RESULT=$(release_task "$TASK"); then
    echo "| [$TASK]($LINK_BASE$TASK) | $RESULT |" >> "$SUMMARY"
  else
    RC=$?
    [ "$STATUS" -ne 0 ] || STATUS=$RC
    echo "| [$TASK]($LINK_BASE$TASK) | failed, see log | |" >> "$SUMMARY"
  fi
done
exit "$STATUS"
