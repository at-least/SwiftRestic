# SwiftRestic

Gate: `./build.sh test` (regenerates the Xcode project, lints, builds, runs
every test against the restic the app bundles). On a Mac without the author's
Apple Development certificate: `SWIFTRESTIC_ADHOC_SIGN=1 ./build.sh test`.
The restic and rclone versions and checksums: `Tools/fetch-restic.sh`,
`Tools/fetch-rclone.sh`.
The index's SQLite floor: `Tools/sqlite-floor.sh`, by hand.

GUI runs, screenshots and pixel checks happen in a single-use orchard VM
from the `tester` image (`orchard ssh vm`), never on the host desktop. Debug builds photograph themselves through the
`SWIFTRESTIC_CAPTURE*` environment (`CaptureSupport.swift`), with
`SWIFTRESTIC_CONFIG_DIR` pointing at a throwaway configuration.
