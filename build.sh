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

# A successful exit is not enough: xcodebuild reports success even when a
# filter or a stale project file selects zero tests — the swift-testing
# summary line is then absent entirely. Only checked when xcodebuild itself
# succeeded, so a compile failure is not mislabelled as an empty run.
# SWIFTRESTIC_TEST_DISALLOW_SKIP (set in CI) goes one step further: the
# integration suites skip when restic is missing, and a job that silently
# skipped them would still be green, so their suite line must appear in the
# log. (An environment variable cannot do this check inside the tests:
# xcodebuild does not forward the shell environment to the test process.)
# The grep string must stay in sync with the @Suite("restic integration")
# name in Tests/SwiftResticTests/ResticIntegrationTests.swift and with
# swift-testing's "Suite ... started" console line.
if [ "$status" -eq 0 ] && [ "$ACTION" = "test" ]; then
    if ! grep -qE "Test run with [1-9][0-9]* tests" "$log"; then
        echo "error: test run reported success without executing any tests" >&2
        status=1
    elif [ "${SWIFTRESTIC_TEST_DISALLOW_SKIP:-0}" = "1" ] && ! grep -q 'Suite "restic integration" started' "$log"; then
        echo "error: SWIFTRESTIC_TEST_DISALLOW_SKIP is set but the restic integration suite did not run — is restic installed?" >&2
        status=1
    fi
fi
exit "$status"
