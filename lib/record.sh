#!/usr/bin/env bash
# Appends one check result to the results file of this job.
# Usage: record.sh <name> <hard|soft> <pass|fail> [detail]
set -euo pipefail

results="${RUNNER_TEMP}/kickserve-ci/results.jsonl"
mkdir -p "$(dirname "$results")"

jq -nc --arg name "$1" --arg level "$2" --arg status "$3" --arg detail "${4:-}" \
  '{name: $name, level: $level, status: $status, detail: $detail}' >> "$results"
