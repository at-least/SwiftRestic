import Foundation
import Testing

/// The items Time Machine's options list, as a backup of a plan's folder
/// takes them.
@Suite("Time Machine exclusions")
struct TimeMachineExclusionsTests {
    /// A scratch folder spelled as FileManager hands it out — under
    /// /var/folders, whose real path is /private/var/folders.
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftResticTM-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func preferences(_ contents: [String: Any], in root: URL) throws -> URL {
        let file = root.appendingPathComponent("com.apple.TimeMachine.plist")
        try PropertyListSerialization.data(fromPropertyList: contents, format: .binary, options: 0).write(to: file)
        return file
    }

    private func folders(_ urls: URL...) throws {
        for url in urls { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    @Test("the listed items inside the folder are left out, spelled under the folder as given, each once")
    func listedItems() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(root.path.hasPrefix("/var/"), "the premise: the folder is spelled through a symlink, \(root.path)")
        let source = root.appendingPathComponent("source")
        let real = "/private" + source.path
        try folders(
            source.appendingPathComponent("Listed"), source.appendingPathComponent("Build/cache"),
            source.appendingPathComponent("Real"), URL(fileURLWithPath: source.path + "2/Sibling"),
            root.appendingPathComponent("elsewhere")
        )
        let file = try preferences([
            "SkipPaths": [
                source.path + "/Listed/",         // a trailing slash as the options may write it
                real + "/Real",                   // the real spelling of an item inside
                source.path + "/Real",            // the same item in the other spelling: once
                source.path + "/Build",
                source.path + "/Build/cache",     // inside a listed item: named once, with it
                source.path + "2/Sibling",        // beside the folder, not inside it
                root.path + "/elsewhere",         // outside the folder
                source.path + "/Gone",            // not on disk: nothing to leave out
            ],
            "PreferencesVersion": 6,
        ], in: root)
        let reading = TimeMachineExclusions.reading(for: source.path, preferences: file)
        #expect(reading.items == [source.path + "/Listed", source.path + "/Real", source.path + "/Build"])
        #expect(reading.notes.isEmpty)
    }

    @Test("a listed symbolic link is the link: what it points to is not left out")
    func listedLinkIsTheLink() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("proj")
        let release = source.appendingPathComponent("releases/v3")
        try folders(release)
        let current = source.appendingPathComponent("current")
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: release)
        let outside = root.appendingPathComponent("outside")
        try folders(outside)
        let away = source.appendingPathComponent("away")
        try FileManager.default.createSymbolicLink(at: away, withDestinationURL: outside)
        let file = try preferences(["SkipPaths": [current.path, away.path]], in: root)
        #expect(TimeMachineExclusions.reading(for: source.path, preferences: file).items == [current.path, away.path])
    }

    @Test("a listed item that is or holds the plan's folder is not applied, and the run's log says which")
    func listedItemHoldingTheFolder() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Library/Application Support/X")
        try folders(source)
        let file = try preferences(["SkipPaths": [root.path + "/Library", source.path]], in: root)
        let reading = TimeMachineExclusions.reading(for: source.path, preferences: file)
        #expect(reading.items.isEmpty)
        #expect(reading.notes == [
            "Time Machine’s options leave out “\(root.path)/Library”, which holds this plan’s folder. SwiftRestic backed it up anyway.",
            "Time Machine’s options leave out this plan’s folder, “\(source.path)”. SwiftRestic backed it up anyway.",
        ])
    }

    @Test("an item that can't be checked is named in the log, not passed over as absent")
    func uncheckableItem() throws {
        let root = try scratch()
        let source = root.appendingPathComponent("source")
        let shut = source.appendingPathComponent("shut")
        try folders(shut.appendingPathComponent("inner"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: shut.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shut.path)
            try? FileManager.default.removeItem(at: root)
        }
        let item = shut.path + "/inner"
        let file = try preferences(["SkipPaths": [item]], in: root)
        #expect(TimeMachineExclusions.location(of: item) == .unknown)
        #expect(TimeMachineExclusions.reading(for: source.path, preferences: file) == TimeMachineExclusions.Reading(
            notes: ["SwiftRestic couldn’t check “\(item)”, listed in Time Machine’s options, so it was backed up."]
        ))
    }

    @Test("only items spelled near the folder are looked up on disk")
    func nearness() {
        let folder = "/tmp/proj", real = "/private/tmp/proj"
        #expect(TimeMachineExclusions.isNear("/tmp/proj/build", folder: folder, realFolder: real))
        #expect(TimeMachineExclusions.isNear("/private/tmp/proj/build", folder: folder, realFolder: real))
        #expect(TimeMachineExclusions.isNear("/tmp", folder: folder, realFolder: real))
        #expect(!TimeMachineExclusions.isNear("/Volumes/NAS/scratch", folder: folder, realFolder: real))
        #expect(!TimeMachineExclusions.isNear("/tmp/project", folder: folder, realFolder: real))
    }

    @Test("no preferences file or no list means nothing listed and nothing to say")
    func nothingListed() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try folders(source)
        #expect(TimeMachineExclusions.reading(for: source.path, preferences: root.appendingPathComponent("absent.plist"))
            == TimeMachineExclusions.Reading())
        #expect(TimeMachineExclusions.reading(for: source.path, preferences: try preferences(["PreferencesVersion": 6], in: root))
            == TimeMachineExclusions.Reading())
    }

    @Test("a list this process may not read, or a damaged one, never fails the backup: the run's log says why it was not applied")
    func unreadableOrDamagedList() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try folders(source.appendingPathComponent("listed"))
        // Unreadable to its owner too, as the real file is to an app without
        // Full Disk Access.
        let locked = try preferences(["SkipPaths": [source.path + "/listed"]], in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        #expect(TimeMachineExclusions.reading(for: source.path, preferences: locked) == TimeMachineExclusions.Reading(
            notes: ["Time Machine’s list of excluded items can be read only with Full Disk Access, so the items listed there were backed up."]
        ))

        let damagedNote = ["Time Machine’s list of excluded items is damaged, so the items listed there were backed up."]
        let damaged = root.appendingPathComponent("damaged.plist")
        try "not a property list".write(to: damaged, atomically: true, encoding: .utf8)
        #expect(TimeMachineExclusions.reading(for: source.path, preferences: damaged).notes == damagedNote)
        // Readable, but not the shape Time Machine writes.
        let mixed = root.appendingPathComponent("mixed")
        try folders(mixed)
        #expect(TimeMachineExclusions.reading(for: source.path, preferences: try preferences(["SkipPaths": [source.path + "/listed", 7]], in: mixed)).notes == damagedNote)
        let array = mixed.appendingPathComponent("array.plist")
        try PropertyListSerialization.data(fromPropertyList: [source.path], format: .binary, options: 0).write(to: array)
        #expect(TimeMachineExclusions.reading(for: source.path, preferences: array).notes == damagedNote)
    }

    @Test("a plan folder that isn't on disk applies nothing, and says so")
    func folderNotOnDisk() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try preferences(["SkipPaths": [root.path + "/gone/listed"]], in: root)
        #expect(TimeMachineExclusions.reading(for: root.path + "/gone/plan", preferences: file).notes
            == ["SwiftRestic couldn’t find this plan’s folder on disk, so the items Time Machine’s options list were backed up."])
    }

    @Test("new plans skip Time Machine's exclusions; a plan saved before the option keeps backing them up")
    func planDefault() throws {
        #expect(BackupPlan().skipsTimeMachineExclusions)
        let older = try JSONDecoder().decode(BackupPlan.self, from: Data(#"{"path":"/Users/someone/Documents"}"#.utf8))
        #expect(!older.skipsTimeMachineExclusions)
        var configuration = AppConfiguration()
        configuration.plans = [BackupPlan()]
        #expect(try ConfigStore.decoded(ConfigStore.encoded(configuration)).0.plans[0].skipsTimeMachineExclusions)
    }
}
