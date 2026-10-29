#!/usr/bin/env bash
# Smoke test and Lighthouse; every result is recorded, nothing fails here.
set -euo pipefail

# -b "": cookie engine on, so cookie-based redirects (locale, consent) do not loop.
auth=()
[ -n "$BASIC_AUTH" ] && auth=(-u "$BASIC_AUTH")
# Lets a WAF rule (e.g. Cloudflare) skip its bot challenge for curl.
[ -n "${CHECK_TOKEN:-}" ] && auth+=(-H "X-Kickserve-Check: $CHECK_TOKEN")

# Smoke: one result for all paths, listing the failures and the slowest page.
failed=()
slowest="" slowest_time=0
for path in $SMOKE_PATHS; do
  out="$(curl -sS -L -b "" -o /dev/null --max-time 60 ${auth[@]+"${auth[@]}"} \
    -w '%{http_code} %{time_total}' "$BASE_URL$path" 2>&1)" || out="000 0"
  code="${out%% *}" time="${out##* }"
  echo "$path → $code in ${time}s"
  [[ "$code" =~ ^2 ]] || failed+=("$path ($code)")
  if awk -v a="$time" -v b="$slowest_time" 'BEGIN { exit !(a > b) }'; then
    slowest="$path" slowest_time="$time"
  fi
done
if [ ${#failed[@]} -eq 0 ]; then
  bash "$RECORD" smoke hard pass "$(wc -w <<<"$SMOKE_PATHS" | tr -d ' ') pages OK, slowest $slowest ${slowest_time}s"
else
  bash "$RECORD" smoke hard fail "failed: ${failed[*]}"
fi

# Lighthouse: one result per path, red below min, yellow below target.
# Required requests (e.g. the GTM container) are checked in the same browser run.
if [ -z "$LIGHTHOUSE_PATHS" ]; then
  [ -n "${REQUIRED_REQUESTS:-}" ] && bash "$RECORD" requests hard fail "required-requests needs lighthouse-paths"
  exit 0
fi
headers='{}'
[ -n "$BASIC_AUTH" ] && headers="$(jq -nc --arg a "Basic $(printf '%s' "$BASIC_AUTH" | base64 | tr -d '\n')" '{Authorization: $a}')"
preset=()
[ "$FORM_FACTOR" = desktop ] && preset=(--preset=desktop)

for path in $LIGHTHOUSE_PATHS; do
  # Warm the caches (one hit per node behind a load balancer) so the score is not a cold start.
  for _ in $(seq 1 "${WARMUP_HITS:-2}"); do
    curl -sS -L -b "" -o /dev/null --max-time 60 ${auth[@]+"${auth[@]}"} "$BASE_URL$path" || true
  done
  report="$(mktemp)"
  if ! npx --yes lighthouse@12.6.1 "$BASE_URL$path" ${preset[@]+"${preset[@]}"} --quiet \
      --only-categories=performance,accessibility,best-practices,seo \
      --extra-headers="$headers" \
      --chrome-flags="--headless=new --no-sandbox --disable-dev-shm-usage" \
      --output=json --output-path="$report"; then
    bash "$RECORD" "lighthouse $path" soft fail "Lighthouse did not finish"
    [ -n "${REQUIRED_REQUESTS:-}" ] && bash "$RECORD" "requests $path" hard fail "not checked, Lighthouse did not finish"
    continue
  fi
  if [ -n "${REQUIRED_REQUESTS:-}" ]; then
    missing="$(jq -r --arg required "$REQUIRED_REQUESTS" '
      [.audits["network-requests"].details.items[]?.url] as $urls
      | [$required | splits("\\s+") | select(. != "") | select(. as $r | $urls | any(contains($r)) | not)]
      | join(" ")' "$report")"
    if [ -z "$missing" ]; then
      bash "$RECORD" "requests $path" hard pass "$(wc -w <<<"$REQUIRED_REQUESTS" | tr -d ' ') required requests loaded"
    else
      bash "$RECORD" "requests $path" hard fail "never requested: $missing"
    fi
  fi
  read -r detail worst < <(jq -r '
    .categories | to_entries
    | map({k: ({performance: "Perf", accessibility: "A11y", "best-practices": "BP", seo: "SEO"}[.key]), s: ((.value.score // 0) * 100 | round)})
    | "\(map("\(.k) \(.s)") | join(" · ") | gsub(" "; " ")) \(map(.s) | min)"' "$report")
  if [ "$worst" -lt "$LIGHTHOUSE_MIN" ]; then
    bash "$RECORD" "lighthouse $path" hard fail "$detail (min $LIGHTHOUSE_MIN)"
  elif [ "$worst" -lt "$LIGHTHOUSE_TARGET" ]; then
    bash "$RECORD" "lighthouse $path" soft fail "$detail (target $LIGHTHOUSE_TARGET)"
  else
    bash "$RECORD" "lighthouse $path" soft pass "$detail"
  fi
done
