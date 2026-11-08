import XCTest

/// Backup ▸ Pause Backups ▸ Until I Resume holds the schedule, and Resume
/// Backups gives it back.
final class PauseBackupsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPauseUntilResumedThenResume() throws {
        let folders = try UITestFolders.make("Pause")
        let app = UITest.launch(folders)
        UITest.backUpFirstFolder(folders, in: app)
        let next = app.staticTexts[AccessibilityID.Plan.nextBackup]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        let scheduled = try XCTUnwrap(next.value as? String)
        XCTAssertNotEqual(scheduled, "Waiting")

        let backup = app.menuBars.menuBarItems["Backup"]
        backup.click()
        let pause = backup.menuItems["Pause Backups"]
        pause.hover()
        pause.menuItems["Until I Resume"].click()
        // An open-ended hold has no date to show.
        XCTAssertTrue(next.waitForValue("Waiting"))

        backup.click()
        backup.menuItems["Resume Backups"].click()
        XCTAssertTrue(next.waitForValue(scheduled))
        attachScreenshot()
    }
}
