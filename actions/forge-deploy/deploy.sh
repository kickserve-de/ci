#!/usr/bin/env bash
# Starts a Laravel Forge deployment of a site through its deploy hook and waits until it has ended.
# Env: DEPLOY_HOOK (deploy hook URL), FORGE_API_TOKEN (server:view, only reads the status),
#      ORGANIZATION, SERVER, SITE, SHA (commit that must be deployed),
#      TIMEOUT (seconds), POLL (seconds between status requests, default 15)
set -euo pipefail

[ -n "${DEPLOY_HOOK:-}" ] || { echo "::error::FORGE_DEPLOY_HOOK is not set"; exit 1; }
[ -n "${FORGE_API_TOKEN:-}" ] || { echo "::error::FORGE_API_TOKEN is not set"; exit 1; }
api="https://forge.laravel.com/api/orgs/$ORGANIZATION/servers/$SERVER/sites/$SITE/deployments"
forge() { curl -fsS -H "Authorization: Bearer $FORGE_API_TOKEN" -H "Accept: application/json" "$@"; }
latest() { forge "$api?sort=-created_at&page%5Bsize%5D=1" | jq -r '.data[0].id // ""'; }

# The hook answers without a deployment id, so the new deployment is the first one newer than this.
before=$(latest) || { echo "::error::Forge API did not list the deployments of site $SITE"; exit 1; }
sep='?'; [[ "$DEPLOY_HOOK" == *\?* ]] && sep='&'
curl -fsS -X POST "${DEPLOY_HOOK}${sep}forge_deploy_commit=$SHA" > /dev/null \
  || { echo "::error::Forge deploy hook of site $SITE failed"; exit 1; }

deadline=$(( $(date +%s) + TIMEOUT ))
id=""
while :; do
  sleep "${POLL:-15}"
  if [ -z "$id" ]; then
    id=$(latest) || id=""
    [ "$id" != "$before" ] || id=""
    [ -z "$id" ] || echo "Forge deployment $id started"
  fi
  if [ -n "$id" ]; then
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
  fi
  [ "$(date +%s)" -lt "$deadline" ] || { echo "::error::Forge deployment ${id:-of site $SITE} did not end within ${TIMEOUT}s"; exit 1; }
done
