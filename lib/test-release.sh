#!/usr/bin/env bash
# Offline tests for the release helpers: next-version.sh (numbering, notes base) and
# deployments.sh (against tests/mock-gh.sh). No token or network required.
# Usage: lib/test-release.sh
set -uo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
ln -s "$DIR/tests/mock-gh.sh" "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GITHUB_REPOSITORY=o/r
FAIL=0 PASS=0
HEAD=hhhhhhh

check() { # name, actual, expected
  if [ "$2" == "$3" ]; then PASS=$((PASS + 1)); echo "ok   $1"
  else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$3" "$2"; fi
}

# tags ("<tag> <sha>" lines), releases (tag names, newest first); then the next-version.sh mode and argument
nv() { printf '%b' "$1" > "$TMP/tags"; printf '%b' "$2" > "$TMP/releases"; bash "$DIR/next-version.sh" "$3" "$4" "$TMP/tags" "$TMP/releases" | paste -sd' ' -; }

echo "── next"
check "no tags → version 1, notes from everything" "$(nv '' '' next $HEAD)" "version=1 on_head=false previous="
check "versions sort numerically" "$(nv '9 a\n10 b\n2 c\n' '10\n9\n' next $HEAD)" "version=11 on_head=false previous=10"
check "latest version on HEAD → same version" "$(nv "9 a\n10 $HEAD\n" '' next $HEAD)" "version=10 on_head=true previous="
check "older version on HEAD does not count" "$(nv "9 $HEAD\n10 b\n" '' next $HEAD)" "version=11 on_head=false previous=10"
check "semver tags are ignored for the number" "$(nv 'v2.0.0 a\n3 b\nrelease-7 c\n' 'v2.0.0\n' next $HEAD)" "version=4 on_head=false previous=3"
check "version 1 after semver releases → newest release" "$(nv 'v1.10.0 a\nv1.9.2 b\n' 'v1.9.2\nv1.10.0\n' next $HEAD)" "version=1 on_head=false previous=v1.9.2"
check "version 1 after tags without releases → highest tag" "$(nv 'v1.9.2 a\nv1.10.0 b\n' '' next $HEAD)" "version=1 on_head=false previous=v1.10.0"
check "leading zeros count as numbers" "$(nv "007 $HEAD\n" '' next $HEAD)" "version=007 on_head=true previous="
check "tags file without trailing newline" "$(nv '4 a' '' next $HEAD)" "version=5 on_head=false previous=4"

echo "── previous"
check "highest version below" "$(nv '12 a\n14 b\n15 c\n' '15\n14\n12\n' previous 14)" "12"
check "version 1 skips its own numeric release" "$(nv "1 $HEAD\nv3.1 a\n" '1\nv3.1\n' previous 1)" "v3.1"
check "nothing before the first version" "$(nv "1 $HEAD\n" '1\n' previous 1)" ""

echo "── usage"
bash "$DIR/next-version.sh" next $HEAD 2> /dev/null; check "missing files → 64" "$?" 64
bash "$DIR/next-version.sh" previous x "$TMP/tags" "$TMP/releases" 2> /dev/null; check "non-numeric version → 64" "$?" 64
bash "$DIR/deployments.sh" live production 2> /dev/null; check "deployments usage → 64" "$?" 64

echo "── deployments"
fixture() { # path, json
  printf '%s\n' "$2" > "$MOCK_GH_DIR/$(tr '/?&=' '____' <<< "repos/o/r/$1").json"
}
case_dir() { export MOCK_GH_DIR="$TMP/gh-$((PASS + FAIL))"; mkdir "$MOCK_GH_DIR"; : > "$MOCK_GH_DIR/calls"; }
dep() { bash "$DIR/deployments.sh" "$@" 2> "$MOCK_GH_DIR/err"; }

case_dir
fixture "deployments?environment=production&sha=$HEAD&per_page=100" '[{"id":1},{"id":2}]'
fixture "deployments/1/statuses?per_page=100" '[{"state":"failure"},{"state":"in_progress"}]'
fixture "deployments/2/statuses?per_page=100" '[{"state":"inactive"},{"state":"success"},{"state":"in_progress"}]'
check "success in the history counts, also when inactive later" "$(dep live production $HEAD)" true

case_dir
fixture "deployments?environment=production&sha=$HEAD&per_page=100" '[{"id":1}]'
fixture "deployments/1/statuses?per_page=100" '[{"state":"failure"}]'
check "only failed deployments → not live" "$(dep live production $HEAD)" false

case_dir
fixture "deployments?environment=production&sha=$HEAD&per_page=100" '[]'
check "no deployment → not live" "$(dep live production $HEAD)" false

case_dir
fixture "deployments?environment=prod%20eu&sha=$HEAD&per_page=100" '[]'
check "environment name is URL-encoded" "$(dep live 'prod eu' $HEAD)" false

case_dir
fixture "deployments?environment=production&sha=$HEAD&per_page=100" '[{"id":1}]'
OUT=$(dep live production $HEAD); RC=$?
check "status read error fails instead of reading as not live" "$RC:$OUT" "1:"

case_dir
OUT=$(dep live production $HEAD); RC=$?
check "list error fails" "$RC:$OUT" "1:"

case_dir
fixture "deployments?environment=production&per_page=100" \
  "[{\"id\":5,\"sha\":\"$HEAD\"},{\"id\":4,\"sha\":\"ccc\"},{\"id\":3,\"sha\":\"bbb\"},{\"id\":2,\"sha\":\"aaa\"}]"
fixture "deployments/4/statuses?per_page=100" '[{"state":"failure"}]'
fixture "deployments/3/statuses?per_page=100" '[{"state":"success"}]'
check "previous = newest successful other commit" "$(dep previous production $HEAD)" bbb
check "stops at the first match, skips its own commit" "$(paste -sd' ' - < "$MOCK_GH_DIR/calls")" \
  "repos/o/r/deployments?environment=production&per_page=100 repos/o/r/deployments/4/statuses?per_page=100 repos/o/r/deployments/3/statuses?per_page=100"

case_dir
fixture "deployments?environment=production&per_page=100" '[]'
OUT=$(dep previous production $HEAD); RC=$?
check "no previous deployment → nothing, exit 0" "$RC:$OUT" "0:"

case_dir
fixture "deployments?environment=production&per_page=100" "[{\"id\":1,\"sha\":\"$HEAD\"}]"
OUT=$(dep previous production $HEAD); RC=$?
check "only its own deployment → nothing, exit 0" "$RC:$OUT" "0:"

case_dir
fixture "deployments?environment=production&per_page=100" '[{"id":1,"sha":"aaa"}]'
fixture "deployments/1/statuses?per_page=100" '[{"state":"failure"}]'
OUT=$(dep previous production $HEAD); RC=$?
check "only failed other deployments → nothing, exit 0" "$RC:$OUT" "0:"

echo
echo "$PASS passed, $FAIL failed (release helpers)"
[ "$FAIL" -eq 0 ]
