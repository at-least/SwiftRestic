import XCTest

/// A file's versions on the Files tab: the one before the latest change
/// restored, its old bytes back — into a chosen folder, and in place.
final class FileVersionsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRestoreAnEarlierVersion() throws {
        let folders = try UITestFolders.make("FileVersions")
        let first = try Data(contentsOf: folders.sourceFile)
        let restored = folders.root.appendingPathComponent("restored")
        try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: true)
        let app = UITest.launch(folders)
        UITest.backUpFirstFolder(folders, in: app)
        try Data("hello again\n".utf8).write(to: folders.sourceFile)
        app.buttons[AccessibilityID.Plan.backUpNow].click()
        XCTAssertTrue(app.staticTexts[AccessibilityID.Plan.total].waitForValue(beginningWith: "2 backups · since ", timeout: 120))

        app.radioButtons["Files"].click()
        XCTAssertTrue(app.buttons[AccessibilityID.FilesPane.restore].waitForEnabled())
        app.outlines.staticTexts["hello.txt"].firstMatch.click()
        // Newest first: the second row is the version before the change.
        let versions = app.outlines[AccessibilityID.FileVersions.list].outlineRows
        let two = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: versions)
        XCTAssertEqual(XCTWaiter().wait(for: [two], timeout: 30), .completed)
        // At the row's middle, then read back: XCUITest's hit test of a SwiftUI
        // list row lands on its cell and calls the row not hittable.
        let older = versions.element(boundBy: 1)
        older.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(older.waitForSelected())
        let restoreButton = app.buttons[AccessibilityID.FileVersions.restore]
        XCTAssertTrue(restoreButton.waitForEnabled())
        UITest.restoreToButton(AccessibilityID.FileVersions.restoreTo, in: app).click()

        UITest.restoreInSheet(into: restored, in: app)
        let file = try XCTUnwrap(UITest.waitForFile(named: "hello.txt", under: restored))
        XCTAssertTrue(restoreButton.waitForEnabled(timeout: 120))
        XCTAssertEqual(try Data(contentsOf: file), first)
        attachScreenshot()
    }

    /// Restore puts the older version back over the file, with no sheet:
    /// the file is in the way, so the Replace question comes first.
    @MainActor
    func testRestoreAnEarlierVersionInPlace() throws {
        let folders = try UITestFolders.make("FileVersionsInPlace")
        let first = try Data(contentsOf: folders.sourceFile)
        let app = UITest.launch(folders)
        UITest.backUpFirstFolder(folders, in: app)
        try Data("hello again\n".utf8).write(to: folders.sourceFile)
        app.buttons[AccessibilityID.Plan.backUpNow].click()
        XCTAssertTrue(app.staticTexts[AccessibilityID.Plan.total].waitForValue(beginningWith: "2 backups · since ", timeout: 120))

        app.radioButtons["Files"].click()
        XCTAssertTrue(app.buttons[AccessibilityID.FilesPane.restore].waitForEnabled())
        app.outlines.staticTexts["hello.txt"].firstMatch.click()
        let versions = app.outlines[AccessibilityID.FileVersions.list].outlineRows
        let two = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: versions)
        XCTAssertEqual(XCTWaiter().wait(for: [two], timeout: 30), .completed)
        let older = versions.element(boundBy: 1)
        older.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(older.waitForSelected())
        let restoreButton = app.buttons[AccessibilityID.FileVersions.restore]
        XCTAssertTrue(restoreButton.waitForEnabled())
        restoreButton.click()

        let replace = app.buttons["Replace"]
        XCTAssertTrue(replace.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[AccessibilityID.RestoreSheet.chooseFolder].exists)
        replace.click()
        XCTAssertTrue(restoreButton.waitForEnabled(timeout: 120))
        let deadline = Date().addingTimeInterval(30)
        while try Data(contentsOf: folders.sourceFile) != first, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertEqual(try Data(contentsOf: folders.sourceFile), first)
        attachScreenshot()
    }
}
