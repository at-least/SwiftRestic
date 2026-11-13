import XCTest

/// SWIFTRESTIC_DELAY_STATS (Debug builds) holds back the size: the Size row
/// shows "—" until the hold ends. The first-run sheet's repository starts its
/// first refresh before the plan exists, so the hold delays only its size,
/// never the rows.
final class RefreshOrderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRowsLandBeforeTheSize() throws {
        let folders = try UITestFolders.make("RefreshOrder")
        let app = XCUIApplication()
        app.launchEnvironment["SWIFTRESTIC_CONFIG_DIR"] = folders.config.path
        app.launchEnvironment["SWIFTRESTIC_DISK"] = folders.disk.path
        // A hold long enough to outlast the walk to the repository page — the
        // run reached it at about a minute.
        app.launchEnvironment["SWIFTRESTIC_DELAY_STATS"] = "120"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        // The backup itself may still run; the refresh this test watches
        // started when the repository was created.
        UITest.createFirstBackup(folders, in: app)

        app.outlines["Sidebar"].staticTexts["SwiftRestic Backups"].click()
        let size = app.staticTexts[AccessibilityID.Repository.size]
        XCTAssertTrue(size.waitForExistence(timeout: 30))
        XCTAssertEqual(size.value as? String, "—", "the rows are in, the size has not arrived yet")
        XCTAssertTrue(size.waitForValue(otherThan: "—", timeout: 240), "the size arrives when the hold ends")
        attachScreenshot()
    }
}
