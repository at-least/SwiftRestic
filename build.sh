#!/bin/bash
# Regenerate the Xcode project (xcodegen snapshots the file list, so new
# sources are invisible until it runs again) and build.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate --quiet

ACTION="${1:-build}"
source Tools/xcodebuild-common.sh
Tools/fetch-restic.sh >/dev/null

if [ "$ACTION" = "test" ]; then
    refuse_concurrent_test_session
fi

# The suites that drive the real restic: ~614 of the suite's ~740 seconds.
# `test` runs every other suite first and these only
# once the rest pass, so a unit failure answers in about two minutes. A
# suite left off this list still runs, in the first phase.
end_to_end_suites=(
    AppModelTests ResticIntegrationTests ResticFindTests ResticMaintenanceTests
    ResticCheckDamageTests ResticDiffTests ResticFilesTreeTests LocateRepositoryTests
    PreviewSessionTests IndexBackfillTests FirstBackupTests
)

# One xcodebuild run: the full log to a temporary file, the interesting
# lines to the terminal; the status is xcodebuild's own, not grep's.
# Tests run in parallel, overriding the generated scheme's parallelizable NO;
# three parallel runs of each phase passed with no failure. Parallel output interleaves and cuts
# lines, so the counts come from the result bundle, not the log.
work="$(mktemp -d)"
log="$work/log"
trap 'rm -rf "$work"' EXIT
run_xcodebuild() {
    local action="$1"
    shift
    local result=0
    local bundle="$work/$action.xcresult"
    local test_arguments=()
    if [ "$action" != build ]; then
        test_arguments=(-parallel-testing-enabled YES -resultBundlePath "$bundle")
    fi
    xcodebuild "${xcodebuild_arguments[@]}" "$action" ${test_arguments[@]+"${test_arguments[@]}"} "$@" 2>&1 \
      | tee "$log" \
      | grep --line-buffered -E "error:|warning:|BUILD|TEST|Testing failed|failed" \
      || result=${PIPESTATUS[0]}
    if [ "$action" != build ]; then
        # The filtered stream above does not show a restarted runner.
        if runner_restarted "$log"; then
            echo "error: the test runner restarted mid-run (a test crash or timeout, or a concurrent xcodebuild session) — inspect the newest xcresult before re-running" >&2
            result=1
        fi
        # xcodebuild exits 0 when a filter or a stale project file selects
        # zero tests. Checked only after success, so a compile failure is
        # not reported as an empty run.
        if [ "$result" -eq 0 ]; then
            local counts
            counts="$(xcrun xcresulttool get test-results summary --path "$bundle" \
                | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["totalTestCount"], d["passedTests"], d["failedTests"], d["skippedTests"])')"
            read -r total passed failed skipped <<<"$counts"
            echo "Test run: $total tests, $passed passed, $failed failed, $skipped skipped"
            if [ "$total" -eq 0 ]; then
                echo "error: test run reported success without executing any tests" >&2
                result=1
            fi
        fi
    fi
    return "$result"
}

status=0
if [ "$ACTION" = "test" ]; then
    skip=() only=()
    for suite in "${end_to_end_suites[@]}"; do
        skip+=("-skip-testing:SwiftResticTests/$suite")
        only+=("-only-testing:SwiftResticTests/$suite")
    done
    echo "== unit tests (end-to-end suites wait for these)"
    run_xcodebuild test "${skip[@]}" || status=$?
    if [ "$status" -eq 0 ]; then
        echo "== end-to-end tests against the bundled restic"
        run_xcodebuild test-without-building "${only[@]}" || status=$?
    fi
else
    run_xcodebuild "$ACTION" || status=$?
fi

if [ "$status" -eq 0 ]; then
    app="$(xcodebuild "${xcodebuild_arguments[@]}" -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/^ *TARGET_BUILD_DIR = /{dir=$2} /^ *WRAPPER_NAME = /{name=$2} END{print dir"/"name}')"
    pinned_restic="$(Tools/fetch-restic.sh)"
    if ! codesign --verify --deep --strict "$app"; then
        echo "error: $app fails codesign --verify --deep --strict" >&2
        status=1
    elif [ "$("$app/Contents/Helpers/restic" version)" != "$("$pinned_restic" version)" ]; then
        echo "error: $app/Contents/Helpers/restic is not the pinned restic" >&2
        status=1
    else
        echo "bundled: $("$app/Contents/Helpers/restic" version)"
    fi
fi
exit "$status"
