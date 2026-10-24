# New PR description with the task link. Args: $body (current body), $id (task GID), optional $base
# (task URL prefix, default Asana; Kickserve Work: https://<host>/tasks). Run with -n.
# Placeholder present → replace it. Missing (empty body, template not used or changed)
# → prepend the link unless it is already there.
($ARGS.named.base // "https://app.asana.com/0/0") as $base
| "[\($id)](\($base)/\($id))" as $link
| "TASK_ID (will be automatically replaced with task ID and link)" as $placeholder
| if $body | contains($placeholder) then $body | split($placeholder) | join($link)
  elif $body | contains("\($base)/\($id)") then $body
  else "- Task: \($link)" + (if $body == "" then "" else "\n\n\($body)" end)
  end
