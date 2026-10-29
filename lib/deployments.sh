#!/usr/bin/env bash
# Reads the GitHub deployments of this repo (GITHUB_REPOSITORY, gh authenticated by GH_TOKEN,
# token needs deployments: read). A deployment counts as successful when any of its statuses is
# "success", so a later "inactive" does not hide it.
# usage: deployments.sh live <environment> <sha>
#          prints true when <sha> has a successful deployment to <environment>, else false
#        deployments.sh previous <environment> <sha>
#          prints the commit of the newest successful deployment to <environment> of another
#          commit than <sha> (the last 100 deployments), else nothing
# Exit 0, 64 usage, other codes from gh.
set -euo pipefail

[ "$#" -eq 3 ] || { echo "usage: deployments.sh live|previous <environment> <sha>" >&2; exit 64; }
mode=$1 sha=$3
env=$(jq -rn --arg e "$2" '$e | @uri')
repo="repos/$GITHUB_REPOSITORY"

# gh errors end the script; they never read as "not deployed".
succeeded() {
  local state
  state=$(gh api "$repo/deployments/$1/statuses?per_page=100" --jq 'any(.[]; .state == "success")') || exit $?
  [ "$state" = true ]
}

case "$mode" in
  live)
    ids=$(gh api "$repo/deployments?environment=$env&sha=$sha&per_page=100" --jq '.[].id')
    for id in $ids; do
      succeeded "$id" && { echo true; exit 0; }
    done
    echo false
    ;;
  previous)
    list=$(gh api "$repo/deployments?environment=$env&per_page=100" --jq '.[] | "\(.id) \(.sha)"')
    # An if, not an && chain: a last non-matching line must not become the exit code.
    while read -r id commit; do
      if [ -n "$id" ] && [ "$commit" != "$sha" ] && succeeded "$id"; then echo "$commit"; break; fi
    done <<< "$list"
    ;;
  *) echo "usage: deployments.sh live|previous <environment> <sha>" >&2; exit 64 ;;
esac
