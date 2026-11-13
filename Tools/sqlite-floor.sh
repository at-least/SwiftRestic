#!/bin/bash
# SnapshotIndexPlanTests and SnapshotIndexPropertyTests on SQLite 3.43.2, what
# macOS 15 (the deployment target) ships, instead of the build machine's
# library. The index never ANALYZEs, so its query plans are the planner's
# defaults, which change between releases; a drifted plan turns a statement
# into a table scan without failing any answer. Run by hand, not by
# `./build.sh test`.
#
# The swap: GRDB links /usr/lib/libsqlite3.dylib, and dyld looks for the leaf
# name in DYLD_LIBRARY_PATH first. xcodebuild passes TEST_RUNNER_* variables to
# the test runner alone, prefix stripped. The plan suite fails when
# sqlite_version() differs from SWIFTRESTIC_EXPECT_SQLITE_VERSION, so a run
# where the swap did not happen cannot pass.
#
# The SHA3-256 below is the one sqlite.org publishes in
# https://sqlite.org/releaselog/3_43_2.html; the zip's SHA-256 is that of the
# download whose sqlite3.c matched it.
#
# This is upstream 3.43.2, not Apple's build of it: only a macOS 15 machine
# fully proves the floor.
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

source Tools/xcodebuild-common.sh
refuse_concurrent_test_session

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
    # The system library's options that GRDB or the index rely on (SNAPSHOT:
    # GRDB's WAL snapshots call sqlite3_snapshot_get), THREADSAFE=2 as Apple
    # builds it. dyld refuses a replacement whose compatibility version is
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

# The whole log goes to the file: a pipe reader that exits early kills
# xcodebuild with SIGPIPE.
status=0
env "${runner_env[@]}" xcodebuild "${xcodebuild_arguments[@]}" test \
    -only-testing:SwiftResticTests/SnapshotIndexPlanTests \
    -only-testing:SwiftResticTests/SnapshotIndexPropertyTests \
    >"$log" 2>&1 || status=$?

grep -E "sqlite_version|SnapshotIndexPropertyTests |Suite \".*\" (passed|failed)|✘|Test run with|error:" "$log" || true

if runner_restarted "$log"; then
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
