#!/usr/bin/env bash
# Builds the traffic light from results.jsonl and publishes it.
# Env: TITLE, KEY, SHAS, PRS, FAIL_ON_HARD, GH_TOKEN (+ GitHub's default env).
set -euo pipefail

results="${RUNNER_TEMP}/kickserve-ci/results.jsonl"
if [ ! -s "$results" ]; then
  echo "No check results recorded."
  echo "light=green" >> "$GITHUB_OUTPUT"
  exit 0
fi

api() {
  local method="$1" path="$2"; shift 2
  curl -fsS -X "$method" \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/$path" "$@"
}

rows="$(jq -s '.' "$results")"
light="$(jq -r '
  if any(.[]; .status == "fail" and .level == "hard") then "red"
  elif any(.[]; .status == "fail") then "yellow"
  else "green" end' <<<"$rows")"
echo "light=$light" >> "$GITHUB_OUTPUT"

run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
block="$(jq -r --arg title "$TITLE" --arg light "$light" --arg key "$KEY" \
  --arg run "$run_url" --arg sha "${GITHUB_SHA:0:7}" --arg at "$(date -u '+%Y-%m-%d %H:%M UTC')" '
  def icon: if .status == "pass" then "🟢" elif .level == "hard" then "🔴" else "🟡" end;
  ({green: "🟢", yellow: "🟡", red: "🔴"}[$light]) as $l
  | "<!-- kickserve-ci:\($key):start -->\n"
  + "### \($l) \($title)\n\n"
  + "| Check | Status | Detail |\n|---|---|---|\n"
  + (map("| \(.name) | \(icon) | \(.detail | gsub("\\|"; "\\|") | gsub("\n"; " ")) |") | join("\n"))
  + "\n\n<sub>[Run](\($run)) · \($sha) · \($at) · 🔴 blocks the merge, 🟡 is a warning</sub>\n"
  + "<!-- kickserve-ci:\($key):end -->"' <<<"$rows")"

echo "$block" >> "$GITHUB_STEP_SUMMARY"

# One check per result, so each shows up on the commit and in the PR checks list.
for sha in $SHAS; do
  jq -c '.[]' <<<"$rows" | while read -r row; do
    payload="$(jq -c --arg sha "$sha" --arg title "$TITLE" --arg url "$run_url" '{
      name: "\($title): \(.name)",
      head_sha: $sha,
      status: "completed",
      details_url: $url,
      conclusion: (if .status == "pass" then "success" elif .level == "hard" then "failure" else "neutral" end),
      output: {title: (if .status == "pass" then "passed" else "failed (\(.level))" end), summary: (.detail // "")}
    }' <<<"$row")"
    api POST check-runs -d "$payload" > /dev/null || echo "::warning::Could not create check run on $sha"
  done
done

# Replace the block in each PR description, or append it once.
for pr in $PRS; do
  body="$(api GET "pulls/$pr" | jq -r '.body // ""')"
  new_body="$(jq -rn --arg body "$body" --arg block "$block" --arg key "$KEY" '
    "<!-- kickserve-ci:\($key):start -->" as $s | "<!-- kickserve-ci:\($key):end -->" as $e
    | ($body | index($s)) as $i | ($body | index($e)) as $j
    | if $i != null and $j != null and $j > $i
      then $body[:$i] + $block + $body[$j + ($e | length):]
      else ($body | rtrimstr("\n")) + "\n\n" + $block end')"
  api PATCH "pulls/$pr" -d "$(jq -n --arg b "$new_body" '{body: $b}')" > /dev/null \
    || echo "::warning::Could not update the description of PR #$pr"
done

if [ "$light" = red ] && [ "$FAIL_ON_HARD" = true ]; then
  echo "::error::At least one hard check failed (see the table in the job summary)."
  exit 1
fi
