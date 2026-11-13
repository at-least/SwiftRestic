import XCTest

/// A plan's search (⌘F on its Backups tab) lists what its backups hold, each
/// word matching the start of a word in a name.
final class FilesSearchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchMatchesTheStartOfAName() throws {
        let folders = try UITestFolders.make("FilesSearch")
        let app = UITest.launch(folders)
        UITest.backUpFirstFolder(folders, in: app)

        _ = UITest.showNewestBackup(folders, in: app)
        app.typeKey("f", modifierFlags: [.command])

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("hello")
        let hit = app.outlines[AccessibilityID.FilesSearch.results].staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "hello.txt")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 30))

        field.typeKey("a", modifierFlags: [.command])
        field.typeText("ello")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.outlines[AccessibilityID.FilesSearch.results].exists)
        attachScreenshot()
    }
}
