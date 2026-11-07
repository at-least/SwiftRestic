import XCTest

/// What every UI test starts from: a folder of its own to back up, an empty
/// one to keep the backups in and a throwaway configuration, all under the
/// runner's temporary directory.
struct UITestFolders {
    let root: URL
    var config: URL { root.appendingPathComponent("config") }
    var source: URL { root.appendingPathComponent("source") }
    var backups: URL { root.appendingPathComponent("backups") }
    var sourceFile: URL { source.appendingPathComponent("hello.txt") }

    static func make(_ name: String) throws -> UITestFolders {
        let folders = UITestFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)"))
        for dir in [folders.config, folders.source, folders.backups] {
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
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return app
    }

    /// The first-run sheet from Back Up a Folder… to the plan page counting
    /// the first backup, with the bundled restic. Back Up stays off, each
    /// reason in turn, until every answer is in.
    static func backUpFirstFolder(_ folders: UITestFolders, in app: XCUIApplication) {
        let start = app.buttons[AccessibilityID.Welcome.backUpAFolder]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        start.click()

        let backUp = app.buttons[AccessibilityID.FirstBackup.backUp]
        let requirement = app.staticTexts[AccessibilityID.FirstBackup.requirement]
        XCTAssertTrue(backUp.waitForExistence(timeout: 10))
        XCTAssertFalse(backUp.isEnabled)
        XCTAssertEqual(requirement.value as? String, "Choose a folder to back up.")

        // Each choice checked where the sheet shows it: a Go to Folder that
        // missed leaves the panel on its last folder, and Choose takes that one.
        app.buttons[AccessibilityID.FirstBackup.chooseSource].click()
        choose(folders.source, in: app)
        XCTAssertTrue(app.staticTexts[AccessibilityID.FirstBackup.source].waitForValue(tilde(folders.source)))
        XCTAssertTrue(requirement.waitForValue("Choose where the backups go."))

        app.popUpButtons[AccessibilityID.FirstBackup.disk].click()
        app.menuItems["Other…"].click()
        choose(folders.backups, in: app)
        XCTAssertEqual(app.popUpButtons[AccessibilityID.FirstBackup.disk].value as? String, tilde(folders.backups))
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

        // The plan page the sheet lands on counts the backup restic just made.
        XCTAssertTrue(app.staticTexts[AccessibilityID.Plan.total].waitForValue("1 backup", timeout: 120))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folders.backups.appendingPathComponent("config").path))
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

    /// The open panel the app's FilePicker runs: Go to Folder with the path,
    /// then its Choose button.
    static func choose(_ folder: URL, in app: XCUIApplication) {
        let choose = app.buttons["Choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        app.typeKey("g", modifierFlags: [.command, .shift])
        // Go to Folder opens holding the last path typed into it; typing
        // after it made a path that went nowhere.
        app.typeKey("a", modifierFlags: [.command])
        app.typeText(folder.path)
        app.typeKey(.return, modifierFlags: [])
        choose.click()
        XCTAssertTrue(choose.waitForNonExistence(timeout: 10))
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
