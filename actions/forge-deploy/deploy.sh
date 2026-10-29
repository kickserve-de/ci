#!/usr/bin/env bash
# Starts a Laravel Forge deployment of a site and waits until it has ended.
# Env: FORGE_API_TOKEN, ORGANIZATION, SERVER, SITE, SHA (commit that must be deployed),
#      TIMEOUT (seconds), POLL (seconds between status requests, default 15)
set -euo pipefail

[ -n "${FORGE_API_TOKEN:-}" ] || { echo "::error::FORGE_API_TOKEN is not set"; exit 1; }
api="https://forge.laravel.com/api/orgs/$ORGANIZATION/servers/$SERVER/sites/$SITE/deployments"
forge() { curl -fsS -H "Authorization: Bearer $FORGE_API_TOKEN" -H "Accept: application/json" "$@"; }

id=$(forge -X POST "$api" | jq -r '.data.id // empty') || id=""
[ -n "$id" ] || { echo "::error::Forge did not start a deployment of site $SITE"; exit 1; }
echo "Forge deployment $id started"

deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  sleep "${POLL:-15}"
  deployment=$(forge "$api/$id") || deployment='{}'
  status=$(jq -r '.data.attributes.status // "unknown"' <<<"$deployment")
  case "$status" in
    finished)
      # Forge deploys the head of the site's branch; a newer commit there was not checked by the gate.
      hash=$(jq -r '.data.attributes.commit.hash // ""' <<<"$deployment")
      if [ -n "$SHA" ] && [ "$hash" != "$SHA" ]; then
        echo "::error::Forge deployed ${hash:0:7} instead of ${SHA:0:7}; the branch moved on"
        exit 1
      fi
      echo "Forge deployed ${hash:0:7}"
      exit 0 ;;
    failed|failed-build|cancelled)
      echo "::error::Forge deployment $id $status"
      exit 1 ;;
  esac
  echo "Forge deployment $id: $status"
  [ "$(date +%s)" -lt "$deadline" ] || { echo "::error::Forge deployment $id did not end within ${TIMEOUT}s"; exit 1; }
done
