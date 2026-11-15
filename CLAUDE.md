# SwiftRestic

Gate: `./build.sh test` (regenerates the Xcode project, builds, runs
every test against the restic the app bundles). Where codesign cannot use the
author's Apple Development certificate the gate is
`SWIFTRESTIC_ADHOC_SIGN=1 ./build.sh test`: on another Mac, and on air from a
session that is not on the desktop (a background agent session), where the
login keychain is unreachable and codesign fails with
`errSecInternalComponent` (seen 2026-11-15).
The restic version and checksums: `Tools/fetch-restic.sh`.
The index's SQLite floor: `Tools/sqlite-floor.sh`, by hand.

GUI runs, screenshots, pixel checks and the UI tests run on the Mac itself
and drive its desktop, so this project is developed on air, where nobody
else works (user 2026-11-14).
UI tests (scheme SwiftResticUITests, identifiers in `AccessibilityID.swift`):
`Tools/ui-test.sh` builds and runs them; `./build.sh test` leaves them out.
Debug builds photograph themselves through the
`SWIFTRESTIC_CAPTURE*` environment (`CaptureSupport.swift`), with
`SWIFTRESTIC_CONFIG_DIR` pointing at a throwaway configuration.
GUI runs need the development-signed build: an ad hoc build does not match
the TCC grants made to it (seen 2026-11-15), so its screen capture falls back
to cacheDisplay (the sidebar photographs white) and a UI test's restic is
refused the runner's container ("kTCCServiceSystemPolicyAppDataDetailed …
recording denied").
