#!/usr/bin/env bash
# Finds the commits and PRs a deploy reports to.
# staging: the deployed commit plus the branch heads merged into it (second and
#   later parents), and their open PRs, so results show on the feature PR.
# production: the deployed commit and the PRs that brought it to main.
set -euo pipefail

api() {
  curl -fsS -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
    "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/$1"
}

shas="$GITHUB_SHA"
if [ "$MODE" = staging ]; then
  shas="$GITHUB_SHA $(api "commits/$GITHUB_SHA" | jq -r '.parents[1:][].sha' | tr '\n' ' ')"
  state_filter='select(.state == "open")'
else
  state_filter='select(.merged_at != null or .state == "open")'
fi

prs=""
for sha in $shas; do
  prs="$prs $(api "commits/$sha/pulls" | jq -r ".[] | $state_filter | .number" | tr '\n' ' ')"
done
prs="$(tr ' ' '\n' <<<"$prs" | grep -v '^$' | sort -un | tr '\n' ' ' || true)"

echo "Reporting to commits: $shas"
echo "Reporting to PRs: ${prs:-none}"
echo "shas=$shas" >> "$GITHUB_OUTPUT"
echo "prs=$prs" >> "$GITHUB_OUTPUT"
