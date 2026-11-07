# shellcheck shell=bash
# What build.sh and Tools/sqlite-floor.sh share
# about running xcodebuild. Sourced from the repository root.

# Two xcodebuild test sessions on one machine stomp each other's testmanagerd
# sessions: the loser's runner gets SIGTERM'd mid-run ("Test crashed with
# signal term"), xcodebuild restarts it, the remaining tests pass, and the
# run is still marked failed. The suite costs about ten minutes; a
# collision wastes all of it, so refuse to start while another instance
# exists. Test runs only: a concurrent plain build does not touch the
# test-runner machinery. Limits worth knowing: the check runs at start only
# (a session launched mid-run is what `runner_restarted` catches), it cannot
# see test runs started from the Xcode IDE (no process named xcodebuild), and
# it refuses on any xcodebuild, including harmless builds of other projects.
refuse_concurrent_test_session() {
    if pgrep -x xcodebuild >/dev/null; then
        echo "error: another xcodebuild is already running; concurrent test sessions kill each other's runners" >&2
        pgrep -x xcodebuild | sed 's/^/  pid /' >&2
        echo "error: wait for it to finish (or kill it) and re-run" >&2
        exit 1
    fi
}

# platform=macOS with the native arch is explicit so destination resolution
# never walks the simulator fleet — the CoreSimulator churn the collisions
# above rode in on.
# Debug signs with the developer's Apple Development certificate
# (project.yml says why); a machine without it — CI — asks for an ad-hoc
# signature with SWIFTRESTIC_ADHOC_SIGN=1. Not a fallback on a missing
# certificate: locally that must still fail, or every rebuild quietly
# returns to asking the Keychain for the passwords.
xcodebuild_arguments=(
    -project SwiftRestic.xcodeproj -scheme "${xcodebuild_scheme:-SwiftRestic}" -configuration Debug
    -destination "platform=macOS,arch=$(uname -m)"
)
if [ "${SWIFTRESTIC_ADHOC_SIGN:-}" = "1" ]; then
    xcodebuild_arguments+=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi

# A restarted runner never announces itself in a filtered stream, and the
# run still ends with a plausible test summary — the killed tests "crashed",
# the rest passed. Only the full log tells the truth, so a caller that ran
# tests checks it and fails even on a green summary: a run that restarted
# mid-way is not a run whose green means green. The banner covers every
# restart cause — a test crash, a test timeout, or a colliding xcodebuild
# session.
runner_restarted() {
    grep -q "Restarting after unexpected exit" "$1"
}
