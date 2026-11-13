import XCTest

final class PlanEditorUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A file added to Exclude (+, the open panel) is in the first backup
    /// and not in the next one: the newest backup restored holds the folder's
    /// other file alone.
    @MainActor
    func testExcludedFileIsLeftOutOfTheNextBackup() throws {
        let folders = try UITestFolders.make("Exclude")
        let secret = folders.source.appendingPathComponent("secret.txt")
        try Data("not for the backup\n".utf8).write(to: secret)
        let restored = folders.root.appendingPathComponent("restored")
        try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: true)
        let app = UITest.launch(folders)
        UITest.backUpFirstFolder(folders, in: app)

        app.buttons[AccessibilityID.Plan.edit].click()
        let save = app.buttons[AccessibilityID.PlanEditor.save]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        // Exclude's + is in view as the editor opens, no scrolling: above
        // the Cancel and Save bar. XCUITest calls a + below the fold hittable
        // too, and the click lands on whatever covers it.
        let add = app.buttons[AccessibilityID.PathList.add]
        XCTAssertLessThan(add.frame.maxY, save.frame.minY)
        add.click()
        UITest.choose(secret, in: app)
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))

        app.buttons[AccessibilityID.Plan.backUpNow].click()
        XCTAssertTrue(app.staticTexts[AccessibilityID.Plan.total].waitForValue(beginningWith: "2 backups · since ", timeout: 120))

        UITest.restorePlanFolder(folders, into: restored, in: app)
        XCTAssertNotNil(UITest.waitForFile(named: "hello.txt", under: restored, timeout: 5))
        XCTAssertNil(UITest.waitForFile(named: "secret.txt", under: restored, timeout: 5))
        attachScreenshot()
    }

    /// How often, set on the plan page, is saved at once: Manually, and the
    /// next backup waits for Back Up Now.
    @MainActor
    func testManuallyWaitsForBackUpNow() throws {
        let folders = try UITestFolders.make("Manually")
        let app = UITest.launch(folders)
        UITest.backUpFirstFolder(folders, in: app)
        let howOften = app.popUpButtons[AccessibilityID.Plan.frequency]
        XCTAssertTrue(howOften.waitForValue("Daily"))

        howOften.click()
        howOften.menuItems["Manually"].click()

        XCTAssertTrue(howOften.waitForValue("Manually"))
        XCTAssertTrue(app.staticTexts[AccessibilityID.Plan.nextBackup].waitForValue("When you click Back Up Now"))
        attachScreenshot()
    }

    /// Remove Plan (the Backup menu) asks first, then the plan is gone from the
    /// sidebar and its backup stays in the repository.
    @MainActor
    func testRemovePlanKeepsItsBackups() throws {
        let folders = try UITestFolders.make("RemovePlan")
        let app = UITest.launch(folders)
        UITest.backUpFirstFolder(folders, in: app)
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.staticTexts["source"].exists)

        let backupMenu = app.menuBars.menuBarItems["Backup"]
        backupMenu.click()
        backupMenu.menuItems["Remove Plan…"].click()
        let remove = app.buttons["Remove Plan"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.click()

        XCTAssertTrue(sidebar.staticTexts["source"].waitForNonExistence(timeout: 10))
        let snapshots = try FileManager.default.contentsOfDirectory(atPath: folders.repository.appendingPathComponent("snapshots").path)
        XCTAssertEqual(snapshots.count, 1)
        attachScreenshot()
    }
}
