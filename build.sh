#!/bin/bash
# Regenerate the Xcode project (xcodegen snapshots the file list, so new
# sources are invisible until it runs again) and build.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate --quiet
ACTION="${1:-build}"

# The full log goes to a temporary file, the interesting lines stream to the
# terminal, and the script's exit status is xcodebuild's own: a failed build or
# test run must fail this script, or CI (and humans) will read silence as
# success.
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
status=0
xcodebuild -project SwiftRestic.xcodeproj -scheme SwiftRestic -configuration Debug "$ACTION" 2>&1 \
  | tee "$log" \
  | grep --line-buffered -E "error:|warning:|BUILD|TEST|Testing failed|failed|passed" \
  || status=${PIPESTATUS[0]}
exit "$status"
