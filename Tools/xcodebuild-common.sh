# shellcheck shell=bash
# Sourced from the repository root by build.sh, Tools/sqlite-floor.sh and
# Tools/ui-test.sh.

# Two xcodebuild test sessions on one machine kill each other's runners
# ("Test crashed with signal term") and the run is marked failed. Checked at
# start only (`runner_restarted` catches a later collision); it does not see
# Xcode IDE test runs, and it refuses on any xcodebuild, even another
# project's build.
refuse_concurrent_test_session() {
    if pgrep -x xcodebuild >/dev/null; then
        echo "error: another xcodebuild is already running; concurrent test sessions kill each other's runners" >&2
        pgrep -x xcodebuild | sed 's/^/  pid /' >&2
        echo "error: wait for it to finish (or kill it) and re-run" >&2
        exit 1
    fi
}

# An explicit native-arch destination keeps resolution off the simulators.
# Debug signs with the Apple Development certificate (project.yml says why).
# SWIFTRESTIC_ADHOC_SIGN=1 is opt-in, not a fallback on a missing
# certificate: a silent ad-hoc build would ask the Keychain for every
# password again after each rebuild.
xcodebuild_arguments=(
    -project SwiftRestic.xcodeproj -scheme "${xcodebuild_scheme:-SwiftRestic}" -configuration Debug
    -destination "platform=macOS,arch=$(uname -m)"
)
if [ "${SWIFTRESTIC_ADHOC_SIGN:-}" = "1" ]; then
    xcodebuild_arguments+=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi

# A run whose runner restarted (test crash, timeout or colliding session)
# still ends with a plausible summary; only this banner in the full log
# shows it, so callers fail on it.
runner_restarted() {
    grep -q "Restarting after unexpected exit" "$1"
}
