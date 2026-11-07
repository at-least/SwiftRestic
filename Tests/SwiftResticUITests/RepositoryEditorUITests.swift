import XCTest

/// File ▸ Add Backup Location… with a folder on this Mac: Add Backup Location
/// stays off, each reason in turn, then restic makes the repository and the
/// sidebar lists it.
final class RepositoryEditorUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAddLocalFolderLocation() throws {
        let folders = try UITestFolders.make("AddLocation")
        let location = folders.root.appendingPathComponent("Second Location")
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        let app = UITest.launch(folders)
        XCTAssertTrue(app.buttons[AccessibilityID.Welcome.backUpAFolder].waitForExistence(timeout: 30))

        let file = app.menuBars.menuBarItems["File"]
        file.click()
        file.menuItems["Add Backup Location…"].click()
        let add = app.buttons[AccessibilityID.RepositoryEditor.save]
        let requirement = app.staticTexts[AccessibilityID.RepositoryEditor.requirement]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertFalse(add.isEnabled)
        XCTAssertTrue(requirement.waitForValue("Choose a folder to save it."))

        app.buttons[AccessibilityID.RepositoryEditor.chooseFolder].click()
        UITest.choose(location, in: app)
        XCTAssertTrue(requirement.waitForValue("Set a password to save it."))

        let password = app.secureTextFields[AccessibilityID.RepositoryEditor.password]
        password.click()
        password.typeText("correct horse")
        let confirm = app.secureTextFields[AccessibilityID.RepositoryEditor.confirmPassword]
        confirm.click()
        confirm.typeText("correct hors")
        XCTAssertTrue(requirement.waitForValue("The passwords don’t match."))
        XCTAssertFalse(add.isEnabled)
        confirm.typeText("e")
        XCTAssertTrue(requirement.waitForNonExistence(timeout: 5))
        XCTAssertTrue(add.isEnabled)
        add.click()

        XCTAssertTrue(add.waitForNonExistence(timeout: 60))
        XCTAssertTrue(app.outlines["Sidebar"].staticTexts["Second Location"].waitForExistence(timeout: 10))
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.appendingPathComponent("config").path))
        attachScreenshot()
    }
}
