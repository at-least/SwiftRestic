import XCTest

/// A plan's Backups tab restores its folder as of the newest backup into a
/// folder chosen in the folder panel, byte for byte.
final class RestoreUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRestoreFolderToChosenFolder() throws {
        let folders = try UITestFolders.make("Restore")
        let restored = folders.root.appendingPathComponent("restored")
        try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: true)
        let app = UITest.launch(folders)
        UITest.backUpFirstFolder(folders, in: app)

        UITest.restorePlanFolder(folders, into: restored, in: app)
        let file = try XCTUnwrap(UITest.waitForFile(named: "hello.txt", under: restored))
        XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: folders.sourceFile))
        attachScreenshot()
    }
}
