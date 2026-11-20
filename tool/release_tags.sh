# Definitions shared by tool/build_version.sh and
# tool/fetch_release_history.sh, so the two agree on what a release tag is
# and on when history is incomplete. Source this file; do not run it.
# shellcheck shell=bash

# A semver 2.0.0 version (https://semver.org), as an extended regex:
# X.Y.Z without leading zeros, an optional -pre-release and an optional
# +build part, each made of dot-separated [0-9A-Za-z-] identifiers (numeric
# pre-release identifiers without leading zeros).
semver_num='(0|[1-9][0-9]*)'
semver_pre_id="($semver_num|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
semver_build_id='[0-9A-Za-z-]+'
SEMVER_ERE="^$semver_num\\.$semver_num\\.$semver_num(-$semver_pre_id(\\.$semver_pre_id)*)?(\\+$semver_build_id(\\.$semver_build_id)*)?\$"
unset semver_num semver_pre_id semver_build_id

# is_release_tag TAG: TAG is v followed by a semver version.
is_release_tag() {
  [[ "$1" == v* && "${1#v}" =~ $SEMVER_ERE ]]
}

# is_final_tag TAG: TAG is a release tag without a -pre-release part (build
# metadata, which may itself contain hyphens, is allowed).
is_final_tag() {
  is_release_tag "$1" && [[ "${1%%+*}" != *-* ]]
}

# head_is_shallow: true while HEAD's history is cut off, i.e. some commit in
# it is a shallow boundary. Whether the repository as a whole is shallow is
# not the question: another ref's shallow tip (e.g. the branch originally
# cloned) keeps that true even once HEAD's history is complete.
head_is_shallow() {
  local shallow_file
  shallow_file="$(git rev-parse --git-path shallow)"
  [[ -s "$shallow_file" ]] && grep -qxF -f "$shallow_file" <(git rev-list HEAD)
}
