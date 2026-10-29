#!/usr/bin/env bash
# Offline tests for checks.sh: curl and npx (Lighthouse) are stubbed, the Lighthouse report
# lists the URLs in $MOCK_URLS. No network or Chrome required.
# Assertions are static shell expressions evaluated by check(), not expanded here.
# shellcheck disable=SC2016
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
printf '#!/usr/bin/env bash\necho "200 0.1"\n' > "$TMP/bin/curl"
cat > "$TMP/bin/npx" << 'EOF'
#!/usr/bin/env bash
[ -n "${MOCK_LH_FAIL:-}" ] && exit 1
for arg in "$@"; do
  case "$arg" in --output-path=*) out=${arg#--output-path=} ;; esac
done
jq -n --arg urls "$MOCK_URLS" '{
  categories: {performance: {score: 0.9}, accessibility: {score: 0.9}, "best-practices": {score: 0.9}, seo: {score: 0.9}},
  audits: {"network-requests": {details: {items: [$urls | splits(" ") | select(. != "") | {url: .}]}}}
}' > "$out"
EOF
chmod +x "$TMP/bin/curl" "$TMP/bin/npx"
export PATH="$TMP/bin:$PATH" RUNNER_TEMP="$TMP" RECORD="$DIR/../../lib/record.sh"
export BASE_URL=https://example.com SMOKE_PATHS=/ LIGHTHOUSE_MIN=50 LIGHTHOUSE_TARGET=80 WARMUP_HITS=1 \
  FORM_FACTOR=desktop BASIC_AUTH="" CHECK_TOKEN=""
GTM='googletagmanager.com/gtm.js?id=GTM-TG55ZK9'
PASS=0 FAIL=0

run() {
  rm -f "$TMP/kickserve-ci/results.jsonl"
  bash "$DIR/checks.sh" > /dev/null
}
result() { jq -r --arg n "$1" 'select(.name == $n) | "\(.level) \(.status) \(.detail)"' "$TMP/kickserve-ci/results.jsonl"; }
check() {
  if eval "$2"; then
    PASS=$((PASS + 1)); echo "ok   $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL $1"; cat "$TMP/kickserve-ci/results.jsonl"
  fi
}

LIGHTHOUSE_PATHS="/en /de" REQUIRED_REQUESTS="$GTM cookiehub" MOCK_URLS="https://www.$GTM https://cdn.cookiehub.eu/c2/x.js" run
check "all required requests loaded → pass per path" \
  '[[ "$(result "requests /en")" == "hard pass 2 required requests loaded" && "$(result "requests /de")" == hard\ pass* ]]'

LIGHTHOUSE_PATHS=/en REQUIRED_REQUESTS="$GTM cookiehub" MOCK_URLS="https://cdn.cookiehub.eu/c2/x.js" run
check "missing GTM → hard fail naming it" '[[ "$(result "requests /en")" == "hard fail never requested: $GTM" ]]'

LIGHTHOUSE_PATHS=/en REQUIRED_REQUESTS="$GTM" MOCK_URLS="" MOCK_LH_FAIL=1 run
check "Lighthouse did not finish → hard fail, not silently skipped" \
  '[[ "$(result "requests /en")" == "hard fail not checked, Lighthouse did not finish" ]]'

LIGHTHOUSE_PATHS="" REQUIRED_REQUESTS="$GTM" MOCK_URLS="" run
check "required requests without Lighthouse paths → hard fail" \
  '[[ "$(result requests)" == "hard fail required-requests needs lighthouse-paths" ]]'

LIGHTHOUSE_PATHS=/en REQUIRED_REQUESTS="" MOCK_URLS="" run
check "no required requests → no requests check" \
  '[[ -z "$(jq -r "select(.name | startswith(\"requests\")) | .name" "$TMP/kickserve-ci/results.jsonl")" && "$(result "lighthouse /en")" == soft\ pass* ]]'

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
