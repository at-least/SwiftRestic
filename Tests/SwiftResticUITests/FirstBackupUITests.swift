import XCTest

/// The first-run sheet end to end, with the restic the app bundles: a folder
/// and a destination chosen through the open panel, the Back Up button held
/// back until every answer is in, then a real repository and a first backup.
final class FirstBackupUITests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FirstBackupUITests-\(UUID().uuidString)")
        for dir in ["config", "source", "backups"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try Data("hello\n".utf8).write(to: root.appendingPathComponent("source/hello.txt"))
    }

    @MainActor
    func testFirstBackup() throws {
        let app = XCUIApplication()
        app.launchEnvironment["SWIFTRESTIC_CONFIG_DIR"] = root.appendingPathComponent("config").path
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        let start = app.buttons[AccessibilityID.Welcome.backUpAFolder]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        start.click()

        let backUp = app.buttons[AccessibilityID.FirstBackup.backUp]
        let requirement = app.staticTexts[AccessibilityID.FirstBackup.requirement]
        XCTAssertTrue(backUp.waitForExistence(timeout: 10))
        XCTAssertFalse(backUp.isEnabled)
        XCTAssertEqual(requirement.value as? String, "Choose a folder to back up.")

        app.buttons[AccessibilityID.FirstBackup.chooseSource].click()
        choose(root.appendingPathComponent("source"), in: app)
        XCTAssertTrue(requirement.waitForValue("Choose where the backups go."))

        app.popUpButtons[AccessibilityID.FirstBackup.disk].click()
        app.menuItems["Other…"].click()
        choose(root.appendingPathComponent("backups"), in: app)
        XCTAssertTrue(requirement.waitForValue("Set a password to save it."))

        let password = app.secureTextFields[AccessibilityID.FirstBackup.password]
        password.click()
        password.typeText("correct horse")
        let confirm = app.secureTextFields[AccessibilityID.FirstBackup.confirmPassword]
        confirm.click()
        confirm.typeText("correct hors")
        XCTAssertTrue(requirement.waitForValue("The passwords don’t match."))
        XCTAssertFalse(backUp.isEnabled)

        confirm.typeText("e")
        XCTAssertTrue(requirement.waitForNonExistence(timeout: 5))
        XCTAssertTrue(backUp.isEnabled)
        backUp.click()
        XCTAssertTrue(backUp.waitForNonExistence(timeout: 120))

        // The plan page the sheet lands on counts the backup restic just made.
        XCTAssertTrue(app.staticTexts[AccessibilityID.Plan.total].waitForValue("1 backup", timeout: 120))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The open panel the app's FilePicker runs: Go to Folder with the path,
    /// then its Choose button.
    @MainActor
    private func choose(_ folder: URL, in app: XCUIApplication) {
        let choose = app.buttons["Choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(folder.path)
        app.typeKey(.return, modifierFlags: [])
        choose.click()
        XCTAssertTrue(choose.waitForNonExistence(timeout: 10))
    }
}

// A SwiftUI Text's string is its element's value on macOS; its label is empty.
@MainActor
private extension XCUIElement {
    func waitForValue(_ value: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }
}
