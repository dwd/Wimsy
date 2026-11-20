#!/usr/bin/env bash
# Works out the build version from git and prints it, optionally also
# stamping it into pubspec.yaml.
#
# Usage: tool/build_version.sh [--tag TAG] [--build-number N]
#                              [--write-pubspec] [--pubspec PATH]
#   --tag TAG          build a release from tag TAG (vX.Y.Z or X.Y.Z, with an
#                      optional -pre-release part such as -rc1). Empty or
#                      omitted means a pre-release build.
#   --build-number N   positive integer build number (default 1).
#   --write-pubspec    also rewrite the version and msix_version lines of
#                      the pubspec (see below). Without it, nothing is
#                      modified.
#   --pubspec PATH     pubspec to rewrite (default pubspec.yaml).
#
# Run from inside the git checkout. Nothing here is specific to a CI
# provider: CI maps its own tag and run number onto --tag and
# --build-number, and reads the printed values. Release tags are found in
# HEAD's history, so in a shallow or tagless clone run
# tool/fetch_release_history.sh first; a pre-release or -rc build fails
# rather than guessing if HEAD's history is cut off before any final
# release.
#
# Tags must be v followed by a semver 2.0.0 version (X.Y.Z without leading
# zeros, optional -pre-release and +build parts). Use dotted pre-release
# numbers (v1.0.0-rc.10, not -rc10) so that rc10 sorts after rc9.
#
# Versions:
#   release build:     display version from the tag (build metadata in the
#                      tag, e.g. v1.2.3+foo, is rejected)
#   pre-release build: <base> is the nearest release tag to HEAD, unless
#                      the highest final release in HEAD's history is at
#                      least as high (an older release merged back in, or an
#                      rc whose final release exists), in which case it is
#                      that final release; 0.0.0 if there are no tags. Build
#                      metadata on the base tag is dropped. The display
#                      version is then
#                        X.Y.(Z+1)-pre.<build number>.g<short sha>
#                      for a final <base> X.Y.Z, or
#                        <base>.pre.<build number>.g<short sha>
#                      for an unreleased pre-release <base> such as 2.0.0-rc.1.
#
# Ordering: under semver a pre-release sorts *before* its release, so a build
# made after v0.0.6 is labelled 0.0.7-pre..., which sorts after 0.0.6 and
# before 0.0.7; after v2.0.0-rc.1 it is 2.0.0-rc.1.pre..., which sorts after
# rc.1 and before rc.2 and 2.0.0. Within a version, the numeric build-number
# identifier orders pre-releases by build rather than by commit hash; the "g"
# prefix keeps an all-digit hash from becoming an invalid numeric identifier.
#
# Output (stdout, one KEY=VALUE per line; diagnostics go to stderr):
#   WIMSY_VERSION       display version, e.g. 0.0.6 or 0.0.7-pre.412.gd217e1d
#   WIMSY_DEB_VERSION   WIMSY_VERSION with its pre-release separator (the
#                       first -) as ~, so dpkg also sorts pre-releases before
#                       their release (0.0.7~pre.412.gd217e1d < 0.0.7). Use
#                       it for the package's Version field; ~ is best kept
#                       out of file names.
#   WIMSY_VERSION_CORE  numeric X.Y.Z only, e.g. 0.0.6 or 0.0.7. Pass this as
#                       --build-name on iOS/macOS: Flutter otherwise strips
#                       non-digits from the display version and produces
#                       nonsense such as 0.0.7412. Apple platforms only accept
#                       numeric versions, so a pre-release (or an -rc tag) has
#                       the same short version as the release it leads up to;
#                       the build number, which only increases, orders them.
#   WIMSY_BUILD_NUMBER  the build number. A CI run counter is shared by all
#                       branches, so it orders builds by when they ran, not by
#                       what they contain, and restarts if the counter does.
#   WIMSY_MSIX_VERSION  MSIX versions are four numbers with no pre-release
#                       part, so only final releases get their own X.Y.Z.0.
#                       Pre-release and -rc tag builds get
#                       <highest final release in HEAD's history>.<build>,
#                       which sorts after that release, before the next, and
#                       in build order in between. The build number must then
#                       fit the 16-bit field (at most 65535), or this fails.
#
# --write-pubspec sets:
#   version:       <WIMSY_VERSION>+<WIMSY_BUILD_NUMBER>
#   msix_version:  <WIMSY_MSIX_VERSION>
# so every tool that reads the pubspec (flutter build, msix:create,
# package_info_plus and hence Sentry) picks the version up without extra
# flags. Restore it afterwards with `git checkout pubspec.yaml`.
set -euo pipefail

# shellcheck source=tool/release_tags.sh
source "$(dirname "${BASH_SOURCE[0]}")/release_tags.sh"

usage() {
  sed -n '5,14p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

tag=""
build_number="1"
write_pubspec=false
pubspec="pubspec.yaml"
while (($# > 0)); do
  case "$1" in
    --tag) tag="${2-}"; shift 2 || usage ;;
    --build-number) build_number="${2-}"; shift 2 || usage ;;
    --write-pubspec) write_pubspec=true; shift ;;
    --pubspec) pubspec="${2-}"; shift 2 || usage ;;
    *) echo "error: unknown argument '$1'" >&2; usage ;;
  esac
done

if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: build number must be a positive integer, got '$build_number'" >&2
  exit 1
fi

# version_of TAG: TAG's version without the leading v and any +build
# metadata (which carries no meaning for ordering).
version_of() {
  local v="${1#v}"
  echo "${v%%+*}"
}

# core_le A B: true if the X.Y.Z core of version A is <= that of B.
core_le() {
  local -a a b
  local i
  IFS=. read -r -a a <<<"${1%%[-+]*}"
  IFS=. read -r -a b <<<"${2%%[-+]*}"
  for i in 0 1 2; do
    if ((a[i] < b[i])); then return 0; fi
    if ((a[i] > b[i])); then return 1; fi
  done
  return 0
}

# nearest_tag: the release tag (final or pre-release) nearest to HEAD, or
# nothing. describe's glob is only a first filter; the tag must also be a
# valid release tag.
nearest_tag() {
  local t
  t="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
  if [[ -n "$t" ]] && is_release_tag "$t"; then echo "$t"; fi
}

# last_final_tag: the highest final release tag in HEAD's history, or
# nothing.
last_final_tag() {
  local t core x y z
  git tag --merged HEAD --list 'v[0-9]*' | while read -r t; do
    if is_final_tag "$t"; then
      core="$(version_of "$t")"
      IFS=. read -r x y z <<<"$core"
      echo "$x $y $z $t"
    fi
  done | sort -k1,1n -k2,2n -k3,3n | tail -n 1 | cut -d' ' -f4
}

# require_history FINAL_TAG: fail unless a final release was found or HEAD's
# history is complete, so a missing tag means "none" rather than "not
# fetched".
require_history() {
  if [[ -z "$1" ]] && head_is_shallow; then
    echo "error: HEAD's history is shallow and contains no final release tag; run tool/fetch_release_history.sh first" >&2
    exit 1
  fi
}

# msix_prerelease FINAL_TAG: <final release X.Y.Z, or 0.0.0>.<build number>.
msix_prerelease() {
  if ((build_number > 65535)); then
    echo "error: build number $build_number exceeds the MSIX field limit of 65535" >&2
    exit 1
  fi
  echo "$(version_of "${1:-v0.0.0}").${build_number}"
}

if [[ -n "$tag" ]]; then
  [[ "$tag" == v* ]] || tag="v$tag"
  if ! is_release_tag "$tag"; then
    echo "error: tag '$tag' is not v followed by a semver version (X.Y.Z, no leading zeros, optional -pre-release)" >&2
    exit 1
  fi
  if [[ "$tag" == *+* ]]; then
    echo "error: tag '$tag' must not contain +build metadata; the build number is appended automatically" >&2
    exit 1
  fi
  version="${tag#v}"
  if is_final_tag "$tag"; then
    msix_version="${version}.0"
  else
    # An -rc tag: numbered like a pre-release on MSIX, so that its final
    # release is an upgrade from it.
    final_tag="$(last_final_tag)"
    require_history "$final_tag"
    msix_version="$(msix_prerelease "$final_tag")"
  fi
else
  final_tag="$(last_final_tag)"
  require_history "$final_tag"
  base_tag="$(nearest_tag)"
  base_version="$(version_of "${base_tag:-v0.0.0}")"
  if [[ -n "$final_tag" ]] && core_le "$base_version" "$(version_of "$final_tag")"; then
    base_version="$(version_of "$final_tag")"
  fi
  pre_suffix="pre.${build_number}.g$(git rev-parse --short HEAD)"
  if [[ "$base_version" == *-* ]]; then
    # An unreleased pre-release (e.g. 2.0.0-rc.1): extend it.
    version="${base_version}.${pre_suffix}"
  else
    # A final release: a pre-release of the next patch.
    IFS=. read -r major minor patch <<<"$base_version"
    version="${major}.${minor}.$((patch + 1))-${pre_suffix}"
  fi
  msix_version="$(msix_prerelease "$final_tag")"
fi
core="${version%%-*}"

if [[ "$write_pubspec" == "true" ]]; then
  if [[ ! -f "$pubspec" ]]; then
    echo "error: $pubspec not found" >&2
    exit 1
  fi
  # awk (rather than sed -i) behaves the same on Linux, macOS (BSD) and
  # Windows (Git Bash), with one exception: Git for Windows' awk drops the CR
  # of a CRLF line as it reads it, so it cannot tell a CRLF file (as Windows
  # checkouts usually are) from an LF one. So the line ending is detected from
  # the raw bytes with od, and awk strips any CR it does see and writes every
  # line with that ending. msix_version keeps its indentation. Each line must
  # be found exactly once, or the pubspec is left untouched.
  # Escape sequences, which awk -v expands (a literal newline in a -v value
  # is an error in some awks).
  eol='\n'
  if od -An -c "$pubspec" | grep -q '\\r'; then eol='\r\n'; fi
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  awk -v version="${version}+${build_number}" -v msix="$msix_version" -v eol="$eol" '
    BEGIN                        { ORS = eol }
                                 { sub(/\r$/, "") }
    /^version:/                  { print "version: " version; v++; next }
    /^[ \t]+msix_version:/       { match($0, /^[ \t]+/)
                                   print substr($0, 1, RLENGTH) "msix_version: " msix
                                   m++; next }
                                 { print }
    END { if (v != 1 || m != 1) { print "matched version:" v+0 " msix_version:" m+0 > "/dev/stderr"; exit 1 } }
  ' "$pubspec" >"$tmp" || {
    echo "error: expected exactly one top-level 'version:' and one indented 'msix_version:' line in $pubspec" >&2
    exit 1
  }
  cat "$tmp" >"$pubspec"
fi

# Held in a variable: a literal ~ in the replacement is treated differently
# across bash versions (tilde expansion or a kept backslash). Only the first
# -, the pre-release separator, is replaced; hyphens inside pre-release
# identifiers stay as they are.
tilde='~'
echo "WIMSY_VERSION=${version}"
echo "WIMSY_DEB_VERSION=${version/-/$tilde}"
echo "WIMSY_VERSION_CORE=${core}"
echo "WIMSY_BUILD_NUMBER=${build_number}"
echo "WIMSY_MSIX_VERSION=${msix_version}"
