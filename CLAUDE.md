# SwiftRestic

Gate: `./build.sh test` (regenerates the Xcode project, lints, builds, runs
every test against the installed restic). On a Mac without the author's
Apple Development certificate: `SWIFTRESTIC_ADHOC_SIGN=1 ./build.sh test`.
Real-restic suites on one restic release: `Tools/restic-version.sh 0.19.1`.
The index's SQLite floor: `Tools/sqlite-floor.sh`, by hand.

GUI runs, screenshots and pixel checks happen in a tester VM, never on the
host desktop. Debug builds photograph themselves through the
`SWIFTRESTIC_CAPTURE*` environment (`CaptureSupport.swift`), with
`SWIFTRESTIC_CONFIG_DIR` pointing at a throwaway configuration.
