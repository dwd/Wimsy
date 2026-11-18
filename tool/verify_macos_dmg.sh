#!/usr/bin/env bash
# Verifies a macOS release DMG produced by tool/package_macos_dmg.sh.
#
# Usage: tool/verify_macos_dmg.sh DMG_PATH [EXPECTED_VERSION]
#   DMG_PATH          the DMG to check
#   EXPECTED_VERSION  optional; if given, wimsy.app's CFBundleShortVersionString
#                     must equal it exactly
#
# Checks (all must pass; every failure is reported before exiting non-zero):
#   - the image passes hdiutil verify and mounts read-only
#   - the volume contains exactly wimsy.app and an Applications -> /Applications
#     symlink (hidden volume metadata such as .fseventsd is ignored)
#   - wimsy.app passes codesign --verify --deep --strict
#   - the main executable is universal (x86_64 and arm64)
#   - the bundle version matches EXPECTED_VERSION, when given
#
# These checks hold for both the current ad-hoc signed build and a future
# Developer ID signed and notarized build. Checks specific to Developer ID
# signing and notarization (signing authority, hardened runtime, spctl,
# stapler) belong with the change that introduces that signing.
set -euo pipefail

dmg_path="${1:?usage: $0 DMG_PATH [EXPECTED_VERSION]}"
expected_version="${2:-}"
app_name="wimsy.app"

failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}
pass() {
  echo "ok:   $*"
}

if [[ ! -f "$dmg_path" ]]; then
  echo "error: DMG not found at $dmg_path" >&2
  exit 1
fi

if hdiutil verify -quiet "$dmg_path"; then
  pass "hdiutil verify"
else
  fail "hdiutil verify"
fi

# Mount at a private mount point so a volume already mounted under
# /Volumes/Wimsy (e.g. on a developer machine) cannot interfere.
mount_point="$(mktemp -d)"
cleanup() {
  hdiutil detach -quiet "$mount_point" 2>/dev/null || true
  rmdir "$mount_point" 2>/dev/null || true
}
trap cleanup EXIT
if ! hdiutil attach -quiet -readonly -nobrowse -noautoopen \
  -mountpoint "$mount_point" "$dmg_path"; then
  fail "could not mount $dmg_path; remaining checks skipped"
  echo "$failures check(s) failed" >&2
  exit 1
fi

# Top-level contents, ignoring hidden volume metadata.
contents="$(cd "$mount_point" && find . -mindepth 1 -maxdepth 1 ! -name '.*' | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ')"
if [[ "$contents" == "Applications $app_name " ]]; then
  pass "volume contains only $app_name and Applications"
else
  fail "unexpected volume contents: $contents"
fi

if [[ -L "$mount_point/Applications" && "$(readlink "$mount_point/Applications")" == "/Applications" ]]; then
  pass "Applications is a symlink to /Applications"
else
  fail "Applications is not a symlink to /Applications"
fi

app="$mount_point/$app_name"
if [[ ! -d "$app" ]]; then
  fail "$app_name missing; skipping app checks"
else
  if codesign --verify --deep --strict "$app"; then
    pass "codesign --verify --deep --strict"
  else
    fail "codesign --verify --deep --strict"
  fi

  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
  archs="$(lipo -archs "$app/Contents/MacOS/$executable")"
  if [[ " $archs " == *" x86_64 "* && " $archs " == *" arm64 "* ]]; then
    pass "universal executable ($archs)"
  else
    fail "executable is not universal: $archs"
  fi

  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
  if [[ -z "$expected_version" ]]; then
    echo "skip: version check (no expected version given; bundle has $version)"
  elif [[ "$version" == "$expected_version" ]]; then
    pass "bundle version $version"
  else
    fail "bundle version $version, expected $expected_version"
  fi
fi

if ((failures > 0)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "All checks passed"
