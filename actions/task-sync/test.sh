#!/usr/bin/env bash
# Tests for the jq filters of the task-sync action.
# Usage: actions/task-sync/test.sh   (other jq binary: JQ=/path/to/jq actions/task-sync/test.sh)
set -uo pipefail

cd "$(dirname "$0")"
JQ=${JQ:-jq}
A=1111111111111111 B=2222222222222222 P=9999999999999999
FAIL=0 PASS=0

check() { # name, actual, expected
  if [ "$2" == "$3" ]; then PASS=$((PASS + 1)); echo "ok   $1"
  else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$3" "$2"; fi
}

entries() { # event, ref, payload, [commit_msgs]
  $JQ -c -L . --arg event "$1" --arg ref "$2" --arg repo kickserve-de/repo --arg main main \
    --argjson commit_msgs "${4:-[]}" -f entries.jq <<< "$3"
}

commit() { # id, message, [distinct], [committer]
  $JQ -n --arg id "$1" --arg m "$2" --argjson d "${3:-true}" --arg c "${4:-dev}" \
    '{id: $id, message: $m, distinct: $d, url: "https://github.com/c/\($id)",
      author: {username: "dev", name: "Dev"}, committer: {username: $c}}'
}

pr() { # action, merged, base, title, head
  $JQ -n --arg a "$1" --argjson m "$2" --arg base "$3" --arg t "$4" --arg head "$5" \
    '{action: $a, pull_request: {merged: $m, title: $t, number: 7, html_url: "https://github.com/pr/7",
      base: {ref: $base}, head: {ref: $head}, user: {login: "opener"}, merged_by: (if $m then {login: "merger"} else null end)}}'
}

echo "── Push"
PUSH=$($JQ -s '{commits: .}' <(
  commit c1 "feat: first without ID"
  commit c2 "fix: second for B ($B)"
  commit c3 "chore: already known ($B)" false
  commit c4 "Merge pull request #1 ($B)" true web-flow
  commit c5 "docs: third with link https://app.asana.com/0/$P/$A/f and body

Second line ($B)"
))
E=$(entries push "feature/$A-test" "$PUSH")
check "distinct only, no web-flow" "$($JQ -c 'map(.sha)' <<< "$E")" '["c1","c2","c5"]'
check "task IDs: branch, message, URL instead of project" "$($JQ -c 'map(.task)' <<< "$E")" "[\"$A\",\"$B\",\"$A\"]"
check "task sources" "$($JQ -c 'map(.task_source)' <<< "$E")" '["branch","message","message"]'
check "subjects cleaned" "$($JQ -c 'map(.subject)' <<< "$E")" '["feat: first without ID","fix: second for B","docs: third with link and body"]'
check "branch without ID, commit without ID → nothing" "$(entries push feature/x '{"commits":[{"id":"a","message":"x","distinct":true,"committer":{}}]}')" '[]'
check "push without commits (branch deletion)" "$(entries push feature/x '{}')" '[]'

echo "── Kickserve Work IDs (17 digits)"
K=17919966507813712
E17=$(entries push "feat/x-$K" "$($JQ -s '{commits: .}' <(commit k1 "fix: link https://work.kickserve.de/tasks/$K" ; commit k2 "feat: plain ($K)"))")
check "17-digit IDs from branch and message" "$($JQ -c 'map(.task)' <<< "$E17")" "[\"$K\",\"$K\"]"
check "17-digit ID removed from subject" "$($JQ -c 'map(.subject)' <<< "$E17")" '["fix: link","feat: plain"]'

echo "── Log entries"
ITEMS=$($JQ -r -L . --arg t "$A" --arg now "2026-10-01 12:00" -f log-items.jq <<< "$E")
check "newest on top (commits arrive oldest first)" "$(grep -o 'c/c[0-9]' <<< "$ITEMS" | tr '\n' ' ')" "c/c5 c/c1 "
check "PUSH format" "${ITEMS%%</li>*}</li>" '<li><strong>[PUSH]</strong> 2026-10-01 12:00 · dev · <code>kickserve-de/repo:feature/1111111111111111-test</code> · <a href="https://github.com/c/c5">c5</a> docs: third with link and body</li>'

echo "── Special characters"
SPECIAL=$($JQ -s '{commits: .}' <(
  commit s1 "\"double\" and 'single' quotes ($A)"
  commit s2 "<b>HTML</b> & <script>alert(1)</script> ($A)"
  commit s3 'Backslash \n \t \\ ('$A')'
  commit s4 'Backticks `code` ('$A')'
  commit s5 '$HOME $(whoami) ${PATH} ('$A')'
  commit s6 "Umlauts äöüß ÄÖÜ ($A)"
  commit s7 "Emoji 🚲🔥 ($A)"
  commit s8 "100% done %s %d ($A)"
  commit s9 "fix: with https://app.asana.com/1/$P/project/$P/task/$A?focus=true inside"
  commit s10 "feat: multiline $A ()

Body with <tags> and ($B)"
))
S=$($JQ -r -L . --arg t "$A" --arg now n -f log-items.jq <<< "$(entries push feature/x "$SPECIAL")" \
  | grep -o '</a> [^<]*</li>' | sed 's|</a> ||; s|</li>||' | awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }')
EXPECTED=$(cat <<'EOF'
"double" and 'single' quotes
&lt;b&gt;HTML&lt;/b&gt; &amp; &lt;script&gt;alert(1)&lt;/script&gt;
Backslash \n \t \\
Backticks `code`
$HOME $(whoami) ${PATH}
Umlauts äöüß ÄÖÜ
Emoji 🚲🔥
100% done %s %d
fix: with inside
feat: multiline
EOF
)
check "special characters escaped, quotes literal" "$S" "$EXPECTED"
check "all special-character commits in task A" \
  "$(entries push feature/x "$SPECIAL" | $JQ -c '[.[].task] | unique')" "[\"$A\"]"

echo "── Pull requests"
check "PR opened" "$(entries pull_request feature/x "$(pr opened false develop "feat: Checkout ($A)" "feature/whatever")" \
  | $JQ -c 'map([.task, .task_source, .type, .author, .branch, .source, .subject])')" \
  "[[\"$A\",\"title\",\"PR\",\"opener\",\"develop\",\"feature/whatever\",\"feat: Checkout\"]]"
check "PR merged into main" "$(entries pull_request x "$(pr closed true main "feat: X ($A)" feature/x)" | $JQ -c 'map([.type, .author])')" \
  '[["MERGED_MAIN","merger"]]'
check "PR merged into develop" "$(entries pull_request x "$(pr closed true develop "feat: X" "feature/$B-x")" | $JQ -c 'map([.type, .task, .task_source])')" \
  "[[\"MERGED\",\"$B\",\"branch\"]]"
check "PR closed without merge" "$(entries pull_request x "$(pr closed false develop "feat: X ($A)" feature/x)")" '[]'
check "PR edited/synchronize ignored" "$(entries pull_request x "$(pr synchronize false develop "feat: X ($A)" feature/x)")" '[]'

echo "── Truncated title (GitHub cuts long titles with …)"
TRUNC=$(pr opened false develop "Rework checkout with a very long title 12098765432…" feature/no-id)
MSGS="[\"wip\", \"feat: Checkout ($A)\", \"fix: something else ($B)\", \"fix: again ($A)\"]"
E=$(entries pull_request x "$TRUNC" "$MSGS")
check "task from first PR commit" "$($JQ -c 'map([.task, .task_source])' <<< "$E")" "[[\"$A\",\"commits\"]]"
check "multiple commit IDs collected (for warning)" "$($JQ -c '.[0].commit_tasks' <<< "$E")" "[\"$A\",\"$B\"]"
check "ID fragment removed from title end (…)" "$($JQ -r '.[0].subject' <<< "$E")" "Rework checkout with a very long title"
check "ID fragment removed from title end (...)" \
  "$(entries pull_request x "$(pr opened false develop "Checkout (120987..." feature/x)" "[\"$A\"]" | $JQ -r '.[0].subject')" "Checkout"
check "title ID wins over commit ID" \
  "$(entries pull_request x "$(pr opened false develop "feat ($B)" feature/x)" "[\"$A\"]" | $JQ -r '.[0].task')" "$B"
check "no ID anywhere → nothing" "$(entries pull_request x "$TRUNC" '["wip"]')" '[]'

echo "── Merge comment"
M=$($JQ -r -L . --arg now n -f merge-comment.jq <<< "$(entries pull_request x "$(pr closed true main "feat: \"X\" & <Y> ($A)" feature/x)" | $JQ -c '.[0]')")
check "merge comment" "$M" '<body><strong>✅ Merged into main</strong>
merger merged PR <a href="https://github.com/pr/7">#7 feat: "X" &amp; &lt;Y&gt;</a> from <code>feature/x</code> into <code>kickserve-de/repo:main</code>.
<em>n</em></body>'

echo "── Merging the Commit-Log"
log() { $JQ -rn --arg new "$1" --argjson old "$2" --argjson max "$3" --arg header Commit-Log -f commit-log.jq; }
check "create new" "$(log '<li>1</li>' null 50)" '<body><strong>Commit-Log</strong><ul><li>1</li></ul></body>'
check "new before old" "$(log '<li>3</li><li>2</li>' '{"html_text":"<body><strong>Commit-Log</strong><ul><li>1</li></ul></body>"}' 50)" \
  '<body><strong>Commit-Log</strong><ul><li>3</li><li>2</li><li>1</li></ul></body>'
check "cap at max" "$(log '<li>3</li><li>2</li>' '{"html_text":"<ul><li>1</li><li>0</li></ul>"}' 3)" \
  '<body><strong>Commit-Log</strong><ul><li>3</li><li>2</li><li>1</li></ul></body>'
check "quote entities from Asana normalized" "$(log '' '{"html_text":"<ul><li>&quot;a&quot; &#39;b&#39; &amp;</li></ul>"}' 50)" \
  "<body><strong>Commit-Log</strong><ul><li>\"a\" 'b' &amp;</li></ul></body>"

echo "── PR description"
body() { $JQ -rn --arg body "$1" --arg id "$A" -f pr-body.jq; }
LINK="[$A](https://app.asana.com/0/0/$A)"
check "placeholder replaced" "$(body $'- Asana Task: TASK_ID (will be automatically replaced with task ID and link)\r\n\r\nText')" \
  $'- Asana Task: '"$LINK"$'\r\n\r\nText'
check "empty body" "$(body '')" "- Task: $LINK"
check "no placeholder → prepend" "$(body 'My text')" "- Task: $LINK"$'\n\nMy text'
check "link already present → unchanged" "$(body "See $LINK")" "See $LINK"

echo
echo "$PASS passed, $FAIL failed ($($JQ --version))"
[ "$FAIL" -eq 0 ]
