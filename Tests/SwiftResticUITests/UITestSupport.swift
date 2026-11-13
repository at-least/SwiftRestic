import XCTest

/// What every UI test starts from, under the runner's temporary directory: a
/// folder of its own to back up, a folder the app takes for the Mac's one
/// external disk (SWIFTRESTIC_DISK, Debug builds) and a throwaway configuration.
struct UITestFolders {
    let root: URL
    var config: URL { root.appendingPathComponent("config") }
    var source: URL { root.appendingPathComponent("source") }
    var disk: URL { root.appendingPathComponent("Test Disk") }
    /// Where the first-run sheet keeps the backups on a disk.
    var repository: URL { disk.appendingPathComponent("SwiftRestic Backups") }
    var sourceFile: URL { source.appendingPathComponent("hello.txt") }

    static func make(_ name: String) throws -> UITestFolders {
        let folders = UITestFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)"))
        for dir in [folders.config, folders.source, folders.disk] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("hello\n".utf8).write(to: folders.sourceFile)
        return folders
    }
}

@MainActor
enum UITest {
    static func launch(_ folders: UITestFolders) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SWIFTRESTIC_CONFIG_DIR"] = folders.config.path
        app.launchEnvironment["SWIFTRESTIC_DISK"] = folders.disk.path
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return app
    }

    /// Back Up a Folder…'s folder panel, then the first-run sheet to its
    /// closing on a created repository and plan, with the bundled restic.
    /// Back Up stays off, each reason in turn, until every answer is in. The
    /// backup itself may still be running when this returns.
    static func createFirstBackup(_ folders: UITestFolders, in app: XCUIApplication) {
        let start = app.buttons[AccessibilityID.Welcome.backUpAFolder]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        start.click()

        // The panel comes before the sheet. Each choice checked where the
        // sheet shows it: a Go to Folder that missed leaves the panel on its
        // last folder, and Choose takes that one.
        choose(folders.source, in: app)
        let backUp = app.buttons[AccessibilityID.FirstBackup.backUp]
        let requirement = app.staticTexts[AccessibilityID.FirstBackup.requirement]
        XCTAssertTrue(backUp.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[AccessibilityID.FirstBackup.source].waitForValue(tilde(folders.source)))
        XCTAssertFalse(backUp.isEnabled)

        // One disk on the Mac is the sheet's answer on its own, so the next
        // question is the password.
        XCTAssertTrue(app.popUpButtons[AccessibilityID.FirstBackup.destination].waitForValue(folders.disk.lastPathComponent))
        XCTAssertTrue(requirement.waitForValue("Set a password to save it."))

        let password = app.secureTextFields[AccessibilityID.FirstBackup.password]
        password.click()
        password.typeText("correct horse")
        let confirm = app.secureTextFields[AccessibilityID.FirstBackup.confirmPassword]
        confirm.click()
        confirm.typeText("correct hors")
        XCTAssertTrue(requirement.waitForValue("The passwords don’t match."))
        XCTAssertFalse(backUp.isEnabled)

        confirm.typeText("e")
        XCTAssertTrue(requirement.waitForNonExistence(timeout: 5))
        XCTAssertTrue(backUp.isEnabled)
        backUp.click()
        XCTAssertTrue(backUp.waitForNonExistence(timeout: 120))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folders.repository.appendingPathComponent("config").path))
    }

    /// createFirstBackup, then the plan page the sheet lands on counting the
    /// backup restic just made.
    static func backUpFirstFolder(_ folders: UITestFolders, in app: XCUIApplication) {
        createFirstBackup(folders, in: app)
        XCTAssertTrue(app.staticTexts[AccessibilityID.Plan.total].waitForValue("1 backup", timeout: 120))
    }

    /// A path as the app shows it, ~ for the user's home. Not
    /// abbreviatingWithTildeInPath: the runner is sandboxed, its home its
    /// container, so it wrote ~/tmp/… where the app shows
    /// ~/Library/Containers/…/tmp/….
    static func tilde(_ url: URL) -> String {
        guard let account = getpwuid(getuid()) else { preconditionFailure("no account for uid \(getuid())") }
        let home = String(cString: account.pointee.pw_dir)
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    /// Waits for a file to appear anywhere under a folder: a restore writes
    /// in the background, after its sheet closes.
    static func waitForFile(named name: String, under folder: URL, timeout: TimeInterval = 120) -> URL? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let found = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .first { $0.lastPathComponent == name }
            if let found { return found }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        return nil
    }

    /// The plan's Backups tab, its newest backup's tree read: the backed-up
    /// folder's row, its contents open under it.
    static func showNewestBackup(_ folders: UITestFolders, in app: XCUIApplication) -> XCUIElement {
        app.radioButtons["Backups"].click()
        let tree = app.outlines[AccessibilityID.RestorePane.tree]
        XCTAssertTrue(tree.staticTexts["hello.txt"].firstMatch.waitForExistence(timeout: 30))
        return tree.staticTexts[folders.source.lastPathComponent].firstMatch
    }

    /// The plan's folder as of its newest backup, selected in its tree and
    /// restored through Restore To… into `folder`, chosen in the folder
    /// panel this Mac's backup opens straight away. Returns once the restore
    /// is over: Restore is back on.
    static func restorePlanFolder(_ folders: UITestFolders, into folder: URL, in app: XCUIApplication) {
        showNewestBackup(folders, in: app).click()
        let restoreButton = app.buttons[AccessibilityID.RestorePane.restore]
        XCTAssertTrue(restoreButton.waitForEnabled())
        restoreToButton(AccessibilityID.RestorePane.restoreTo, in: app).click()
        choose(folder, in: app)
        XCTAssertNotNil(waitForFile(named: "hello.txt", under: folder))
        XCTAssertTrue(restoreButton.waitForEnabled(timeout: 120))
    }

    /// A pane's Restore To…, by its identifier, once it can be clicked.
    static func restoreToButton(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForEnabled())
        return button
    }

    /// The open panel the app's FilePicker runs, driven element by element:
    /// keys sent before a part of it was up went elsewhere, and Choose took
    /// whatever folder the panel happened to have selected.
    static func choose(_ folder: URL, in app: XCUIApplication) {
        let panel = app.dialogs["open-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        let goTo = app.sheets["GoToWindow"]
        let path = goTo.textFields["PathTextField"]
        // A ⌘⇧G sent as the panel appears is lost: send it until the sheet is up.
        let deadline = Date().addingTimeInterval(20)
        repeat {
            panel.typeKey("g", modifierFlags: [.command, .shift])
        } while !path.waitForExistence(timeout: 2) && Date() < deadline
        XCTAssertTrue(path.exists)
        // Go to Folder opens holding the last path typed into it.
        path.typeKey("a", modifierFlags: [.command])
        path.typeText(folder.path + "\n")
        XCTAssertTrue(goTo.waitForNonExistence(timeout: 10))
        // Go to Folder opens a folder, or a file's folder with the file selected.
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        let shown = isDirectory.boolValue ? folder : folder.deletingLastPathComponent()
        XCTAssertTrue(panel.popUpButtons["where popup"].waitForValue(shown.lastPathComponent))
        panel.buttons["OKButton"].click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 10))
    }
}

// A SwiftUI Text's string is its element's value on macOS; its label is empty.
@MainActor
extension XCUIElement {
    func waitForValue(_ value: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }

    func waitForValue(beginningWith prefix: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value BEGINSWITH %@", prefix)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }

    func waitForValue(otherThan value: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value != %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }

    func waitForSelected(timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "selected == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }

    func waitForEnabled(timeout: TimeInterval = 30) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND enabled == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }
}

extension XCTestCase {
    @MainActor
    func attachScreenshot() {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }
}
