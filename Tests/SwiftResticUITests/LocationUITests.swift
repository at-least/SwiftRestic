import XCTest

/// The Location menu on the plan's backup location: Verify Backups and
/// Remove Location….
final class LocationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The scheduled check, asked for by hand, of a fresh repository: it runs
    /// at once, with no question, and Activity records it with restic's
    /// verdict.
    @MainActor
    func testVerifyFindsNoErrors() throws {
        let folders = try UITestFolders.make("Verify")
        let app = UITest.launch(folders)
        UITest.backUpFirstFolder(folders, in: app)

        let location = app.menuBars.menuBarItems["Location"]
        location.click()
        location.menuItems["Verify Backups"].click()

        app.outlines["Sidebar"].staticTexts["Activity"].click()
        let table = app.outlines[AccessibilityID.Activity.table]
        let verification = table.outlineRows.containing(NSPredicate(format: "value == %@", "Verification")).firstMatch
        XCTAssertTrue(verification.waitForExistence(timeout: 120))
        let verdict = verification.staticTexts.matching(NSPredicate(format: "value == %@", "No errors found")).firstMatch
        XCTAssertTrue(verdict.waitForExistence(timeout: 120))
        attachScreenshot()
    }

    /// Removing the location takes its plan with it and leaves the backups on
    /// disk; the window is back to its first-run page.
    @MainActor
    func testRemoveLocationKeepsItsBackups() throws {
        let folders = try UITestFolders.make("RemoveLocation")
        let app = UITest.launch(folders)
        UITest.backUpFirstFolder(folders, in: app)
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.staticTexts["SwiftRestic Backups"].exists)

        let location = app.menuBars.menuBarItems["Location"]
        location.click()
        location.menuItems["Remove Location…"].click()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.click()

        XCTAssertTrue(sidebar.staticTexts["SwiftRestic Backups"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(sidebar.staticTexts["source"].exists)
        XCTAssertTrue(app.buttons[AccessibilityID.Welcome.backUpAFolder].waitForExistence(timeout: 10))
        let snapshots = try FileManager.default.contentsOfDirectory(atPath: folders.repository.appendingPathComponent("snapshots").path)
        XCTAssertEqual(snapshots.count, 1)
        attachScreenshot()
    }
}
