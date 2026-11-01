#!/usr/bin/env bash
# Offline tests for audit.sh with mocked composer/npm/yarn. The last output line is the
# hint run-check puts into the PR, so it must name the audit that failed.
# Usage: lib/test-audit.sh
set -uo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin" "$TMP/repo"
# Each mock prints $MOCK_<TOOL>_OUT and exits with $MOCK_<TOOL>_RC; calls are logged.
for tool in composer npm yarn; do
  var=$(tr '[:lower:]' '[:upper:]' <<<"$tool")
  cat > "$TMP/bin/$tool" <<EOF
#!/usr/bin/env bash
echo $tool >> "$TMP/calls"
printf '%b' "\${MOCK_${var}_OUT:-}"
exit "\${MOCK_${var}_RC:-0}"
EOF
  chmod +x "$TMP/bin/$tool"
done
export PATH="$TMP/bin:$PATH"
FAIL=0 PASS=0

check() { # name, actual, expected
  if [ "$2" == "$3" ]; then PASS=$((PASS + 1)); echo "ok   $1"
  else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$3" "$2"; fi
}

# audit <php> <node> <pm>: prints "<exit code> | <last line> | <tools called>"
audit() {
  : > "$TMP/calls"
  local out code
  out="$(cd "$TMP/repo" && bash "$DIR/audit.sh" "$@" 2>&1)"
  code=$?
  echo "$code | $(grep -v '^[[:space:]]*$' <<<"$out" | tail -n 1) | $(paste -sd' ' - < "$TMP/calls")"
}

COMPOSER_FOUND='Found 1 security vulnerability advisory affecting 1 package:\n+---------+\n| Package | symfony/mime |\n+---------+\n'
COMPOSER_CLEAN='No security vulnerability advisories found.\n'
NPM_CLEAN='found 0 vulnerabilities\n'
NPM_FOUND='# npm audit report\n\naxios  <1.8.2\nSeverity: high\n\n2 vulnerabilities (1 moderate, 1 high)\n\nTo address all issues, run:\n  npm audit fix\n'
YARN_FOUND='┌───────┐\n│ high  │\n└───────┘\n5 vulnerabilities found - Packages audited: 832\nSeverity: 2 Moderate | 3 High\nDone in 1.2s.\n'

touch "$TMP/repo/composer.lock" "$TMP/repo/package.json"

echo "── hint names the failed audit"
check "composer finding, npm clean → composer summary, not npm's clean line" \
  "$(MOCK_COMPOSER_OUT=$COMPOSER_FOUND MOCK_COMPOSER_RC=1 MOCK_NPM_OUT=$NPM_CLEAN audit true true npm)" \
  "1 | composer: Found 1 security vulnerability advisory affecting 1 package | composer npm"
check "npm finding → npm summary line" \
  "$(MOCK_COMPOSER_OUT=$COMPOSER_CLEAN MOCK_NPM_OUT=$NPM_FOUND MOCK_NPM_RC=1 audit true true npm)" \
  "1 | npm: 2 vulnerabilities (1 moderate, 1 high) | composer npm"
check "both fail → both named" \
  "$(MOCK_COMPOSER_OUT=$COMPOSER_FOUND MOCK_COMPOSER_RC=1 MOCK_NPM_OUT=$NPM_FOUND MOCK_NPM_RC=1 audit true true npm)" \
  "1 | composer: Found 1 security vulnerability advisory affecting 1 package; npm: 2 vulnerabilities (1 moderate, 1 high) | composer npm"
check "yarn finding → yarn summary line" \
  "$(MOCK_YARN_OUT=$YARN_FOUND MOCK_YARN_RC=12 audit false true yarn)" \
  "1 | yarn: 5 vulnerabilities found - Packages audited: 832 | yarn"
check "composer advisories and abandoned packages → both lines" \
  "$(MOCK_COMPOSER_OUT="${COMPOSER_FOUND}Found 1 abandoned package:\n| foo/bar | none |\n" MOCK_COMPOSER_RC=1 audit true false npm)" \
  "1 | composer: Found 1 security vulnerability advisory affecting 1 package, Found 1 abandoned package | composer"
check "no summary line → last output line" \
  "$(MOCK_COMPOSER_OUT='\nLock file is not up to date\n\n' MOCK_COMPOSER_RC=2 audit true false npm)" \
  "1 | composer: Lock file is not up to date | composer"
check "no output → exit code" \
  "$(MOCK_NPM_RC=3 audit false true npm)" \
  "1 | npm: exit 3 | npm"

echo "── clean and skipped"
check "all clean → exit 0, last tool's line" \
  "$(MOCK_COMPOSER_OUT=$COMPOSER_CLEAN MOCK_NPM_OUT=$NPM_CLEAN audit true true npm)" \
  "0 | found 0 vulnerabilities | composer npm"
check "php false → no composer audit" "$(MOCK_NPM_OUT=$NPM_CLEAN audit false true npm)" "0 | found 0 vulnerabilities | npm"
check "node false → no npm audit" "$(MOCK_COMPOSER_OUT=$COMPOSER_CLEAN audit true false npm)" "0 | No security vulnerability advisories found. | composer"
rm "$TMP/repo/composer.lock" "$TMP/repo/package.json"
check "no composer.lock / package.json → nothing runs" "$(audit true true npm)" "0 |  | "

echo "── usage"
check "wrong argument count → 64" "$(audit true true 2>/dev/null | cut -d' ' -f1)" "64"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
