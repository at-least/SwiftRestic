import XCTest

/// Backup ▸ Pause Backups offers For 1 Hour and Until Tomorrow; a pause
/// turns the item into Resume Backups, which gives the schedule back.
final class PauseBackupsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPauseForAnHourThenResume() throws {
        let folders = try UITestFolders.make("Pause")
        let app = UITest.launch(folders)
        UITest.backUpFirstFolder(folders, in: app)

        let backup = app.menuBars.menuBarItems["Backup"]
        backup.click()
        let pause = backup.menuItems["Pause Backups"]
        pause.hover()
        XCTAssertTrue(pause.menuItems["Until Tomorrow"].exists)
        XCTAssertFalse(pause.menuItems["Until I Resume"].exists)
        pause.menuItems["For 1 Hour"].click()

        backup.click()
        let resume = backup.menuItems["Resume Backups"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.click()

        backup.click()
        XCTAssertTrue(backup.menuItems["Pause Backups"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        attachScreenshot()
    }
}
