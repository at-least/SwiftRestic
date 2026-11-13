#!/bin/bash
# Regenerate the Xcode project (xcodegen snapshots the file list, so new
# sources are invisible until it runs again) and build.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate --quiet

# Core, Models and the restic engine stay free of UI frameworks, so a port
# off macOS does not inherit AppKit. An import guard only: the runner still
# calls Darwin.read. NSString (expandTilde) is Foundation's and allowed.
portable=(
    Sources/SwiftRestic/Core
    Sources/SwiftRestic/Models
    Sources/SwiftRestic/Services/ResticService.swift
    Sources/SwiftRestic/Services/ResticClient.swift
    Sources/SwiftRestic/Services/Index
)
# A missing path makes grep exit 2, which `if grep` reads as clean, so a
# renamed path fails the build here instead.
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

# GRDB stays inside the snapshot index: every other layer reads it through
# SnapshotIndex's own types, so the database can be swapped without a sweep.
if grep -rnE "^import GRDB" Sources --include='*.swift' | grep -vE "^Sources/SwiftRestic/Services/Index/SnapshotIndex[^/]*\.swift:"; then
    echo "error: GRDB imported outside Services/Index/SnapshotIndex*.swift (see lines above)" >&2
    exit 1
fi

# The test target compiles the app's sources itself (project.yml) and has no
# SwiftRestic module. An import of it resolves against a module an earlier
# build left in DerivedData (only a warning, "missing a dependency on
# 'SwiftRestic'"), and a clean checkout then fails with "Unable to resolve
# module dependency: 'SwiftRestic'".
tests=Tests/SwiftResticTests
if [ ! -d "$tests" ]; then
    echo "error: test-import lint path is missing: $tests (update the path in build.sh)" >&2
    exit 1
fi
if grep -rnE "^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+SwiftRestic([[:space:]]|$)" "$tests"; then
    echo "error: a test file imports SwiftRestic (see lines above); the test target compiles the app's sources and has no such module" >&2
    exit 1
fi

# A Text with both .textSelection(.enabled) and .accessibilityLabel makes
# SwiftUI recurse until the stack overflows when any accessibility client
# reads it (seen on macOS 27.0.1). Put the label on the row around it. A
# modifier chain is the run of lines starting with "." around the
# .textSelection line.
if ! perl -e '
    my $bad = 0;
    for my $file (@ARGV) {
        open(my $fh, "<", $file) or die "$file: $!";
        my @lines = <$fh>;
        for my $i (0 .. $#lines) {
            next unless $lines[$i] =~ /\.textSelection\(\.enabled\)/;
            my ($lo, $hi) = ($i, $i);
            $lo-- while $lo > 0 && $lines[$lo] =~ /^\s*\./;
            $hi++ while $hi < $#lines && $lines[$hi + 1] =~ /^\s*\./;
            for my $j ($lo .. $hi) {
                next unless $lines[$j] =~ /\.accessibilityLabel\(/;
                print STDERR "$file:" . ($j + 1) . ": error: .accessibilityLabel on a selectable Text crashes accessibility clients\n";
                $bad = 1;
            }
        }
    }
    exit $bad;
' $(find Sources -name "*.swift"); then
    exit 1
fi

ACTION="${1:-build}"
source Tools/xcodebuild-common.sh
Tools/fetch-restic.sh >/dev/null

if [ "$ACTION" = "test" ]; then
    refuse_concurrent_test_session
fi

# The suites that drive the real restic: ~614 of the suite's ~740 seconds,
# measured 2026-11-14. `test` runs every other suite first and these only
# once the rest pass, so a unit failure answers in about two minutes. A
# suite left off this list still runs, in the first phase.
end_to_end_suites=(
    AppModelTests ResticIntegrationTests ResticFindTests ResticMaintenanceTests
    ResticCheckDamageTests ResticDiffTests ResticFilesTreeTests LocateRepositoryTests
    PreviewSessionTests IndexBackfillTests FirstBackupTests
)

# One xcodebuild run: the full log to a temporary file, the interesting
# lines to the terminal; the status is xcodebuild's own, not grep's.
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
run_xcodebuild() {
    local action="$1"
    shift
    local result=0
    xcodebuild "${xcodebuild_arguments[@]}" "$action" "$@" 2>&1 \
      | tee "$log" \
      | grep --line-buffered -E "error:|warning:|BUILD|TEST|Testing failed|failed|passed" \
      || result=${PIPESTATUS[0]}
    if [ "$action" != build ]; then
        # The filtered stream above does not show a restarted runner.
        if runner_restarted "$log"; then
            echo "error: the test runner restarted mid-run (a test crash or timeout, or a concurrent xcodebuild session) — inspect the newest xcresult before re-running" >&2
            result=1
        fi
        # xcodebuild exits 0 when a filter or a stale project file selects
        # zero tests; the swift-testing summary line is then absent. Checked
        # only after success, so a compile failure is not an empty run.
        if [ "$result" -eq 0 ] && ! grep -qE "Test run with [1-9][0-9]* tests" "$log"; then
            echo "error: test run reported success without executing any tests" >&2
            result=1
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

# The built app must carry the pinned restic under a seal that holds.
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
