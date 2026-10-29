import Foundation
import Testing

/// The items Time Machine's options list, as a plan's folder holds them.
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

    @Test("the listed items inside the folder are left out, the folder itself and items elsewhere are not")
    func listedItems() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let file = try preferences([
            "SkipPaths": [
                source.path + "/Listed/",       // a trailing slash as the options may write it
                source.path + "2/Sibling",      // beside the folder, not inside it
                root.path + "/elsewhere",       // outside the folder
                source.path,                    // the folder itself: a plan's folder is never left out
                "~/NotUnderTheFolder",
            ],
            "PreferencesVersion": 6,
        ], in: root)
        #expect(try TimeMachineExclusions.items(under: source.path, preferences: file) == [source.path + "/Listed"])
        #expect(try TimeMachineExclusions.listedPaths(in: file)?.last == NSHomeDirectory() + "/NotUnderTheFolder")
    }

    @Test("no preferences file or no list means nothing listed; a damaged file is an error")
    func preferencesFile() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try TimeMachineExclusions.listedPaths(in: root.appendingPathComponent("absent.plist")) == [])
        #expect(try TimeMachineExclusions.listedPaths(in: preferences(["PreferencesVersion": 6], in: root)) == [])
        let damaged = root.appendingPathComponent("damaged.plist")
        try "not a property list".write(to: damaged, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try TimeMachineExclusions.listedPaths(in: damaged) }
    }

    @Test("a list this process may not read is nil, for the run to say so, rather than failing the backup")
    func unreadableList() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // Unreadable to its owner too, as the real file is to an app without
        // Full Disk Access.
        let file = try preferences(["SkipPaths": [root.path + "/source/listed"]], in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        #expect(try TimeMachineExclusions.listedPaths(in: file) == nil)
        #expect(try TimeMachineExclusions.items(under: root.path + "/source", preferences: file) == nil)
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
