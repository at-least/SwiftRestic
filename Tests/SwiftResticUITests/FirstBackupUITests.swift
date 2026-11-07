import XCTest

/// The first-run sheet end to end, with the restic the app bundles: a folder
/// and a destination chosen through the open panel, the Back Up button held
/// back until every answer is in, then a real repository and a first backup.
final class FirstBackupUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstBackup() throws {
        let folders = try UITestFolders.make("FirstBackup")
        let app = UITest.launch(folders)
        UITest.backUpFirstFolder(folders, in: app)
        attachScreenshot()
    }

    /// The Disk picker's Other… with the folder being backed up: its panel
    /// takes the keyboard (Go to Folder), and the sheet refuses the choice.
    @MainActor
    func testOtherFolderInsideTheSourceIsRefused() throws {
        let folders = try UITestFolders.make("OtherFolder")
        let app = UITest.launch(folders)
        app.buttons[AccessibilityID.Welcome.backUpAFolder].click()
        let backUp = app.buttons[AccessibilityID.FirstBackup.backUp]
        XCTAssertTrue(backUp.waitForExistence(timeout: 10))
        app.buttons[AccessibilityID.FirstBackup.chooseSource].click()
        UITest.choose(folders.source, in: app)

        let disk = app.popUpButtons[AccessibilityID.FirstBackup.disk]
        disk.click()
        app.menuItems["Other…"].click()
        UITest.choose(folders.source, in: app)
        XCTAssertTrue(disk.waitForValue(UITest.tilde(folders.source)))
        XCTAssertTrue(app.staticTexts[AccessibilityID.FirstBackup.requirement]
            .waitForValue("Keep the backups outside the folder you’re backing up."))
        XCTAssertFalse(backUp.isEnabled)
        attachScreenshot()
    }
}
