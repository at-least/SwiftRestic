#!/bin/bash
# The UI tests (scheme SwiftResticUITests): built here, run in a single-use
# orchard VM from cirruslabs' Xcode image, never on this desktop, which they
# would drive. Needs the orchard CLI's default context (the controller).
# Arguments go to xcodebuild test-without-building (-only-testing:SwiftResticUITests/FirstBackupUITests).
# The result bundle lands in .build/ui-test/ui.xcresult; the exit status is
# the test run's.
set -euo pipefail
cd "$(dirname "$0")/.."

# The image's Xcode matches the host's: the runner is built here.
IMAGE=ghcr.io/cirruslabs/macos-golden-gate-xcode:27.2
OUT=.build/ui-test

xcodegen generate --quiet
Tools/fetch-restic.sh >/dev/null
xcodebuild_scheme=SwiftResticUITests
# shellcheck source=Tools/xcodebuild-common.sh
source Tools/xcodebuild-common.sh
xcodebuild "${xcodebuild_arguments[@]}" -derivedDataPath "$OUT/dd" build-for-testing -quiet
xctestrun=$(cd "$OUT/dd/Build/Products" && ls ./*.xctestrun)

VM="swiftrestic-ui-$$"
# Not below the image's own 140 GB disk: the clone fails.
orchard create vm "$VM" --image "$IMAGE" --memory 8192 --cpu 4
trap 'orchard delete vm "$VM" >/dev/null' EXIT
vm() { orchard ssh vm "$VM" -u admin -p admin "$@"; }

# A worker's first pull of the image took 30 minutes; a clone after it, seconds.
deadline=$((SECONDS + 3600))
until status=$(orchard get vm "$VM" | awk '$1 == "Status" && $2 != "message" {print $2}'); [ "$status" = running ]; do
    if [ "$status" = failed ]; then
        orchard get vm "$VM" >&2
        exit 1
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo "error: $VM not running within an hour (status $status)" >&2
        exit 1
    fi
    sleep 5
done
deadline=$((SECONDS + 240))
until vm 'pgrep -x Finder >/dev/null' 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo "error: $VM did not finish logging in within 4 minutes" >&2
        exit 1
    fi
    sleep 3
done

tar -C "$OUT/dd/Build" -cf - Products | vm 'mkdir -p /tmp/ui && tar -C /tmp/ui -xf -'
# Not printf ' %q' "$@" alone: with no arguments it prints '', an empty build action.
options=""
if [ "$#" -gt 0 ]; then options=$(printf ' %q' "$@"); fi
status=0
vm "cd /tmp/ui && xcodebuild test-without-building -xctestrun Products/$xctestrun -destination 'platform=macOS,arch=$(uname -m)' -resultBundlePath ui.xcresult$options" || status=$?
rm -rf "$OUT/ui.xcresult"
vm 'cd /tmp/ui && tar -cf - ui.xcresult' | tar -C "$OUT" -xf -
echo "result bundle: $OUT/ui.xcresult"
exit "$status"
