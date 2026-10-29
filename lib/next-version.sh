#!/usr/bin/env bash
# Version numbers for "Release": a version is a tag that is a plain integer (1, 2, 3 …);
# every other tag (e.g. v1.8.7) is ignored for the numbering.
# usage: next-version.sh next <sha> <tags-file> <releases-file>
#          version=<n>, on_head=<true|false>, previous=<ref>
#          on_head=true: the latest version already sits on <sha> and <n> is that version;
#          otherwise <n> is the next number (1 when none exists) and <ref> where its notes start.
#        next-version.sh previous <version> <tags-file> <releases-file>
#          the ref <version> follows: the highest version below it, else the newest release with a
#          non-numeric tag, else the highest non-numeric tag (version sort), else nothing.
# tags-file: "<tag> <commit sha>" per line; releases-file: release tag names, newest first.
# Exit 0, 64 usage.
set -euo pipefail

usage() {
  echo "usage: next-version.sh next <sha> <tags-file> <releases-file>" >&2
  echo "       next-version.sh previous <version> <tags-file> <releases-file>" >&2
  exit 64
}
[ "$#" -eq 4 ] && [ -f "$3" ] && [ -f "$4" ] || usage
mode=$1 arg=$2 tags=$3 releases=$4

# "<number> <tag> <sha>" per version, lowest first (the tag keeps leading zeros, the number does not).
versions() { awk '$1 ~ /^[0-9]+$/ { n = $1; sub(/^0+/, "", n); print (n == "" ? 0 : n), $1, $2 }' "$tags" | sort -n -k1,1; }

previous() {
  local ref
  ref=$(versions | awk -v v="$1" '$1 < v + 0 { t = $2 } END { print t }')
  [ -n "$ref" ] || ref=$(grep -vxE '[0-9]+' "$releases" | sed -n '1p' || true)
  [ -n "$ref" ] || ref=$(awk '$1 !~ /^[0-9]+$/ { print $1 }' "$tags" | sort -V | tail -n1)
  echo "$ref"
}

case "$mode" in
  next)
    latest=$(versions | tail -n1)
    read -r number tag sha <<< "${latest:-0 - -}"
    if [ -n "$latest" ] && [ "$sha" = "$arg" ]; then
      printf 'version=%s\non_head=true\nprevious=\n' "$tag"
    else
      version=$((number + 1))
      printf 'version=%s\non_head=false\nprevious=%s\n' "$version" "$(previous "$version")"
    fi
    ;;
  previous)
    [[ "$arg" =~ ^[0-9]+$ ]] || usage
    previous "$arg"
    ;;
  *) usage ;;
esac
