import XCTest

/// A file deleted from the folder and backed up without it: the backup
/// before still holds it, marked as not on this Mac, and the tab's Restore
/// puts it back where it was.
final class DeletedFileUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRecoverADeletedFile() throws {
        let folders = try UITestFolders.make("DeletedFile")
        try Data("kept\n".utf8).write(to: folders.source.appendingPathComponent("kept.txt"))
        let original = try Data(contentsOf: folders.sourceFile)
        let app = UITest.launch(folders)
        UITest.backUpFirstFolder(folders, in: app)
        try FileManager.default.removeItem(at: folders.sourceFile)
        app.buttons[AccessibilityID.Plan.backUpNow].click()
        XCTAssertTrue(app.staticTexts[AccessibilityID.Plan.total].waitForValue(beginningWith: "2 backups · since ", timeout: 120))

        app.radioButtons["Backups"].click()
        let tree = app.outlines[AccessibilityID.RestorePane.tree]
        XCTAssertTrue(tree.staticTexts["kept.txt"].firstMatch.waitForExistence(timeout: 30))
        let gone = tree.staticTexts.matching(NSPredicate(format: "value == %@", "not on this Mac"))
        XCTAssertEqual(gone.count, 0, "the newest backup was made without the file")

        // Newest first: the second row is the backup before the deletion.
        let backups = app.outlines[AccessibilityID.Backups.list].outlineRows
        let two = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: backups)
        XCTAssertEqual(XCTWaiter().wait(for: [two], timeout: 30), .completed)
        let older = backups.element(boundBy: 1)
        older.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(older.waitForSelected())

        let deleted = gone.firstMatch
        XCTAssertTrue(deleted.waitForExistence(timeout: 30))
        XCTAssertEqual(gone.count, 1)
        deleted.click()
        let restoreButton = app.buttons[AccessibilityID.RestorePane.restore]
        XCTAssertTrue(restoreButton.waitForEnabled())
        restoreButton.click()

        // Nothing is in the way, so no Replace question and no sheet.
        let deadline = Date().addingTimeInterval(120)
        while !FileManager.default.fileExists(atPath: folders.sourceFile.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertTrue(restoreButton.waitForEnabled(timeout: 120))
        XCTAssertEqual(try Data(contentsOf: folders.sourceFile), original)
        attachScreenshot()
    }
}
