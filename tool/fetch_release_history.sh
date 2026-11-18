#!/usr/bin/env bash
# Fetches what tool/build_version.sh needs from git: the release tags in
# HEAD's history, and, in a shallow clone, only as much history as it takes
# to reach the last final release.
#
# Usage: tool/fetch_release_history.sh [REMOTE]
#   REMOTE defaults to origin.
#
# CI systems typically check out a shallow (often depth-1) clone without tags,
# so the last release cannot be found from HEAD. Fetching full history works
# but grows with the repository; this instead:
#   1. lists the remote's v* tags and the commits they point to
#      (git ls-remote: no history is downloaded);
#   2. if HEAD's history is cut off, deepens it in steps of
#      WIMSY_HISTORY_STEP commits (default 20) until it contains the commit of
#      a final release tag (vX.Y.Z, no -pre-release part), or HEAD's whole
#      history is present and no final release is in it;
#   3. fetches every release tag (final or pre-release) whose commit is in
#      HEAD's history, so tags are present even in a full clone made without
#      them.
#
# HEAD is deepened by commit id, so a detached HEAD (e.g. a pull request
# merge commit) works too. No tag is fetched unless its commit is already in
# HEAD's history, so tags elsewhere add no shallow boundaries of their own.
set -euo pipefail

# shellcheck source=tool/release_tags.sh
source "$(dirname "${BASH_SOURCE[0]}")/release_tags.sh"

remote="${1:-origin}"
step="${WIMSY_HISTORY_STEP:-20}"

if [[ ! "$step" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: WIMSY_HISTORY_STEP must be a positive integer, got '$step'" >&2
  exit 1
fi

# "<commit> <tag>" for every release tag on the remote. Annotated tags are
# listed twice by ls-remote, the second time peeled (name^{}) to the commit
# they point at; the peeled id is the one that appears in history.
tag_commits="$(git ls-remote --tags "$remote" 'refs/tags/v*' | awk '
  { ref = $2; sub(/^refs\/tags\//, "", ref)
    if (ref ~ /\^\{\}$/) { sub(/\^\{\}$/, "", ref); peeled[ref] = $1 }
    else                 { plain[ref] = $1 } }
  END { for (r in plain) print (r in peeled ? peeled[r] : plain[r]), r }' |
  while read -r commit tag; do
    if is_release_tag "$tag"; then echo "$commit $tag"; fi
  done)"
final_commits="$(while read -r commit tag; do
  if [[ -n "$tag" ]] && is_final_tag "$tag"; then echo "$commit"; fi
done <<<"$tag_commits")"

# tags_in_history: the tags of tag_commits whose commits are in HEAD's
# history as fetched so far, one per line (one pass over history).
tags_in_history() {
  awk 'NR == FNR { seen[$1]; next } ($1 in seen) { print $2 }' \
    <(git rev-list HEAD) <(printf '%s\n' "$tag_commits")
}
final_in_history() {
  [[ -n "$final_commits" ]] && grep -qxF -f <(printf '%s\n' "$final_commits") <(git rev-list HEAD)
}

head="$(git rev-parse HEAD)"
deepened=0
while head_is_shallow && ! final_in_history; do
  before="$(git rev-list --count HEAD)"
  git fetch --quiet --deepen="$step" "$remote" "$head"
  # No new commits is fine if the fetch only cleared the shallow marker on a
  # root commit (git can leave one there when the depth ends exactly at the
  # root); it is an error if HEAD's history is still cut off.
  if [[ "$(git rev-list --count HEAD)" == "$before" ]] && head_is_shallow; then
    echo "error: deepening HEAD fetched no new commits; giving up" >&2
    exit 1
  fi
  deepened=$((deepened + step))
done

# Their commits are already present, so this transfers only the tag refs
# (and annotated tag objects).
refspecs=()
while read -r tag; do
  if [[ -n "$tag" ]]; then refspecs+=("+refs/tags/$tag:refs/tags/$tag"); fi
done <<<"$(tags_in_history)"
if ((${#refspecs[@]} > 0)); then
  git fetch --quiet --no-tags "$remote" "${refspecs[@]}"
fi
echo "Deepened HEAD by $deepened commit(s); fetched ${#refspecs[@]} release tag(s) in its history." >&2
