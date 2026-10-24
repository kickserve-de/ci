# Full rich text of the Commit-Log comment: new entries before the existing ones, capped at $max.
# Args: $new (<li> string), $old (existing story or null), $max, $header. Run with -n.
# Existing entries are normalized because Asana returns quotes as &quot; (see html in lib.jq).
([$new | scan("<li>.*?</li>")]
 + [($old.html_text // "") | gsub("&quot;"; "\"") | gsub("&#39;|&apos;"; "'") | scan("<li>.*?</li>")])
| .[:$max]
| "<body><strong>\($header)</strong><ul>\(join(""))</ul></body>"
