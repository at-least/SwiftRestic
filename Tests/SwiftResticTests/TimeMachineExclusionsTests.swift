import Foundation
import Testing

/// What Time Machine leaves out under a plan's folder: the items apps mark
/// (the attribute NSURLIsExcludedFromBackupKey sets, which `tmutil
/// isexcluded` reads) and the items Time Machine's options list.
@Suite("Time Machine exclusions")
struct TimeMachineExclusionsTests {
    /// A scratch folder spelled as FileManager hands it out — under
    /// /var/folders, whose real path is /private/var/folders.
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftResticTM-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func mark(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func preferences(_ contents: [String: Any], in root: URL) throws -> URL {
        let file = root.appendingPathComponent("com.apple.TimeMachine.plist")
        try PropertyListSerialization.data(fromPropertyList: contents, format: .binary, options: 0).write(to: file)
        return file
    }

    @Test("marked items are named once, spelled under the folder as given, their insides not walked")
    func markedItems() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(root.path.hasPrefix("/var/"), "the premise: the folder is spelled through a symlink, \(root.path)")
        let source = root.appendingPathComponent("source")
        let cache = source.appendingPathComponent("App/cache$HOME[1]")
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try "x".write(to: cache.appendingPathComponent("inner/f"), atomically: true, encoding: .utf8)
        try mark(cache)
        try mark(cache.appendingPathComponent("inner"))
        let scratchFile = source.appendingPathComponent("scratch.tmp")
        try "y".write(to: scratchFile, atomically: true, encoding: .utf8)
        try mark(scratchFile)
        try "z".write(to: source.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)

        let none = root.appendingPathComponent("absent.plist")
        let found = try TimeMachineExclusions.items(under: source.path, preferences: none)
        #expect(Set(found.items) == [cache.path, scratchFile.path])
        #expect(found.readTheList)
        // A file, and a link to the folder, hold nothing to walk.
        #expect(try TimeMachineExclusions.items(under: scratchFile.path, preferences: none).items.isEmpty)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(try TimeMachineExclusions.items(under: link.path, preferences: none).items.isEmpty)
    }

    @Test("the items Time Machine's options list join, those inside the folder only, once")
    func listedItems() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let marked = source.appendingPathComponent("marked")
        try FileManager.default.createDirectory(at: marked, withIntermediateDirectories: true)
        try mark(marked)
        let file = try preferences([
            "SkipPaths": [
                source.path + "/Listed/",       // a trailing slash as the options may write it
                marked.path + "/inside",        // already left out with its folder
                root.path + "/elsewhere",       // outside the folder
                source.path,                    // the folder itself: a plan's folder is never left out
                "~/NotUnderTheFolder",
            ],
            "PreferencesVersion": 6,
        ], in: root)
        #expect(try TimeMachineExclusions.items(under: source.path, preferences: file).items == [marked.path, source.path + "/Listed"])
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

    @Test("a list this process may not read leaves the marked items standing and says so, rather than failing the backup")
    func unreadableList() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let marked = source.appendingPathComponent("marked")
        try FileManager.default.createDirectory(at: marked, withIntermediateDirectories: true)
        try mark(marked)
        // Unreadable to its owner too, as the real file is to an app without
        // Full Disk Access.
        let file = try preferences(["SkipPaths": [source.path + "/listed"]], in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        #expect(try TimeMachineExclusions.listedPaths(in: file) == nil)
        #expect(try TimeMachineExclusions.items(under: source.path, preferences: file)
            == TimeMachineExclusions.Found(items: [marked.path], readTheList: false))
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
