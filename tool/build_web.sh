#!/usr/bin/env bash
set -euo pipefail

revision="$(git rev-parse --short HEAD 2>/dev/null || printf unknown)"
build_id="${WIMSY_BUILD_ID:-${revision}-$(date -u +%Y%m%dT%H%M%SZ)}"

flutter build web --release --no-web-resources-cdn \
  --dart-define="WIMSY_BUILD_ID=${build_id}" "$@"

printf '{"build_id":"%s"}\n' "$build_id" > build/web/update.json
echo "Web build ID: $build_id"
