import XCTest

/// The first-run sheet end to end, with the restic the app bundles: a folder
/// and a destination chosen through the open panel, the Back Up button held
/// back until every answer is in, then a real repository and a first backup.
final class FirstBackupUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstBackup() throws {
        let folders = try UITestFolders.make("FirstBackup")
        let app = UITest.launch(folders)
        UITest.backUpFirstFolder(folders, in: app)
        attachScreenshot()
    }
}
