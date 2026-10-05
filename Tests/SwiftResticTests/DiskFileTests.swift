import Foundation
import Testing

/// A Files pane's line about the copy on this Mac: read with one lstat from
/// a real temporary folder, and matched against the versions by size and
/// modification time to restic's millisecond.
@Suite("Disk file")
struct DiskFileTests {
    private let modified = Date(timeIntervalSince1970: 1_791_206_980.7338095)
    /// The same moment as restic reports it: cut to the millisecond.
    private let asRestic = Date(timeIntervalSince1970: 1_791_206_980.733)

    @Test("a file, a folder, a link and nothing at all read as what they are")
    func readsTheDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DiskFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.txt")
        try Data("hello\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        guard case let .file(size, read) = DiskFile.at(file.path) else {
            Issue.record("a regular file read as \(DiskFile.at(file.path))")
            return
        }
        #expect(size == 6)
        #expect(abs(read.timeIntervalSince(modified)) < 0.000_001)
        #expect(DiskFile.at(folder.path) == .other)
        // Not followed: the link itself is no file to compare.
        #expect(DiskFile.at(link.path) == .other)
        #expect(DiskFile.at(folder.appendingPathComponent("gone.txt").path) == .missing)
    }

    @Test("the copy here is named by the version it matches, to restic's millisecond, or by its own facts")
    func matchesAVersion() {
        let disk = DiskFile.file(size: 106, modified: modified)
        let older = Date(timeIntervalSince1970: 1_791_000_000)
        #expect(disk.line(versions: [(106, asRestic), (89, older)], isReading: false)
            == "On this Mac: the same as the newest version")
        #expect(disk.line(versions: [(120, Date(timeIntervalSince1970: 1_791_300_000)), (106, asRestic)], isReading: false)
            == "On this Mac: the same as the version modified \(Format.timestamp(asRestic))")
        // The same size a second apart is another content's date.
        let facts = "modified \(Format.timestamp(modified)), \(Format.bytes(106))"
        #expect(disk.line(versions: [(106, asRestic.addingTimeInterval(1))], isReading: false)
            == "On this Mac: \(facts) — no version here matches it")
        // A version not yet read keeps "matches none" from being said.
        #expect(disk.line(versions: [(89, older), (nil, nil)], isReading: false) == "On this Mac: \(facts)")
        // While the find runs, nothing.
        #expect(disk.line(versions: [(106, asRestic)], isReading: true) == nil)
        // No version to compare with is no verdict either.
        #expect(disk.line(versions: [], isReading: false) == "On this Mac: \(facts)")
    }

    @Test("only this Mac's backups of a folder by its own path compare with the disk")
    func localPathGate() throws {
        let mine = try IndexTestData.snapshot("s1", micros: 1, hostname: "this-mac", paths: ["/Users/x/Documents"])
        #expect(DiskFile.localPath(of: "/Users/x/Documents/a.txt", newestBackup: mine, localHostname: "this-mac")
            == "/Users/x/Documents/a.txt")
        // Another Mac's, none at all, and a path the backup does not name —
        // a relative backup's /Documents, or a sibling by bytes.
        #expect(DiskFile.localPath(of: "/Users/x/Documents/a.txt", newestBackup: mine, localHostname: "other-mac") == nil)
        #expect(DiskFile.localPath(of: "/Users/x/Documents/a.txt", newestBackup: nil, localHostname: "this-mac") == nil)
        #expect(DiskFile.localPath(of: "/Documents/a.txt", newestBackup: mine, localHostname: "this-mac") == nil)
        #expect(DiskFile.localPath(of: "/Users/x/Documents2/a.txt", newestBackup: mine, localHostname: "this-mac") == nil)
    }

    @Test("a missing file, something that is not a file, and an unreadable one each say so, read or not")
    func otherStates() {
        #expect(DiskFile.missing.line(versions: [], isReading: true) == "Not on this Mac")
        #expect(DiskFile.other.line(versions: [], isReading: false) == "On this Mac it is not a file")
        #expect(DiskFile.unreadable("Permission denied. More text.").line(versions: [], isReading: false)
            == "On this Mac it could not be read: \(Format.firstSentence("Permission denied. More text."))")
    }
}
