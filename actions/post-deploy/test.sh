#!/usr/bin/env bash
# Offline tests for checks.sh: curl, npm and node (Lighthouse) are stubbed, the Lighthouse report
# lists the URLs in $MOCK_URLS. No network or Chrome required.
# Assertions are static shell expressions evaluated by check(), not expanded here.
# shellcheck disable=SC2016
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
# curl records its arguments, one per line, so header tests can check them.
# http URLs answer $MOCK_REDIRECT ("<code> <location>"), by default a correct 301 to https.
cat > "$TMP/bin/curl" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$RUNNER_TEMP/curl-args"
url="${*: -1}"
if [[ "$url" == http://* ]]; then
  echo "${MOCK_REDIRECT:-301 https://${url#http://}}"
else
  echo "200 0.1"
fi
EOF
printf '#!/usr/bin/env bash\n[ -z "${MOCK_NPM_FAIL:-}" ]\n' > "$TMP/bin/npm"
# node lighthouse.mjs <url> <report> <form-factor>; records its arguments and whether BASIC_AUTH reached it.
cat > "$TMP/bin/node" << 'EOF'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; echo "BASIC_AUTH=${BASIC_AUTH:-}"; } > "$RUNNER_TEMP/node-args"
[ -n "${MOCK_LH_FAIL:-}" ] && exit 1
out=$3
# MOCK_LH_PARTIAL: best-practices timed out, Lighthouse exits 1 but writes the report.
jq -n --arg urls "$MOCK_URLS" --arg partial "${MOCK_LH_PARTIAL:-}" '{
  categories: {performance: {score: 0.9}, accessibility: {score: 0.9}, "best-practices": {score: (if $partial == "" then 0.9 else null end)}, seo: {score: 0.9}},
  audits: {"network-requests": {details: {items: [$urls | splits(" ") | select(. != "") | {url: .}]}}}
} + (if $partial == "" then {} else {runtimeError: {code: "PROTOCOL_TIMEOUT"}} end)' > "$out"
[ -z "${MOCK_LH_PARTIAL:-}" ]
EOF
chmod +x "$TMP/bin/curl" "$TMP/bin/npm" "$TMP/bin/node"
export PATH="$TMP/bin:$PATH" RUNNER_TEMP="$TMP" RECORD="$DIR/../../lib/record.sh"
export BASE_URL=https://example.com SMOKE_PATHS=/ LIGHTHOUSE_MIN=50 LIGHTHOUSE_TARGET=80 WARMUP_HITS=1 \
  FORM_FACTOR=desktop BASIC_AUTH="" CHECK_HEADER="" CHECK_TOKEN=""
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

LIGHTHOUSE_PATHS=/en REQUIRED_REQUESTS="" MOCK_URLS="" BASIC_AUTH='stage:p@ss' run
check "basic auth reaches the Lighthouse page via the environment, not the command line" \
  '[[ "$(cat "$TMP/node-args")" == *"/lighthouse.mjs"$'"'"'\n'"'"'"https://example.com/en"$'"'"'\n'"'"'*$'"'"'\n'"'"'"desktop"$'"'"'\n'"'"'"BASIC_AUTH=stage:p@ss" ]]'

rm -f "$TMP/curl-args"
LIGHTHOUSE_PATHS="" CHECK_HEADER=X-Test-Check CHECK_TOKEN=s3cret run
check "check header and token set → smoke test sends the project's header" \
  'grep -qx "X-Test-Check: s3cret" "$TMP/curl-args"'

rm -f "$TMP/curl-args"
LIGHTHOUSE_PATHS="" CHECK_HEADER="" CHECK_TOKEN=s3cret run
check "token without header name → no header sent" \
  '! grep -q "s3cret" "$TMP/curl-args"'

LIGHTHOUSE_PATHS="/en /de" REQUIRED_REQUESTS="$GTM" MOCK_URLS="" MOCK_NPM_FAIL=1 run
check "Lighthouse install fails → soft fail per path, required requests not checked" \
  '[[ "$(result "lighthouse /de")" == "soft fail Lighthouse could not be installed" && "$(result "requests /en")" == "hard fail not checked, Lighthouse could not be installed" ]]'

LIGHTHOUSE_PATHS=/en REQUIRED_REQUESTS="$GTM" MOCK_URLS="https://www.$GTM" MOCK_LH_PARTIAL=1 run
check "Lighthouse exits 1 with partial report → scores kept, missing category shown, soft fail" \
  '[[ "$(result "lighthouse /en")" == "soft fail Perf"*"90"*"BP"*"–"*"SEO"*"90 (incomplete: PROTOCOL_TIMEOUT)" && "$(result "requests /en")" == hard\ pass* ]]'

LIGHTHOUSE_PATHS="" HTTPS_REDIRECT_PATHS="/en /de" run
check "http answers 301 to the same https URL → pass" \
  '[[ "$(result https-redirect)" == "hard pass 2 paths redirect to https" ]]'

LIGHTHOUSE_PATHS="" HTTPS_REDIRECT_PATHS=/en MOCK_REDIRECT="308 https://example.com/en" run
check "308 counts as a redirect" '[[ "$(result https-redirect)" == hard\ pass* ]]'

LIGHTHOUSE_PATHS="" HTTPS_REDIRECT_PATHS=/en MOCK_REDIRECT="200 " run
check "http answers 200 → hard fail" '[[ "$(result https-redirect)" == "hard fail no https redirect: /en (200)" ]]'

LIGHTHOUSE_PATHS="" HTTPS_REDIRECT_PATHS=/en MOCK_REDIRECT="302 https://example.com/en" run
check "temporary 302 → hard fail" '[[ "$(result https-redirect)" == hard\ fail* ]]'

LIGHTHOUSE_PATHS="" HTTPS_REDIRECT_PATHS=/en MOCK_REDIRECT="301 https://example.com/" run
check "redirect to another path → hard fail naming it" \
  '[[ "$(result https-redirect)" == "hard fail no https redirect: /en (301 → https://example.com/)" ]]'

LIGHTHOUSE_PATHS="" HTTPS_REDIRECT_PATHS="" run
check "no redirect paths → no https-redirect check" '[[ -z "$(result https-redirect)" ]]'

rm -f "$TMP/curl-args"
LIGHTHOUSE_PATHS="" HTTPS_REDIRECT_PATHS=/en BASIC_AUTH='stage:p@ss' CHECK_HEADER=X-Test-Check CHECK_TOKEN=s3cret run
check "basic auth and check token are not sent over http" \
  '[[ "$(grep -c "stage:p@ss" "$TMP/curl-args")" == 1 && "$(grep -c "s3cret" "$TMP/curl-args")" == 1 ]]'

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
