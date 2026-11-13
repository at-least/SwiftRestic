import XCTest

/// ⌘F on a plan's Backups tab opens Search All Backups, the app's one
/// search, which lists what the backups hold, each word matching the start
/// of a word in a name.
final class SearchAllBackupsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchMatchesTheStartOfAName() throws {
        let folders = try UITestFolders.make("SearchAllBackups")
        let app = UITest.launch(folders)
        UITest.backUpFirstFolder(folders, in: app)

        _ = UITest.showNewestBackup(folders, in: app)
        app.typeKey("f", modifierFlags: [.command])

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("hello")
        let hit = app.tables[AccessibilityID.FindFiles.results].staticTexts["hello.txt"].firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 30))

        field.typeKey("a", modifierFlags: [.command])
        field.typeText("ello")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.tables[AccessibilityID.FindFiles.results].exists)
        attachScreenshot()
    }
}
