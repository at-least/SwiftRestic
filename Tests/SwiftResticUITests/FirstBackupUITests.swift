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

    /// Back up to's Other Folder… with the folder being backed up: its panel
    /// takes the keyboard (Go to Folder), and the sheet refuses the choice.
    @MainActor
    func testOtherFolderInsideTheSourceIsRefused() throws {
        let folders = try UITestFolders.make("OtherFolder")
        let app = UITest.launch(folders)
        let start = app.buttons[AccessibilityID.Welcome.backUpAFolder]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        start.click()
        UITest.choose(folders.source, in: app)
        let backUp = app.buttons[AccessibilityID.FirstBackup.backUp]
        XCTAssertTrue(backUp.waitForExistence(timeout: 10))

        let disk = app.popUpButtons[AccessibilityID.FirstBackup.destination]
        disk.click()
        app.menuItems["Other Folder…"].click()
        UITest.choose(folders.source, in: app)
        XCTAssertTrue(disk.waitForValue(UITest.tilde(folders.source)))
        XCTAssertTrue(app.staticTexts[AccessibilityID.FirstBackup.requirement]
            .waitForValue("Keep the backups outside the folder you’re backing up."))
        XCTAssertFalse(backUp.isEnabled)
        attachScreenshot()
    }

    /// Back Up a Folder… asks for the folder before the sheet: a cancelled
    /// panel leaves Welcome as it was.
    @MainActor
    func testCancelledFolderPanelOpensNothing() throws {
        let folders = try UITestFolders.make("CancelledPanel")
        let app = UITest.launch(folders)
        let start = app.buttons[AccessibilityID.Welcome.backUpAFolder]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        start.click()
        let panel = app.dialogs["open-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        // An Esc sent as the panel appears is lost, as `UITest.choose`'s ⌘⇧G
        // is: send it until the panel goes.
        let deadline = Date().addingTimeInterval(20)
        repeat {
            panel.typeKey(.escape, modifierFlags: [])
        } while !panel.waitForNonExistence(timeout: 2) && Date() < deadline
        XCTAssertFalse(panel.exists)
        XCTAssertFalse(app.buttons[AccessibilityID.FirstBackup.backUp].waitForExistence(timeout: 3))
        XCTAssertTrue(start.isHittable)
    }
}
