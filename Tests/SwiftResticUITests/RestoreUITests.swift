import XCTest

/// A plan's Files tab restores its folder as of the newest backup into a
/// folder chosen in the destination sheet, byte for byte.
final class RestoreUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRestoreFolderToOtherFolder() throws {
        let folders = try UITestFolders.make("Restore")
        let restored = folders.root.appendingPathComponent("restored")
        try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: true)
        let app = UITest.launch(folders)
        UITest.backUpFirstFolder(folders, in: app)

        app.radioButtons["Files"].click()
        let restoreButton = app.buttons[AccessibilityID.FilesPane.restore]
        XCTAssertTrue(restoreButton.waitForExistence(timeout: 30))
        XCTAssertTrue(restoreButton.waitForEnabled())
        restoreButton.click()

        app.radioButtons["Other folder"].click()
        app.buttons[AccessibilityID.RestoreSheet.chooseFolder].click()
        UITest.choose(restored, in: app)
        let restore = app.buttons[AccessibilityID.RestoreSheet.restore]
        XCTAssertTrue(restore.waitForEnabled())
        restore.click()

        let file = try XCTUnwrap(UITest.waitForFile(named: "hello.txt", under: restored))
        XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: folders.sourceFile))
        attachScreenshot()
    }
}
