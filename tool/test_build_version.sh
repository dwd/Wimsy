#!/usr/bin/env bash
# Tests for tool/build_version.sh and tool/fetch_release_history.sh. Runs
# against throwaway git repositories, so it needs no network access and never
# touches the real checkout.
#
# Usage: bash tool/test_build_version.sh
set -euo pipefail
# Byte-wise string comparison and sorting, whatever the developer's locale.
export LC_ALL=C

tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_version="$tool_dir/build_version.sh"
fetch_history="$tool_dir/fetch_release_history.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
check() { # check DESCRIPTION EXPECTED ACTUAL
  if [[ "$2" == "$3" ]]; then
    echo "ok:   $1"
  else
    echo "FAIL: $1"$'\n'"      expected: $2"$'\n'"      actual:   $3" >&2
    failures=$((failures + 1))
  fi
}

fixture_pubspec='name: wimsy
version: 0.0.2

dependencies:
  flutter:
    sdk: flutter

msix_config:
  display_name: Wimsy
  msix_version: 0.0.2.0
  sign_msix: false'

# new_repo DIR: a git repo with the fixture pubspec and one commit.
new_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email test@example.invalid
  git -C "$1" config user.name test
  git -C "$1" config commit.gpgsign false
  git -C "$1" config tag.gpgsign false
  printf '%s\n' "$fixture_pubspec" >"$1/pubspec.yaml"
  git -C "$1" add pubspec.yaml
  git -C "$1" commit -q -m initial
}
commit() { git -C "$1" commit -q --allow-empty -m "$2"; }
sha() { git -C "$1" rev-parse --short HEAD; }
line() { grep "^ *$2:" "$1/pubspec.yaml" | sed -E 's/^ *[a-z_]+: //'; }
# value OUTPUT KEY: the value of KEY in build_version.sh output.
value() { grep "^$2=" <<<"$1" | cut -d= -f2-; }

# bv DIR ARGS...: run build_version.sh in DIR.
bv() {
  local dir="$1"
  shift
  (cd "$dir" && bash "$build_version" "$@")
}

# shallow_clone ORIGIN DEST: a depth-1, tagless clone, as CI checks out.
shallow_clone() { git clone -q --depth 1 --no-tags "$(file_url "$1")" "$2"; }
# full_clone_no_tags ORIGIN DEST: full history, but no tags.
full_clone_no_tags() { git clone -q --no-tags "$(file_url "$1")" "$2"; }
file_url() {
  # Git for Windows needs a native path in the file:// URL.
  if command -v cygpath >/dev/null 2>&1; then
    echo "file:///$(cygpath -m "$1")"
  else
    echo "file://$1"
  fi
}

# --- No tags: pre-release from 0.0.0; nothing written by default ---
r="$work/notags"
new_repo "$r"
out="$(bv "$r" --build-number 7)"
check "no tags: output" "WIMSY_VERSION=0.0.0-pre-$(sha "$r")
WIMSY_VERSION_CORE=0.0.0
WIMSY_BUILD_NUMBER=7
WIMSY_MSIX_VERSION=0.0.0.7" "$out"
check "no tags: pubspec not written without --write-pubspec" "$fixture_pubspec" "$(cat "$r/pubspec.yaml")"
check "no tags: working tree clean" "" "$(git -C "$r" status --porcelain)"

# --- Pre-release after tags, written to pubspec ---
r="$work/pre"
new_repo "$r"
git -C "$r" tag v0.0.5
commit "$r" second
git -C "$r" tag v0.0.6
commit "$r" third
out="$(bv "$r" --tag "" --build-number 12 --write-pubspec)"
check "pre-release: version" "0.0.6-pre-$(sha "$r")" "$(value "$out" WIMSY_VERSION)"
check "pre-release: core" "0.0.6" "$(value "$out" WIMSY_VERSION_CORE)"
check "pre-release: msix" "0.0.6.12" "$(value "$out" WIMSY_MSIX_VERSION)"
check "pre-release: pubspec version" "0.0.6-pre-$(sha "$r")+12" "$(line "$r" version)"
check "pre-release: pubspec msix_version" "0.0.6.12" "$(line "$r" msix_version)"
check "pre-release: rest of pubspec untouched" \
  "$(printf '%s\n' "$fixture_pubspec" | grep -v 'version:')" \
  "$(grep -v 'version:' "$r/pubspec.yaml")"

# --- Release builds ---
r="$work/release"
new_repo "$r"
out="$(bv "$r" --tag v0.0.7 --build-number 13 --write-pubspec)"
check "release: version" "0.0.7" "$(value "$out" WIMSY_VERSION)"
check "release: core" "0.0.7" "$(value "$out" WIMSY_VERSION_CORE)"
check "release: msix" "0.0.7.0" "$(value "$out" WIMSY_MSIX_VERSION)"
check "release: pubspec version" "0.0.7+13" "$(line "$r" version)"
check "release: tag without v" "0.0.7" "$(value "$(bv "$r" --tag 0.0.7)" WIMSY_VERSION)"
check "release: build 70000 keeps a .0 MSIX field" "0.0.8.0" \
  "$(value "$(bv "$r" --tag v0.0.8 --build-number 70000)" WIMSY_MSIX_VERSION)"
git -C "$r" tag v1.2.2
out="$(bv "$r" --tag v1.2.3-rc1 --build-number 5)"
check "rc tag: version" "1.2.3-rc1" "$(value "$out" WIMSY_VERSION)"
check "rc tag: core" "1.2.3" "$(value "$out" WIMSY_VERSION_CORE)"
# Numbered after the last final release, so the final 1.2.3.0 upgrades it.
check "rc tag: msix based on last final release" "1.2.2.5" "$(value "$out" WIMSY_MSIX_VERSION)"
check "rc tag with build number over MSIX limit: fails" "1" \
  "$(bv "$r" --tag v1.2.3-rc1 --build-number 65536 >/dev/null 2>&1 && echo 0 || echo 1)"
check "default build number" "1" "$(value "$(bv "$r" --tag v0.0.7)" WIMSY_BUILD_NUMBER)"

# --- Pre-release after an -rc tag: MSIX is based on the last final release ---
r="$work/afterrc"
new_repo "$r"
git -C "$r" tag v1.0.0
commit "$r" second
git -C "$r" tag v1.1.0-rc1
commit "$r" third
out="$(bv "$r" --build-number 40)"
check "after rc tag: version" "1.1.0-rc1-pre-$(sha "$r")" "$(value "$out" WIMSY_VERSION)"
check "after rc tag: msix based on last final release" "1.0.0.40" "$(value "$out" WIMSY_MSIX_VERSION)"

# --- Base is the higher of the nearest tag and the highest final release ---
# An older release merged back in after a newer one, nearer to HEAD.
# git describe walks history by commit date, so the commits get increasing
# dates for it to find the nearer, older tag.
r="$work/mergeback"
new_repo "$r"
minute=0
dated_commit() {
  minute=$((minute + 1))
  GIT_COMMITTER_DATE="2030-01-01T00:$(printf %02d "$minute"):00Z" \
    GIT_AUTHOR_DATE="2030-01-01T00:$(printf %02d "$minute"):00Z" "$@"
}
main_branch="$(git -C "$r" symbolic-ref --short HEAD)"
dated_commit commit "$r" "main"
git -C "$r" tag v2.0.0
git -C "$r" checkout -q -b maint HEAD~1
for i in 1 2 3; do dated_commit commit "$r" "maint $i"; done
git -C "$r" tag v1.0.1
git -C "$r" checkout -q "$main_branch"
dated_commit git -C "$r" merge -q --no-ff -m "merge maint" maint
check "merge-back: git describe does pick the older tag" "v1.0.1" \
  "$(git -C "$r" describe --tags --abbrev=0 --match 'v[0-9]*')"
out="$(bv "$r" --build-number 6)"
check "merge-back: based on the higher release" "2.0.0-pre-$(sha "$r")" "$(value "$out" WIMSY_VERSION)"
check "merge-back: msix agrees" "2.0.0.6" "$(value "$out" WIMSY_MSIX_VERSION)"

# An rc superseded by its final release on the same commit. The rc tag is
# dated later, so git describe picks it over the final one.
r="$work/superseded"
new_repo "$r"
GIT_COMMITTER_DATE="2030-01-01T00:00:00Z" git -C "$r" tag -a v2.0.0 -m final
GIT_COMMITTER_DATE="2030-01-02T00:00:00Z" git -C "$r" tag -a v2.0.0-rc1 -m rc
commit "$r" second
check "superseded rc: git describe does pick the rc" "v2.0.0-rc1" \
  "$(git -C "$r" describe --tags --abbrev=0 --match 'v[0-9]*')"
check "superseded rc: based on the final release" "2.0.0-pre-$(sha "$r")" \
  "$(value "$(bv "$r" --build-number 3)" WIMSY_VERSION)"

# An rc with no final release at all is not superseded by the implicit 0.0.0.
r="$work/onlyrc"
new_repo "$r"
git -C "$r" tag v0.0.0-rc1
commit "$r" second
out="$(bv "$r" --build-number 2)"
check "only an rc tag: based on it" "0.0.0-rc1-pre-$(sha "$r")" "$(value "$out" WIMSY_VERSION)"
check "only an rc tag: msix" "0.0.0.2" "$(value "$out" WIMSY_MSIX_VERSION)"

# A v-prefixed tag that is not a release version is ignored.
r="$work/badtag"
new_repo "$r"
git -C "$r" tag v1.2
commit "$r" second
check "non-semver tag ignored" "0.0.0-pre-$(sha "$r")" "$(value "$(bv "$r")" WIMSY_VERSION)"

# --- Build metadata on the base tag is dropped ---
r="$work/basemeta"
new_repo "$r"
git -C "$r" tag v1.2.3+meta-x
commit "$r" second
out="$(bv "$r" --build-number 3)"
check "base tag +metadata: dropped" "1.2.3-pre-$(sha "$r")" "$(value "$out" WIMSY_VERSION)"
check "base tag +metadata: msix" "1.2.3.3" "$(value "$out" WIMSY_MSIX_VERSION)"

# --- pubspec formatting is preserved ---
r="$work/indent"
new_repo "$r"
sed 's/^  msix_version:/    msix_version:/' "$r/pubspec.yaml" >"$r/p" && mv "$r/p" "$r/pubspec.yaml"
bv "$r" --tag v0.0.9 --write-pubspec >/dev/null
check "4-space msix_version indent preserved" "    msix_version: 0.0.9.0" "$(grep msix_version "$r/pubspec.yaml")"

# CRLF (Windows checkouts). Checked as raw bytes: on Windows, text tools
# (awk, grep, sed, and $(...) itself) may translate CRLF as they read, which
# would hide the very thing being checked. The fixture and the expected
# result are written with bash's printf, and compared through od, which reads
# bytes as they are.
# as_crlf [VERSION_LINE MSIX_LINE]: the fixture pubspec with CRLF endings,
# optionally with its version and msix_version lines replaced.
as_crlf() {
  local l
  while IFS= read -r l; do
    case "$l" in
      "version: "*) l="${1:-$l}" ;;
      "  msix_version: "*) l="${2:-$l}" ;;
    esac
    printf '%s\r\n' "$l"
  done <<<"$fixture_pubspec"
}
hex() { od -An -tx1 -v | tr -d ' \n'; }
r="$work/crlf"
new_repo "$r"
as_crlf >"$r/pubspec.yaml"
bv "$r" --tag v0.1.0 --write-pubspec >/dev/null
check "CRLF: rewritten pubspec is exactly the expected CRLF bytes" \
  "$(as_crlf "version: 0.1.0+1" "  msix_version: 0.1.0.0" | hex)" \
  "$(hex <"$r/pubspec.yaml")"

r="$work/otherpath"
new_repo "$r"
cp "$r/pubspec.yaml" "$r/other.yaml"
bv "$r" --tag v0.2.0 --write-pubspec --pubspec other.yaml >/dev/null
check "--pubspec: named file written" "0.2.0+1" "$(grep '^version:' "$r/other.yaml" | cut -d' ' -f2)"
check "--pubspec: default file untouched" "0.0.2" "$(line "$r" version)"

# --- Shallow CI-style clones ---
# A depth-1, tagless clone of a repo with a few releases and some commits
# after the last one.
origin="$work/origin"
new_repo "$origin"
git -C "$origin" tag v0.0.4
for i in $(seq 1 30); do commit "$origin" "pre-0.0.5 $i"; done
git -C "$origin" tag v0.0.5
for i in $(seq 1 30); do commit "$origin" "pre-0.0.6 $i"; done
# Annotated, so ls-remote reports it with a separate peeled (^{}) line.
git -C "$origin" tag -a v0.0.6 -m "Release 0.0.6"
for i in $(seq 1 25); do commit "$origin" "after 0.0.6 $i"; done
total="$(git -C "$origin" rev-list --count HEAD)"

r="$work/shallow-unfetched"
shallow_clone "$origin" "$r"
check "shallow: clone starts shallow" "true" "$(git -C "$r" rev-parse --is-shallow-repository)"
status=0
err="$(bv "$r" --build-number 9 2>&1 >/dev/null)" || status=$?
check "shallow, history not fetched: fails instead of guessing 0.0.0" "1" "$status"
check "shallow, history not fetched: says what to do" "1" "$(grep -c fetch_release_history <<<"$err")"
status=0
bv "$r" --tag v0.0.6 >/dev/null || status=$?
check "shallow, release build: needs no history" "0" "$status"

r="$work/shallow"
shallow_clone "$origin" "$r"
(cd "$r" && WIMSY_HISTORY_STEP=10 bash "$fetch_history" 2>/dev/null)
out="$(bv "$r" --build-number 9)"
check "fetched: last tag found" "0.0.6-pre-$(sha "$r")" "$(value "$out" WIMSY_VERSION)"
fetched="$(git -C "$r" rev-list --count HEAD)"
check "fetched: only history back to the last tag (fetched $fetched of $total)" "yes" \
  "$( ((fetched <= 26 + 10 && fetched < total)) && echo yes || echo no)"
check "fetched: still shallow" "true" "$(git -C "$r" rev-parse --is-shallow-repository)"

r="$work/shallow-detached"
shallow_clone "$origin" "$r"
git -C "$r" checkout -q --detach
(cd "$r" && bash "$fetch_history" 2>/dev/null)
check "fetched, detached HEAD (PR merge commit): last tag found" "0.0.6-pre-$(sha "$r")" \
  "$(value "$(bv "$r")" WIMSY_VERSION)"

notags_origin="$work/notags-origin"
new_repo "$notags_origin"
for i in $(seq 1 5); do commit "$notags_origin" "c$i"; done
r="$work/shallow-notags"
shallow_clone "$notags_origin" "$r"
status=0
(cd "$r" && WIMSY_HISTORY_STEP=2 bash "$fetch_history" 2>/dev/null) || status=$?
check "no tags anywhere: fetch succeeds" "0" "$status"
check "no tags anywhere: fetches everything" "false" "$(git -C "$r" rev-parse --is-shallow-repository)"
check "no tags anywhere: 0.0.0 pre-release" "0.0.0-pre-$(sha "$r")" "$(value "$(bv "$r")" WIMSY_VERSION)"

# A branch whose history holds no tag, on a remote that has tags elsewhere
# (e.g. an orphan branch). This must terminate with HEAD's full history, and
# must not fetch the unrelated tags.
origin_branch="$(git -C "$origin" symbolic-ref --short HEAD)"
git -C "$origin" checkout -q --orphan unrelated
git -C "$origin" commit -q --allow-empty -m "orphan root"
for i in $(seq 1 4); do commit "$origin" "orphan $i"; done
git -C "$origin" checkout -q "$origin_branch"
r="$work/shallow-orphan"
shallow_clone "$origin" "$r"
git -C "$r" fetch -q --depth 1 origin unrelated
git -C "$r" checkout -q FETCH_HEAD
status=0
(cd "$r" && WIMSY_HISTORY_STEP=2 bash "$fetch_history" 2>/dev/null) || status=$?
check "unrelated tags: fetch terminates successfully" "0" "$status"
check "unrelated tags: HEAD history complete (root + 4)" "5" "$(git -C "$r" rev-list --count HEAD)"
check "unrelated tags: no tags fetched" "" "$(git -C "$r" tag)"
check "unrelated tags: 0.0.0 pre-release" "0.0.0-pre-$(sha "$r")" "$(value "$(bv "$r")" WIMSY_VERSION)"

r="$work/full-notags"
full_clone_no_tags "$origin" "$r"
check "full clone without tags: starts with no tags" "" "$(git -C "$r" tag)"
(cd "$r" && bash "$fetch_history" 2>/dev/null)
check "full clone without tags: release tags fetched" "v0.0.4 v0.0.5 v0.0.6" "$(git -C "$r" tag | tr '\n' ' ' | sed 's/ $//')"
check "full clone without tags: version" "0.0.6-pre-$(sha "$r")" "$(value "$(bv "$r")" WIMSY_VERSION)"

# --- Failures leave the pubspec untouched ---
expect_failure() { # expect_failure DESCRIPTION DIR ARGS...
  local desc="$1" dir="$2"
  shift 2
  local before status=0
  before="$(cat "$dir/pubspec.yaml")"
  bv "$dir" "$@" >/dev/null 2>&1 || status=$?
  check "$desc: exits non-zero" "nonzero" "$([[ $status -ne 0 ]] && echo nonzero || echo zero)"
  check "$desc: pubspec unchanged" "$before" "$(cat "$dir/pubspec.yaml")"
}

r="$work/fail"
new_repo "$r"
expect_failure "build number 0" "$r" --build-number 0 --write-pubspec
expect_failure "non-numeric build number" "$r" --build-number abc --write-pubspec
expect_failure "non-numeric tag" "$r" --tag vnext --write-pubspec
expect_failure "tag with leading zeros" "$r" --tag v1.08.3 --write-pubspec
expect_failure "tag with empty pre-release" "$r" --tag v1.2.3- --write-pubspec
expect_failure "tag with a space" "$r" --tag "v1.2.3-rc 1" --write-pubspec
expect_failure "tag with +build metadata" "$r" --tag v1.2.3+hotfix --write-pubspec
expect_failure "pre-release build number over MSIX limit" "$r" --build-number 65536 --write-pubspec
expect_failure "unknown argument" "$r" --frobnicate
expect_failure "missing option value" "$r" --tag
grep -v msix_version "$r/pubspec.yaml" >"$r/p" && mv "$r/p" "$r/pubspec.yaml"
expect_failure "missing msix_version line" "$r" --write-pubspec

if ((failures > 0)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "All checks passed"
