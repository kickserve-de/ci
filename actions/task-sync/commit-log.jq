# Full rich text of the Commit-Log comment (the one comment per task): new entries before the existing ones.
# Args: $new (<li> string), $old (existing story or null), $max, $header, $main. Run with -n.
# - Adjacent pushes to the same repo:branch collapse into one entry linking the GitHub diff from the first to
#   the last commit, so many commits never make the comment long.
# - PRs into $main (opened and merged) always stay; $max caps only the other entries.
# Existing entries are normalized because Asana returns quotes as &quot; (see html in lib.jq).
def push_re: "^<li><strong>\\[PUSH\\]</strong> (?<head>.*?) · <code>(?<rb>[^<]*)</code> · <a href=\"(?<base>https://github\\.com/[^\"/]+/[^\"/]+)/(commit/(?<sha>[0-9a-f]+)|compare/(?<first>[0-9a-f]+)\\^\\.\\.\\.(?<last>[0-9a-f]+))\">(?<label>[^<]*)</a> ?(?<subject>.*)</li>$";

def parse:
  . as $li
  | [capture(push_re)] | first
  | if . == null then {li: $li}
    else {li: $li, push: true, head, rb, base, subject,
          first: (.first // .sha), last: (.last // .sha),
          count: (if .sha then 1 else (.label | capture("^(?<n>[0-9]+)") | .n | tonumber) end)}
    end;

def render:
  if .push and .count > 1 then
    "<li><strong>[PUSH]</strong> \(.head) · <code>\(.rb)</code> · <a href=\"\(.base)/compare/\(.first)^...\(.last)\">\(.count) commits</a> \(.subject)</li>"
  else .li end;

([$new | scan("<li>.*?</li>")]
 + [($old.html_text // "") | gsub("&quot;"; "\"") | gsub("&#39;|&apos;"; "'") | scan("<li>.*?</li>")])
| map(parse)
# newest first: an older push to the same repo:branch extends the newer entry backwards
| reduce .[] as $i ([];
    if $i.push and (.[-1].push // false) and .[-1].rb == $i.rb
    then .[length - 1] |= (.first = $i.first | .count += $i.count)
    else . + [$i] end)
| map(render)
| reduce .[] as $li ({n: 0, out: []};
    if $li | contains(" → \($main)</code>") then .out += [$li]
    elif .n < $max then .n += 1 | .out += [$li]
    else . end)
| "<body><strong>\($header)</strong><ul>\(.out | join(""))</ul></body>"
