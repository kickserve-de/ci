#!/usr/bin/env bash
# Tracker API helpers shared by task-sync (update.sh) and release-tasks (sourced, not run).
# Needs: API (base URL), TASK_TOKEN; TASK names the task in diagnostics; LOG_PREFIX (default task-sync).
# shellcheck shell=bash

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
    printf '%s: task %s: %s %s: HTTP %s, curl exit %s%s\n' \
      "${LOG_PREFIX:-task-sync}" "${TASK:-initialization}" "$method" "$path" "$status" "$rc" "${message:+: $message}" >&2
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
    printf '%s: task %s: Invalid API response for GET %s (malformed JSON or missing/wrongly typed data)\n' \
      "${LOG_PREFIX:-task-sync}" "${TASK:-initialization}" "$path" >&2
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
          (.gid | id) and
          (.created_by == null or (.created_by | type == "object" and (.gid | id))) and has("html_text") and
          (.html_text | type == "string" or type == "null")
        else true end) and
      has("next_page") and (.next_page == null or
        (.next_page | type == "object" and (.offset | type == "string" and length > 0)))
    ') || return $?
    jq -c '.data[] | select(.type == "comment")' <<< "$page" || return $?
    offset=$(jq -r '.next_page.offset // empty | @uri' <<< "$page") || return $?
    [ -z "$offset" ] && break
    if [[ "$seen" == *"|$offset|"* ]]; then
      printf '%s: task %s: Repeated comments pagination offset\n' "${LOG_PREFIX:-task-sync}" "$1" >&2
      return 1
    fi
    seen+="$offset|"
  done
}

# Plan moves first: no mutation until all reads for this task have succeeded.
# Optional third argument: move only out of the section with that name (case-insensitive).
section_moves() {
  local task=$1 name=$2 from=${3:-} memberships project current section response M
  response=$(read_api "/tasks/$task?opt_fields=memberships.project.gid,memberships.section.name" '
    (.data | type == "object") and (.data.memberships | type == "array") and
    all(.data.memberships[]; type == "object" and (.project.gid | id) and
      (.section == null or (.section | type == "object" and (.name | type == "string"))))
  ') || return $?
  memberships=$(jq -c '.data.memberships[]' <<< "$response") || return $?
  while read -r M; do
    [ -z "$M" ] && continue
    project=$(jq -r '.project.gid' <<< "$M") || return $?
    current=$(jq -r '.section.name // ""' <<< "$M") || return $?
    [ "$(tr "[:upper:]" "[:lower:]" <<< "$current")" = "$(tr "[:upper:]" "[:lower:]" <<< "$name")" ] && continue
    [ -n "$from" ] && [ "$(tr "[:upper:]" "[:lower:]" <<< "$current")" != "$(tr "[:upper:]" "[:lower:]" <<< "$from")" ] && continue
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
