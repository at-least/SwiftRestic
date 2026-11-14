# SwiftRestic

Gate: `./build.sh test` (regenerates the Xcode project, lints, builds, runs
every test against the restic the app bundles). On a Mac without the author's
Apple Development certificate: `SWIFTRESTIC_ADHOC_SIGN=1 ./build.sh test`.
The restic version and checksums: `Tools/fetch-restic.sh`.
The index's SQLite floor: `Tools/sqlite-floor.sh`, by hand.

GUI runs, screenshots, pixel checks and the UI tests run on the Mac itself
and drive its desktop, so this project is developed on air, where nobody
else works (user 2026-11-14); orchard VMs are no longer used.
UI tests (scheme SwiftResticUITests, identifiers in `AccessibilityID.swift`):
`Tools/ui-test.sh` builds and runs them; `./build.sh test` leaves them out.
Debug builds photograph themselves through the
`SWIFTRESTIC_CAPTURE*` environment (`CaptureSupport.swift`), with
`SWIFTRESTIC_CONFIG_DIR` pointing at a throwaway configuration.
