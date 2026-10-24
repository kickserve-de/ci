# New <li> entries for a task's Commit-Log, newest first.
# Input: entries.json. Args: $t (task GID), $now.
include "lib";

[.[] | select(.task == $t and .type != "MERGED_MAIN")] | reverse | map(
  if .type == "PUSH" then
    "<li><strong>[PUSH]</strong> \($now | html) · \(.author | html) · <code>\(.repo | html):\(.branch | html)</code> · <a href=\"\(.link | @html)\">\(.sha | html)</a> \(.subject | html)</li>"
  else
    "<li><strong>[\(if .type == "PR" then "PR" else "MERGED" end)]</strong> \($now | html) · \(.author | html) · <code>\(.source | html) → \(.branch | html)</code> · <a href=\"\(.link | @html)\">#\(.number)</a> \(.subject | html)</li>"
  end
) | join("")
