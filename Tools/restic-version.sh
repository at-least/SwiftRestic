#!/bin/bash
# The suites that drive a real restic, run against one restic release
# downloaded from GitHub instead of the restic installed on this Mac. CI runs
# it for the oldest restic the app supports (ResticVersion.minimumSupported);
# `./build.sh test` keeps running the installed one.
#
# The binary reaches the tests through SWIFTRESTIC_TEST_RESTIC
# (ResticAvailability.binary), forwarded by xcodebuild's TEST_RUNNER_ prefix,
# which it strips for the test process and never sets for itself.
# ResticUnderTestTests fails when `restic version` differs from
# SWIFTRESTIC_EXPECT_RESTIC_VERSION, and this script fails unless that suite
# printed this download's path, so a run in which the variables silently did
# not reach the tests — and the installed restic ran — cannot pass as a run on
# that version.
#
# Usage: Tools/restic-version.sh <version> [log file]
#   <version>  one of the releases in `checksums` below, e.g. 0.19.1
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:?usage: Tools/restic-version.sh <version> [log file]}"

# SHA-256 of each release's restic_<version>_darwin_arm64.bz2, from that
# release's SHA256SUMS on GitHub. A version missing here is refused: an
# unchecked binary is not a test of that release.
case "$version" in
    0.16.5) sha256=c1439cff56678f08ca43ae32b4842fd43ada6b2c2798e647250e93bd32687c26 ;;
    0.17.3) sha256=18aac652463afe772700f568e52e6416b3940e366472c6c47fb1480dfb1c303c ;;
    0.18.1) sha256=193fccc8bb4567b498923bc70261e104ff22be88016f0f108b035dad372ab711 ;;
    0.19.0) sha256=1475397bf759ef4be16a77b19dec650bdbfec00d2cacd82005553411cdd37997 ;;
    0.19.1) sha256=7be0a144ccc377880f294204aa271d76e4b79554b42a751151d425ce6ebac143 ;;
    *)
        echo "error: no checksum for restic $version in Tools/restic-version.sh; add it from the release's SHA256SUMS" >&2
        exit 1
        ;;
esac

if [ "$(uname -m)" != "arm64" ]; then
    echo "error: the checksums are for darwin_arm64; this Mac is $(uname -m)" >&2
    exit 1
fi

source Tools/xcodebuild-common.sh
refuse_concurrent_test_session

work="$PWD/.build/restic-$version"
binary="$work/restic"
if [ ! -x "$binary" ]; then
    mkdir -p "$work"
    archive="$work/restic_${version}_darwin_arm64.bz2"
    curl -fsSL -o "$archive" "https://github.com/restic/restic/releases/download/v$version/restic_${version}_darwin_arm64.bz2"
    echo "$sha256  $archive" | shasum -a 256 -c -
    bunzip2 -c "$archive" > "$binary.partial"
    chmod +x "$binary.partial"
    mv "$binary.partial" "$binary"
fi

xcodegen generate --quiet

log="${2:-$PWD/.build/restic-$version-$(date +%Y%m%d-%H%M%S).log}"
mkdir -p "$(dirname "$log")"
echo "restic: $binary"
echo "full log: $log"

# Every suite that runs a real restic: the ones enabled by
# ResticAvailability.isInstalled.
suites=(
    ResticUnderTestTests
    ResticIntegrationTests
    ResticMaintenanceTests
    ResticCheckDamageTests
    ResticDiffTests
    ResticFindTests
    ResticFilesTreeTests
    IndexBackfillTests
    AppModelTests
)
only=()
for suite in "${suites[@]}"; do only+=("-only-testing:SwiftResticTests/$suite"); done

# The whole log goes to the file: never pipe xcodebuild through anything that
# can close early.
status=0
env "TEST_RUNNER_SWIFTRESTIC_TEST_RESTIC=$binary" "TEST_RUNNER_SWIFTRESTIC_EXPECT_RESTIC_VERSION=$version" \
    xcodebuild "${xcodebuild_arguments[@]}" test "${only[@]}" \
    >"$log" 2>&1 || status=$?

grep -E "restic under test:|Suite \".*\" (passed|failed)|✘|Test run with|error:" "$log" || true

if runner_restarted "$log"; then
    echo "error: the test runner restarted mid-run — inspect the newest xcresult" >&2
    status=1
fi
if ! grep -q "Suite \"restic under test\" passed" "$log" \
    || ! grep -qF "restic under test: $binary: restic $version " "$log"; then
    echo "error: the tests did not show they ran on restic $version (see the restic under test line above)" >&2
    status=1
fi
exit "$status"
