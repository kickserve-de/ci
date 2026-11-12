#!/usr/bin/env bash
# Offline tests for the host-side database code of sync-staging-deployer.yml: the
# DB_URL_PARSE and SYNC_HELPERS env blocks are read from the workflow (Ruby's YAML)
# and run against a fake deploy path, with sh (and dash when present) as the host
# shell and a mocked mysqldump.
# Usage: lib/test-sync-staging.sh
# sh for the "host" stays in single quotes; ENV_FILE, DB_* and db_name belong to the eval'd helpers.
# shellcheck disable=SC2016,SC2034,SC2154
set -uo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
WORKFLOW="$DIR/../.github/workflows/sync-staging-deployer.yml"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAIL=0 PASS=0

check() { # name, actual, expected
  if [ "$2" == "$3" ]; then PASS=$((PASS + 1)); echo "ok   $1"
  else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$3" "$2"; fi
}

env_block() { ruby -ryaml -e 'print YAML.load_file(ARGV[0])["env"][ARGV[1]]' "$WORKFLOW" "$1"; }
DB_URL_PARSE=$(env_block DB_URL_PARSE)
SYNC_HELPERS=$(env_block SYNC_HELPERS)
[ -n "$DB_URL_PARSE" ] && [ -n "$SYNC_HELPERS" ] || { echo "FAIL env blocks not found in $WORKFLOW"; exit 1; }
eval "$SYNC_HELPERS"

# mysqldump mock: prints its arguments and the password it got via MYSQL_PWD.
mkdir "$TMP/bin"
cat > "$TMP/bin/mysqldump" <<'EOF'
#!/bin/sh
echo "args: $*"
echo "pwd: $MYSQL_PWD"
EOF
chmod +x "$TMP/bin/mysqldump"
export PATH="$TMP/bin:$PATH"

shells=(sh)
command -v dash >/dev/null && shells+=(dash)

for shell in "${shells[@]}"; do
  # parse <url>: "user|pass|host|port|name" or "fail"
  parse() {
    u="$1" "$shell" -c "$DB_URL_PARSE"' && printf "%s|%s|%s|%s|%s" "$SYNC_DB_USER" "$SYNC_DB_PASS" "$SYNC_DB_HOST" "$SYNC_DB_PORT" "$SYNC_DB_NAME"' 2>/dev/null || echo fail
  }
  check "$shell: plain URL, default port" "$(parse 'mysql://shop:secret@localhost/shopware')" "shop|secret|localhost|3306|shopware"
  check "$shell: port and query" "$(parse 'mysql://shop:secret@db.example:3307/shopware?serverVersion=8.0')" "shop|secret|db.example|3307|shopware"
  check "$shell: percent-encoded password" "$(parse 'mysql://shop:p%40ss%3Aw%2Fd%25@db:3306/shopware')" "shop|p@ss:w/d%|db|3306|shopware"
  check "$shell: raw @ and : in password" "$(parse 'mysql://shop:pa@ss:wd@db/shopware')" "shop|pa@ss:wd|db|3306|shopware"
  check "$shell: non-ASCII password" "$(parse 'mysql://shop:%C3%A4bc@db/shopware')" "shop|äbc|db|3306|shopware"
  check "$shell: no credentials fails" "$(parse 'mysql://db/shopware')" "fail"
  check "$shell: no database fails" "$(parse 'mysql://shop:secret@db')" "fail"
  check "$shell: empty URL fails" "$(parse '')" "fail"

  # The workflow's $SSH, with the given shell as the host.
  SSH="$shell -c"
  mkdir -p "$TMP/$shell/url/shared" "$TMP/$shell/env/shared"
  printf '%s\n' "DATABASE_URL=\"mysql://shop:p%40ss@db.prod:3307/shopware\"" > "$TMP/$shell/url/shared/.env.local"
  printf '%s\n' 'DB_HOST=db.staging' 'DB_USERNAME=app' 'DB_PASSWORD="s3cr et"' 'DB_DATABASE=app_staging' > "$TMP/$shell/env/shared/.env"

  ENV_FILE=shared/.env.local DB_URL_ENV=DATABASE_URL
  check "$shell: db_of with db-url-env" "$(db_of "$TMP/$shell/url")" "db.prod:3307/shopware"
  out=$($SSH "$(db_run "$TMP/$shell/url" mysqldump --quick "$db_name" 'users')")
  check "$shell: db_run passes host, port, user, name" "$(sed -n 1p <<<"$out")" "args: -h db.prod -P 3307 -u shop --quick shopware users"
  check "$shell: db_run password only via MYSQL_PWD" "$(sed -n 2p <<<"$out")" "pwd: p@ss"
  out=$($SSH "$(db_run "$TMP/$shell/missing" mysqldump "$db_name")" 2>/dev/null)
  check "$shell: missing deploy path runs nothing" "$out" ""

  ENV_FILE=shared/.env DB_URL_ENV='' DB_ENV='DB_HOST DB_PORT DB_USERNAME DB_PASSWORD DB_DATABASE'
  check "$shell: db_of with db-env" "$(db_of "$TMP/$shell/env")" "db.staging:3306/app_staging"
  out=$($SSH "$(db_run "$TMP/$shell/env" mysqldump "$db_name")")
  check "$shell: db-env password with space" "$(sed -n 2p <<<"$out")" "pwd: s3cr et"

  ENV_FILE=shared/.env DB_URL_ENV=DATABASE_URL
  out=$($SSH "$(db_run "$TMP/$shell/env" mysqldump "$db_name")" 2>/dev/null)
  check "$shell: db-url-env not set in env-file runs nothing" "$out" ""
done

# Files-only flow: the step scripts from the workflow, with bash as the host.
step() { ruby -ryaml -e 'j = YAML.load_file(ARGV[0])["jobs"][ARGV[1]]; print j["steps"].find { |s| s["name"] == ARGV[2] }["run"]' "$WORKFLOW" "$1" "$2"; }
run_step() { (cd "$TMP/repo" && bash -e -c "$(step "$1" "$2")") >"$TMP/step.log" 2>&1; }
P="$TMP/files/prod/shared" S="$TMP/files/stage/shared"
mkdir -p "$P/content/a" "$P/storage/forms" "$S/storage/forms" "$S/storage/accounts" "$TMP/repo/dev"
echo 'Title: A' > "$P/content/a/page.txt"; echo 'Email: x@example.com' > "$P/storage/forms/entry.txt"
echo 'old' > "$S/storage/forms/old.txt"; echo 'staging user' > "$S/storage/accounts/user.txt"
printf '#!/bin/sh\nset -e\nrm -rf storage/forms\n' > "$TMP/repo/dev/anonymize.sh"
export SSH="bash -c" PRODUCTION_PATH="$TMP/files/prod" STAGING_PATH="$TMP/files/stage" SYNC_DIRS="content storage/forms" \
  EXCLUDE="" FILES_TMP="$TMP/files/stage/.sync-files-1" ANONYMIZE_FILES=dev/anonymize.sh
run_step dump 'Copy and anonymize folders' && run_step sync 'Copy folders'
check "files: content copied" "$(cat "$S/content/a/page.txt" 2>&1)" "Title: A"
check "files: folder the script deleted is emptied on staging" "$(ls -A "$S/storage/forms" 2>&1)" ""
check "files: staging folders outside sync-dirs stay" "$(cat "$S/storage/accounts/user.txt" 2>&1)" "staging user"
run_step sync 'Clean up'
check "files: copy removed after the sync" "$(ls -A "$TMP/files/stage")" "shared"
printf '#!/bin/sh\nexit 3\n' > "$TMP/repo/dev/anonymize.sh"
run_step dump 'Copy and anonymize folders' && rc=0 || rc=failed
check "files: failing script fails the step" "$rc" "failed"
run_step dump 'Remove the folder copy'
check "files: copy removed after a failure" "$(ls -A "$TMP/files/stage")" "shared"

# Snapshot: curl, unzip and rclone mocked; rclone rcat keeps the archive in $TMP/archive.tgz.
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = -o ] && touch "$2"; shift; done
EOF
cat > "$TMP/bin/unzip" <<'EOF'
#!/bin/sh
while [ $# -gt 1 ]; do shift; done
printf '#!/bin/sh\nfor a; do [ "$a" = rcat ] && exec cat > "$ARCHIVE"; done\nexit 0\n' > "$1/rclone"
chmod +x "$1/rclone"
EOF
chmod +x "$TMP/bin/curl" "$TMP/bin/unzip"
mkdir -p "$S/content/a/big" && echo zip > "$S/content/a/big/archive.zip"
touch "$TMP/repo/match.zip" # a file in the working directory must not expand the pattern
mkdir -p "$TMP/runner/sync-ssh"
export RUNNER_TEMP="$TMP/runner" ARCHIVE="$TMP/archive.tgz" DATABASE=false RCLONE_CONFIG_CONTENT=eA== FOLDER=f NAME=n \
  REMOTE=r KEEP_DAYS=30 SYNC_DIRS="content" SNAPSHOT_EXCLUDE="*.zip"
run_step sync 'Snapshot to Google Drive' && rc=0 || rc=failed
check "snapshot: step succeeds" "$rc" "0"; [ "$rc" = 0 ] || cat "$TMP/step.log"
check "snapshot: snapshot-exclude left out of the archive" "$(tar tzf "$ARCHIVE" 2>&1 | grep -v '/$')" "content/a/page.txt"
check "snapshot: staging keeps excluded files" "$(cat "$S/content/a/big/archive.zip")" "zip"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
