import Foundation
import Testing

/// A picked selection as the destination sheet shows it: what it restores,
/// from how many backups, and how it names them — one rule for every
/// surface that restores a selection.
@Suite("Restore selection")
struct RestoreSelectionTests {
    private let oct1 = Date(timeIntervalSince1970: 1_790_000_000)
    private let oct2 = Date(timeIntervalSince1970: 1_790_086_400)

    private func source(_ path: String, _ snapshotID: String, _ time: Date?, folder: Bool = false, node: Bool = true) -> RestoreSource {
        let name = (path as NSString).lastPathComponent
        return RestoreSource(
            name: name,
            path: path,
            isDirectory: folder,
            snapshotID: snapshotID,
            backupTime: time,
            node: node ? SnapshotNode(name: name, type: folder ? .dir : .file, path: path) : nil
        )
    }

    @Test("one item is restored as one; several from one backup carry its time and short ID")
    func oneBackup() throws {
        let one = try #require(RestoreSelection([source("/d/a.txt", "1e40fdf63e69", oct1)]))
        #expect(one.subject == .item(name: "a.txt", path: "/d/a.txt", isDirectory: false))
        #expect(one.backupCount == 1)
        #expect(one.backupTime == oct1)
        #expect(one.snapshotShortID == "1e40fdf6")
        #expect(one.note == nil)

        let several = try #require(RestoreSelection([
            source("/d/a.txt", "1e40fdf63e69", oct1),
            source("/d/b.txt", "1e40fdf63e69", oct1),
        ]))
        #expect(several.subject == .items([
            RestoreItem(name: "a.txt", path: "/d/a.txt", isDirectory: false),
            RestoreItem(name: "b.txt", path: "/d/b.txt", isDirectory: false),
        ]))
        #expect(several.backupCount == 1)
        #expect(several.backupTime == oct1)
    }

    @Test("items from several backups are counted, not dated, and named by the first one's backup")
    func severalBackups() throws {
        let selection = try #require(RestoreSelection([
            source("/src/notes", "487ad622a436", oct2, folder: true),
            source("/src/notes/keep.txt", "487ad622a436", oct2),
            source("/src/notes/notes.txt", "1e40fdf63e69", oct1, node: false),
        ]))
        #expect(selection.sources.map(\.path) == ["/src/notes", "/src/notes/notes.txt"])
        #expect(selection.backupCount == 2)
        #expect(selection.backupTime == nil)
        #expect(selection.snapshotShortID == "487ad622")
        #expect(selection.note == "“keep.txt” is inside “notes” and is restored with it.")
        // The row's node travels with it: nil means restic lists it first.
        #expect(selection.sources.map { $0.node == nil } == [false, true])
    }

    @Test("the sheet's backup line counts several backups, dates one, and leads with a version's own modified time")
    func backupLine() {
        let backup = Date(timeIntervalSince1970: 1_790_000_000)
        let modified = backup.addingTimeInterval(-7_200)
        #expect(RestoreSelection.backupLine(backupCount: 3, backupTime: nil, snapshotShortID: "abcdef12", versionModified: nil)
            == "from 3 backups, each item from the one it was found in")
        #expect(RestoreSelection.backupLine(backupCount: 1, backupTime: backup, snapshotShortID: "abcdef12", versionModified: nil)
            == "from \(Format.timestamp(backup))")
        #expect(RestoreSelection.backupLine(backupCount: 1, backupTime: nil, snapshotShortID: "abcdef12", versionModified: nil)
            == "from backup abcdef12")
        #expect(RestoreSelection.backupLine(backupCount: 1, backupTime: backup, snapshotShortID: "abcdef12", versionModified: modified)
            == "the version modified \(Format.timestamp(modified)), from the backup of \(Format.timestamp(backup))")
    }

    @Test("a selection that restores nothing is no selection")
    func empty() {
        #expect(RestoreSelection([]) == nil)
    }
}
