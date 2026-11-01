#!/usr/bin/env bash
# Runs composer audit (with php and a composer.lock) and npm/yarn audit (with node and a package.json).
# usage: audit.sh <php: true|false> <node: true|false> <npm|yarn>
# The full output stays in the log. On findings the last line names each failed audit
# with its summary ("composer: Found 1 security vulnerability advisory affecting 1 package"),
# so the PR hint never shows the clean result of the audit that ran last.
# Exit 0 clean, 1 findings, 64 usage.

{ set +x; } 2>/dev/null

[ "$#" -eq 3 ] || { echo "usage: audit.sh <php: true|false> <node: true|false> <npm|yarn>" >&2; exit 64; }
php="$1" node="$2" pm="$3"
failed=()

# run <label> <summary regex> <command...>: prints the output; on failure remembers
# "<label>: <matching lines>" (no match: the last non-empty line).
run() {
  local label="$1" pattern="$2" out code summary
  shift 2
  out="$("$@" 2>&1)"
  code=$?
  printf '%s\n' "$out"
  [ "$code" -eq 0 ] && return
  summary="$(grep -E "$pattern" <<<"$out" | sed 's/:[[:space:]]*$//' | paste -sd '|' - | sed 's/|/, /g')"
  [ -n "$summary" ] || summary="$(grep -v '^[[:space:]]*$' <<<"$out" | tail -n 1)"
  failed+=("$label: ${summary:-exit $code}")
}

if [ "$php" = true ] && [ -f composer.lock ]; then
  run composer '^Found ' composer audit --locked --no-interaction
fi
if [ "$node" = true ] && [ -f package.json ]; then
  if [ "$pm" = yarn ]; then run yarn '^[0-9]+ .*vulnerabilit' yarn audit --groups dependencies --level high
  else run npm '^[0-9]+ .*vulnerabilit' npm audit --omit=dev --audit-level=high; fi
fi

[ "${#failed[@]}" -eq 0 ] && exit 0
joined="$(printf '%s; ' "${failed[@]}")"
echo "${joined%; }"
exit 1
