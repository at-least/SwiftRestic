#!/bin/bash
# The snapshot index against the oldest SQLite the app runs on: its plan pins
# (SnapshotIndexPlanTests) and its randomized differential test
# (SnapshotIndexPropertyTests), run on SQLite 3.43.2 — what macOS 15, the
# deployment target, ships — instead of the build machine's own library. The
# index never ANALYZEs, so every query plan comes from the planner's defaults,
# and those change between releases; a plan that drifts on the floor turns a
# change-sized statement into a table scan without failing any answer. A manual
# step (or a CI job), not part of `./build.sh test`.
#
# How the library is swapped: the test bundle links /usr/lib/libsqlite3.dylib
# through GRDB, and dyld searches DYLD_LIBRARY_PATH for a library's leaf name
# before its install path, so a libsqlite3.dylib in that folder replaces the
# system one — for the test process alone: xcodebuild forwards TEST_RUNNER_*
# variables to the test runner with the prefix stripped and never sets them for
# itself. The plan suite prints `sqlite_version()` and fails when it differs
# from SWIFTRESTIC_EXPECT_SQLITE_VERSION, so a run in which the swap silently
# did not happen cannot pass as a floor run.
#
# The library is built once from the official amalgamation and reused:
#   https://www.sqlite.org/2023/sqlite-amalgamation-3430200.zip
#   zip SHA-256        a17ac8792f57266847d57651c5259001d1e4e4b46be96ec0d985c953925b2a1c
#   sqlite3.c SHA3-256 e17a3dc69330bd109256fb5a6e2b3ce8fbec48892a800389eb7c0f8856703161
# The SHA3-256 is the one sqlite.org publishes in the release log
# (https://sqlite.org/releaselog/3_43_2.html, with SQLITE_SOURCE_ID
# "2023-10-10 12:14:04 4310099cce5a…"); the zip's SHA-256 is that of the
# download whose sqlite3.c matched it, on 2026-09-28. Both are checked.
#
# It is the upstream 3.43.2, not Apple's build of it: a macOS 15 machine is the
# only full proof of the floor.
#
# Usage: Tools/sqlite-floor.sh [log file]
#   SWIFTRESTIC_SQLITE_FLOOR_LIB=<dir>  use <dir>/libsqlite3.dylib instead of
#                                       building one into .build/sqlite-3.43.2/lib
#   SWIFTRESTIC_INDEX_PROPERTY=40,30    the property test at the harness's scale
set -euo pipefail
cd "$(dirname "$0")/.."

version=3.43.2
zip_url=https://www.sqlite.org/2023/sqlite-amalgamation-3430200.zip
zip_sha256=a17ac8792f57266847d57651c5259001d1e4e4b46be96ec0d985c953925b2a1c
source_sha3=e17a3dc69330bd109256fb5a6e2b3ce8fbec48892a800389eb7c0f8856703161

# One xcodebuild test session at a time: two stomp each other's test runners
# (AGENTS.md, and build.sh's own guard).
if pgrep -x xcodebuild >/dev/null; then
    echo "error: another xcodebuild is already running; concurrent test sessions kill each other's runners" >&2
    exit 1
fi

lib_dir="${SWIFTRESTIC_SQLITE_FLOOR_LIB:-$PWD/.build/sqlite-$version/lib}"
if [ ! -f "$lib_dir/libsqlite3.dylib" ]; then
    if [ -n "${SWIFTRESTIC_SQLITE_FLOOR_LIB:-}" ]; then
        echo "error: no libsqlite3.dylib in $lib_dir" >&2
        exit 1
    fi
    work="$PWD/.build/sqlite-$version"
    mkdir -p "$work/lib"
    echo "building SQLite $version into $lib_dir"
    curl -fsSL -o "$work/amalgamation.zip" "$zip_url"
    echo "$zip_sha256  $work/amalgamation.zip" | shasum -a 256 -c -
    rm -rf "$work/src"
    unzip -q -o "$work/amalgamation.zip" -d "$work/src"
    source_file="$work/src/sqlite-amalgamation-3430200/sqlite3.c"
    actual_sha3="$(/usr/bin/python3 -c 'import hashlib, sys; print(hashlib.sha3_256(open(sys.argv[1], "rb").read()).hexdigest())' "$source_file")"
    if [ "$actual_sha3" != "$source_sha3" ]; then
        echo "error: sqlite3.c SHA3-256 is $actual_sha3, not the published $source_sha3" >&2
        exit 1
    fi
    # The system library's options that GRDB or the index rely on: FTS5 (the
    # search), SNAPSHOT (GRDB's WAL snapshots call sqlite3_snapshot_get), the
    # hooks and virtual tables GRDB can reach, and THREADSAFE=2 as Apple
    # builds it. The install name and compatibility version are the system
    # library's: dyld refuses a replacement whose compatibility version is
    # older than the 9.0.0 the test bundle records.
    xcrun clang -O2 -dynamiclib \
        -DSQLITE_THREADSAFE=2 \
        -DSQLITE_ENABLE_FTS5 \
        -DSQLITE_ENABLE_SNAPSHOT \
        -DSQLITE_ENABLE_DBSTAT_VTAB \
        -DSQLITE_ENABLE_COLUMN_METADATA \
        -DSQLITE_ENABLE_PREUPDATE_HOOK \
        -DSQLITE_ENABLE_SESSION \
        -install_name /usr/lib/libsqlite3.dylib \
        -compatibility_version 9.0.0 -current_version 9.6.0 \
        -o "$lib_dir/libsqlite3.dylib" "$source_file"
fi

xcodegen generate --quiet

log="${1:-$PWD/.build/sqlite-floor-$(date +%Y%m%d-%H%M%S).log}"
mkdir -p "$(dirname "$log")"
echo "SQLite library: $lib_dir/libsqlite3.dylib"
echo "full log: $log"

runner_env=(
    "TEST_RUNNER_DYLD_LIBRARY_PATH=$lib_dir"
    "TEST_RUNNER_SWIFTRESTIC_EXPECT_SQLITE_VERSION=$version"
)
if [ -n "${SWIFTRESTIC_INDEX_PROPERTY:-}" ]; then
    runner_env+=("TEST_RUNNER_SWIFTRESTIC_INDEX_PROPERTY=$SWIFTRESTIC_INDEX_PROPERTY")
fi

# The whole log goes to the file: never pipe xcodebuild through anything that
# can close early (AGENTS.md).
status=0
env "${runner_env[@]}" xcodebuild -project SwiftRestic.xcodeproj -scheme SwiftRestic -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" test \
    -only-testing:SwiftResticTests/SnapshotIndexPlanTests \
    -only-testing:SwiftResticTests/SnapshotIndexPropertyTests \
    >"$log" 2>&1 || status=$?

grep -E "sqlite_version|SnapshotIndexPropertyTests |Suite \".*\" (passed|failed)|✘|Test run with|error:" "$log" || true

if grep -q "Restarting after unexpected exit" "$log"; then
    echo "error: the test runner restarted mid-run — inspect the newest xcresult" >&2
    status=1
fi
if ! grep -q "sqlite_version()=$version" "$log"; then
    echo "error: the tests did not run on SQLite $version (see the sqlite_version line above)" >&2
    status=1
fi
for suite in "snapshot index plans" "snapshot index properties"; do
    if ! grep -q "Suite \"$suite\" passed" "$log"; then
        echo "error: suite \"$suite\" did not pass" >&2
        status=1
    fi
done
exit "$status"
