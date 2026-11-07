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

# GRDB stays inside the snapshot index: every other layer reads it through
# SnapshotIndex's own types, so the database can be swapped without a sweep.
if grep -rnE "^import GRDB" Sources --include='*.swift' | grep -vE "^Sources/SwiftRestic/Services/Index/SnapshotIndex[^/]*\.swift:"; then
    echo "error: GRDB imported outside Services/Index/SnapshotIndex*.swift (see lines above)" >&2
    exit 1
fi

# The test target compiles the app's sources itself (project.yml) and has no
# SwiftRestic module to import. Such an import resolves only against the
# app's module an earlier build left in DerivedData — xcodebuild warns that
# the tests are "missing a dependency on 'SwiftRestic'" and the build passes —
# while a clean checkout fails with "Unable to resolve module dependency:
# 'SwiftRestic'".
tests=Tests/SwiftResticTests
if [ ! -d "$tests" ]; then
    echo "error: test-import lint path is missing: $tests (update the path in build.sh)" >&2
    exit 1
fi
if grep -rnE "^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+SwiftRestic([[:space:]]|$)" "$tests"; then
    echo "error: a test file imports SwiftRestic (see lines above); the test target compiles the app's sources and has no such module" >&2
    exit 1
fi

# SwiftUI recurses without end when an accessibility client reads a Text
# that has both .textSelection(.enabled) and .accessibilityLabel: the app
# dies of a stack overflow the moment VoiceOver (or any AX client) reaches
# it — seen on macOS 27.0.1 with the Activity drawer's snapshot ID. A
# selectable text says its own words; put a label on the row around it
# instead. A modifier chain is the run of lines starting with "." around
# the .textSelection line.
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
Tools/fetch-rclone.sh >/dev/null

if [ "$ACTION" = "test" ]; then
    refuse_concurrent_test_session
fi

# The full log goes to a temporary file, the interesting lines stream to the
# terminal, and the script's exit status is xcodebuild's own: a failed build or
# test run must fail this script, or CI (and humans) will read silence as
# success.
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
status=0
xcodebuild "${xcodebuild_arguments[@]}" "$ACTION" 2>&1 \
  | tee "$log" \
  | grep --line-buffered -E "error:|warning:|BUILD|TEST|Testing failed|failed|passed" \
  || status=${PIPESTATUS[0]}

# The grepped stream above cannot show a restarted runner
# (`runner_restarted`).
if [ "$ACTION" = "test" ] && runner_restarted "$log"; then
    echo "error: the test runner restarted mid-run (a test crash or timeout, or a concurrent xcodebuild session) — inspect the newest xcresult before re-running" >&2
    status=1
fi

# A successful exit is not enough: xcodebuild reports success even when a
# filter or a stale project file selects zero tests: the swift-testing
# summary line is then absent entirely. Only checked when xcodebuild itself
# succeeded, so a compile failure is not mislabelled as an empty run.
if [ "$status" -eq 0 ] && [ "$ACTION" = "test" ]; then
    if ! grep -qE "Test run with [1-9][0-9]* tests" "$log"; then
        echo "error: test run reported success without executing any tests" >&2
        status=1
    fi
fi

# The app in the build folder must carry the pinned restic and rclone under
# a seal that holds: what the tests ran on is what ships.
if [ "$status" -eq 0 ]; then
    app="$(xcodebuild "${xcodebuild_arguments[@]}" -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/^ *TARGET_BUILD_DIR = /{dir=$2} /^ *WRAPPER_NAME = /{name=$2} END{print dir"/"name}')"
    pinned_restic="$(Tools/fetch-restic.sh)"
    pinned_rclone="$(Tools/fetch-rclone.sh)"
    if ! codesign --verify --deep --strict "$app"; then
        echo "error: $app fails codesign --verify --deep --strict" >&2
        status=1
    elif [ "$("$app/Contents/Helpers/restic" version)" != "$("$pinned_restic" version)" ]; then
        echo "error: $app/Contents/Helpers/restic is not the pinned restic" >&2
        status=1
    elif [ "$("$app/Contents/Helpers/rclone" version)" != "$("$pinned_rclone" version)" ]; then
        echo "error: $app/Contents/Helpers/rclone is not the pinned rclone" >&2
        status=1
    else
        echo "bundled: $("$app/Contents/Helpers/restic" version)"
        echo "bundled: $("$app/Contents/Helpers/rclone" version | head -1)"
    fi
fi
exit "$status"
