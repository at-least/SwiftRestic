#!/bin/bash
# Regenerate the Xcode project (xcodegen snapshots the file list, so new
# sources are invisible until it runs again) and build.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate --quiet

# The portability seam: Core, Models and the restic engine stay free of UI
# frameworks, so a future port does not inherit AppKit by accident. This is
# the import guard only — it does not claim the layer compiles off macOS
# today (the runner still calls Darwin.read). NSString (expandTilde) is
# Foundation's own and allowed.
portable=(
    Sources/SwiftRestic/Core
    Sources/SwiftRestic/Models
    Sources/SwiftRestic/Services/ResticService.swift
    Sources/SwiftRestic/Services/ResticClient.swift
    Sources/SwiftRestic/Services/Index
)
# Fail closed: a renamed or moved path makes grep exit 2, which an `if grep`
# alone would read as "clean" — the guard must not die with the paths it
# names, so missing paths fail the build too.
for linted in "${portable[@]}"; do
    if [ ! -e "$linted" ]; then
        echo "error: portability lint path is missing: $linted (update the list in build.sh)" >&2
        exit 1
    fi
done
if grep -rnE "import (AppKit|SwiftUI|Cocoa)" "${portable[@]}"; then
    echo "error: AppKit/SwiftUI imported in the portable layer (see lines above)" >&2
    exit 1
fi

ACTION="${1:-build}"

# Two xcodebuild test sessions on one machine stomp each other's testmanagerd
# sessions: the loser's runner gets SIGTERM'd mid-run ("Test crashed with
# signal term"), xcodebuild restarts it, the remaining tests pass, and the
# run is still marked failed — verified live 2026-09-14, with a foreign
# xcodebuild launching its own test runners seconds before each of our
# runner's three deaths. The suite costs four minutes; a collision wastes
# all of it, so refuse to start while another instance exists. Test actions
# only: a concurrent plain build does not touch the test-runner machinery.
# Limits worth knowing: the check runs at start only (a session launched
# mid-run is what the restart check below catches), it cannot see test runs
# started from the Xcode IDE (no process named xcodebuild), and it refuses
# on any xcodebuild, including harmless builds of other projects.
if [ "$ACTION" = "test" ] && pgrep -x xcodebuild >/dev/null; then
    echo "error: another xcodebuild is already running; concurrent test sessions kill each other's runners" >&2
    pgrep -x xcodebuild | sed 's/^/  pid /' >&2
    echo "error: wait for it to finish (or kill it) and re-run" >&2
    exit 1
fi

# The full log goes to a temporary file, the interesting lines stream to the
# terminal, and the script's exit status is xcodebuild's own: a failed build or
# test run must fail this script, or CI (and humans) will read silence as
# success.
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
# platform=macOS with the native arch is explicit so destination resolution
# never walks the simulator fleet — the CoreSimulator churn the collisions
# above rode in on.
status=0
xcodebuild -project SwiftRestic.xcodeproj -scheme SwiftRestic -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" "$ACTION" 2>&1 \
  | tee "$log" \
  | grep --line-buffered -E "error:|warning:|BUILD|TEST|Testing failed|failed|passed" \
  || status=${PIPESTATUS[0]}

# A restarted runner never announces itself in the grepped stream: the
# banner below matches none of the filter's terms, and the run still ends
# with a plausible test summary — the killed tests "crashed", the rest
# passed. Only the full log tells the truth, so check it whenever tests
# ran, and fail even on a green summary: a run that restarted mid-way is
# not a run whose green means green. The banner covers every restart cause
# — a test crash, a test timeout, or a colliding xcodebuild session — so
# the message points at the xcresult rather than naming a culprit.
if [ "$ACTION" = "test" ] && grep -q "Restarting after unexpected exit" "$log"; then
    echo "error: the test runner restarted mid-run (a test crash or timeout, or a concurrent xcodebuild session) — inspect the newest xcresult before re-running" >&2
    status=1
fi

# A successful exit is not enough: xcodebuild reports success even when a
# filter or a stale project file selects zero tests — the swift-testing
# summary line is then absent entirely. Only checked when xcodebuild itself
# succeeded, so a compile failure is not mislabelled as an empty run.
# SWIFTRESTIC_TEST_DISALLOW_SKIP (set in CI) goes one step further: the
# integration suites skip when restic is missing, and a job that silently
# skipped them would still be green, so their suite line must appear in the
# log. (An environment variable cannot do this check inside the tests:
# xcodebuild does not forward the shell environment to the test process.)
# Locally, without that variable, a missing suite only draws a warning — the
# skip still happens, but it is no longer silent. The grep string must stay
# in sync with the @Suite("restic integration") name in
# Tests/SwiftResticTests/ResticIntegrationTests.swift and with swift-testing's
# "Suite ... started" console line.
if [ "$status" -eq 0 ] && [ "$ACTION" = "test" ]; then
    if ! grep -qE "Test run with [1-9][0-9]* tests" "$log"; then
        echo "error: test run reported success without executing any tests" >&2
        status=1
    elif [ "${SWIFTRESTIC_TEST_DISALLOW_SKIP:-0}" = "1" ] && ! grep -q 'Suite "restic integration" started' "$log"; then
        echo "error: SWIFTRESTIC_TEST_DISALLOW_SKIP is set but the restic integration suite did not run — is restic installed?" >&2
        status=1
    elif [ "${CI:-false}" = "false" ] && ! grep -q 'Suite "restic integration" started' "$log"; then
        echo "warning: the restic integration suite did not run, so this result is missing real-restic coverage — is restic installed? (brew install restic)" >&2
    fi
fi
exit "$status"
