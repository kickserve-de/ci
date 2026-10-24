# New <li> entries for a task's Commit-Log, newest first. Every entry names its repo.
# Input: entries.json. Args: $t (task GID), $now.
include "lib";

[.[] | select(.task == $t)] | reverse | map(
  if .type == "PUSH" then
    "<li><strong>[PUSH]</strong> \($now | html) · \(.author | html) · <code>\(.repo | html):\(.branch | html)</code> · <a href=\"\(.link | @html)\">\(.sha | html)</a> \(.subject | html)</li>"
  else
    "<li><strong>\(if .type == "PR" then "[PR]" elif .type == "MERGED_MAIN" then "✅ [MERGED]" else "[MERGED]" end)</strong> \($now | html) · \(.author | html) · <code>\(.repo | html): \(.source | html) → \(.branch | html)</code> · <a href=\"\(.link | @html)\">#\(.number)</a> \(.subject | html)</li>"
  end
) | join("")
