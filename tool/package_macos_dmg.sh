#!/usr/bin/env bash
# Packages a built macOS app bundle into a compressed, drag-to-install DMG.
#
# Usage: tool/package_macos_dmg.sh [APP_PATH] [OUTPUT_DMG]
#   APP_PATH    defaults to build/macos/Build/Products/Release/wimsy.app
#   OUTPUT_DMG  defaults to wimsy-macos.dmg
#
# The DMG contains only the .app and an /Applications symlink, so users can
# drag the app across to install it. Build intermediates and dSYMs from the
# Xcode products directory are deliberately excluded.
#
# Signing is out of scope here: the app should already be signed before this
# runs, and a notarized release would sign/notarize/staple the resulting DMG
# afterwards.
set -euo pipefail

app_path="${1:-build/macos/Build/Products/Release/wimsy.app}"
output_dmg="${2:-wimsy-macos.dmg}"
volume_name="Wimsy"

if [[ ! -d "$app_path" ]]; then
  echo "error: app bundle not found at $app_path" >&2
  exit 1
fi

staging_dir="$(mktemp -d)"
trap 'rm -rf "$staging_dir"' EXIT

# ditto preserves framework symlinks, permissions, extended attributes and
# the code signature exactly.
ditto "$app_path" "$staging_dir/$(basename "$app_path")"
ln -s /Applications "$staging_dir/Applications"

rm -f "$output_dmg"
hdiutil create \
  -volname "$volume_name" \
  -srcfolder "$staging_dir" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$output_dmg"

hdiutil verify "$output_dmg"
echo "Created $output_dmg"
