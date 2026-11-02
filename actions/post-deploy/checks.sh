#!/usr/bin/env bash
# Smoke test and Lighthouse; every result is recorded, nothing fails here.
set -euo pipefail

# -b "": cookie engine on, so cookie-based redirects (locale, consent) do not loop.
auth=()
[ -n "$BASIC_AUTH" ] && auth=(-u "$BASIC_AUTH")
# Optional project header, e.g. so a bot protection lets the smoke test through.
[ -n "${CHECK_HEADER:-}" ] && [ -n "${CHECK_TOKEN:-}" ] && auth+=(-H "$CHECK_HEADER: $CHECK_TOKEN")

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
# Lighthouse runs through lighthouse.mjs, whose Chrome page answers basic auth challenges
# itself: with --extra-headers, Chrome refetches stylesheets for CSS.enable without the
# header, gets a 401 challenge and hangs until the DevTools protocol timeout.
lh_dir="${RUNNER_TEMP:-/tmp}/kickserve-lighthouse"
mkdir -p "$lh_dir"
cp "$(dirname "$0")/lighthouse.mjs" "$lh_dir/"
if ! npm install --prefix "$lh_dir" --silent --no-audit --no-fund lighthouse@12.6.1 > /dev/null; then
  for path in $LIGHTHOUSE_PATHS; do
    bash "$RECORD" "lighthouse $path" soft fail "Lighthouse could not be installed"
    [ -n "${REQUIRED_REQUESTS:-}" ] && bash "$RECORD" "requests $path" hard fail "not checked, Lighthouse could not be installed"
  done
  exit 0
fi

for path in $LIGHTHOUSE_PATHS; do
  # Warm the caches (one hit per node behind a load balancer) so the score is not a cold start.
  for _ in $(seq 1 "${WARMUP_HITS:-2}"); do
    curl -sS -L -b "" -o /dev/null --max-time 60 ${auth[@]+"${auth[@]}"} "$BASE_URL$path" || true
  done
  report="$(mktemp)"
  # A failed run can still leave a report with most scores (e.g. one category timed out).
  incomplete=""
  node "$lh_dir/lighthouse.mjs" "$BASE_URL$path" "$report" "$FORM_FACTOR" || incomplete=" (incomplete: $(jq -r '.runtimeError.code // "error"' "$report" 2>/dev/null || echo error))"
  if [ -n "$incomplete" ] && ! jq -e '[.categories[]?.score | numbers] | length > 0' "$report" > /dev/null 2>&1; then
    rm -f "$report"
    bash "$RECORD" "lighthouse $path" soft fail "Lighthouse did not finish"
    [ -n "${REQUIRED_REQUESTS:-}" ] && bash "$RECORD" "requests $path" hard fail "not checked, Lighthouse did not finish"
    continue
  fi
  if [ -n "${REQUIRED_REQUESTS:-}" ] && [ -n "$incomplete" ] \
      && ! jq -e '.audits["network-requests"].details.items' "$report" > /dev/null 2>&1; then
    bash "$RECORD" "requests $path" hard fail "not checked, Lighthouse did not finish"
  elif [ -n "${REQUIRED_REQUESTS:-}" ]; then
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
  # A category without a score (timed out) shows as "–" and does not count as 0.
  read -r detail worst < <(jq -r '
    .categories | to_entries
    | map({k: ({performance: "Perf", accessibility: "A11y", "best-practices": "BP", seo: "SEO"}[.key]), s: (.value.score | if . == null then null else . * 100 | round end)})
    | "\(map("\(.k) \(.s // "–")") | join(" · ") | gsub(" "; "\u00a0")) \(map(.s | numbers) | min)"' "$report")
  rm -f "$report"
  if [ "$worst" -lt "$LIGHTHOUSE_MIN" ]; then
    bash "$RECORD" "lighthouse $path" hard fail "$detail (min $LIGHTHOUSE_MIN)$incomplete"
  elif [ "$worst" -lt "$LIGHTHOUSE_TARGET" ]; then
    bash "$RECORD" "lighthouse $path" soft fail "$detail (target $LIGHTHOUSE_TARGET)$incomplete"
  elif [ -n "$incomplete" ]; then
    bash "$RECORD" "lighthouse $path" soft fail "$detail$incomplete"
  else
    bash "$RECORD" "lighthouse $path" soft pass "$detail"
  fi
done
