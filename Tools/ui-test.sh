#!/bin/bash
# The UI tests (scheme SwiftResticUITests), built and run on this Mac. They
# drive its desktop (windows, pointer, keyboard), so this project is
# developed on air, where nobody else works (user 2026-11-14). Arguments go
# to xcodebuild test, e.g.
# -only-testing:SwiftResticUITests/FirstBackupUITests.
# The result bundle lands in .build/ui-test/ui.xcresult; the exit status is
# the test run's.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=.build/ui-test

xcodegen generate --quiet
Tools/fetch-restic.sh >/dev/null
Tools/fetch-rclone.sh >/dev/null
xcodebuild_scheme=SwiftResticUITests
# shellcheck source=Tools/xcodebuild-common.sh
source Tools/xcodebuild-common.sh
refuse_concurrent_test_session
rm -rf "$OUT/ui.xcresult"
status=0
xcodebuild "${xcodebuild_arguments[@]}" -derivedDataPath "$OUT/dd" -resultBundlePath "$OUT/ui.xcresult" test "$@" || status=$?
echo "result bundle: $OUT/ui.xcresult"
exit "$status"
