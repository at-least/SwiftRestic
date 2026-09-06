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

# xcodebuild reports success even when a filter or a stale project file selects
# zero tests — the swift-testing summary line is then absent entirely, and the
# exit status is still 0. A green test run must prove it executed something.
if [ "$ACTION" = "test" ] && ! grep -qE "Test run with [1-9][0-9]* tests" "$log"; then
    echo "error: test run reported success without executing any tests" >&2
    status=1
fi
exit "$status"
