import XCTest

/// The plan page's Back Up Now runs another backup at once, which the page counts.
final class BackUpNowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testBackUpNowAddsABackup() throws {
        let folders = try UITestFolders.make("BackUpNow")
        let app = UITest.launch(folders)
        UITest.backUpFirstFolder(folders, in: app)

        try Data("hello again\n".utf8).write(to: folders.sourceFile)
        let backUpNow = app.buttons[AccessibilityID.Plan.backUpNow]
        XCTAssertTrue(backUpNow.waitForEnabled())
        backUpNow.click()
        // Past one backup the line also says how far back they reach.
        XCTAssertTrue(app.staticTexts[AccessibilityID.Plan.total].waitForValue(beginningWith: "2 backups · since ", timeout: 120))
        attachScreenshot()
    }
}
