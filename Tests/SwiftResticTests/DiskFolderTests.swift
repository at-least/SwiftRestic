import Darwin
import Foundation
import Testing

/// A folder of this Mac as a plan's Files tab lists it (`DiskFolder`), and
/// why one can't be listed (`FolderAbsence`), on scratch folders.
@Suite("disk folder")
struct DiskFolderTests {
    private func scratch() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticDiskFolder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    @Test("a listing names each item by its bytes, a package as a folder and a link as none, a dot name and the hidden flag as hidden")
    func listing() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/real", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/Thing.app/Contents", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: "real")
        #expect(FileManager.default.createFile(atPath: root + "/.hidden", contents: Data()))
        #expect(FileManager.default.createFile(atPath: root + "/flagged", contents: Data()))
        // The flag ~/Library carries.
        #expect(chflags(root + "/flagged", UInt32(UF_HIDDEN)) == 0)
        // An NFD name, written by its bytes.
        let nfd = "cafe\u{301}.txt"
        let descriptor = open(root + "/" + nfd, O_CREAT | O_WRONLY, 0o644)
        #expect(descriptor >= 0)
        close(descriptor)

        let items = try DiskFolder.list(root).sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        #expect(items.map(\.name) == [".hidden", "Thing.app", nfd, "flagged", "link", "real"])
        #expect(items.map(\.isDirectory) == [false, true, false, false, false, true])
        #expect(items.map(\.isHidden) == [true, false, false, true, false, false])
        // Swift's == would take the NFC spelling for it too: the bytes are
        // what the index keys on.
        #expect(Array(items[2].name.utf8) == Array(nfd.utf8))

        #expect(try DiskFolder.isDirectory(root + "/real"))
        #expect(try !DiskFolder.isDirectory(root + "/link"))
        #expect(try !DiskFolder.isDirectory(root + "/flagged"))
    }

    @Test("a folder that can't be listed says why: nothing there, a drive away, its permissions, or macOS")
    func absences() throws {
        let root = try scratch()
        defer {
            chmod(root + "/locked", 0o755)
            try? FileManager.default.removeItem(atPath: root)
        }
        #expect(throws: FolderAbsence.missing(name: "nope")) { try DiskFolder.list(root + "/nope") }
        #expect(throws: FolderAbsence.missing(name: "nope")) { try DiskFolder.isDirectory(root + "/nope") }
        #expect(FileManager.default.createFile(atPath: root + "/file", contents: Data()))
        #expect(throws: FolderAbsence.missing(name: "file")) { try DiskFolder.list(root + "/file") }

        try FileManager.default.createDirectory(atPath: root + "/locked", withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: root + "/locked/inside", contents: Data()))
        #expect(chmod(root + "/locked", 0) == 0)
        #expect(throws: FolderAbsence.deniedByFilePermissions(name: "locked")) { try DiskFolder.list(root + "/locked") }

        let volume = "SwiftResticNoSuchVolume-\(UUID().uuidString)"
        #expect(throws: FolderAbsence.volumeAway(volume: volume)) { try DiskFolder.list("/Volumes/\(volume)/Data") }
        #expect(throws: FolderAbsence.volumeAway(volume: volume)) { try DiskFolder.isDirectory("/Volumes/\(volume)/Data") }

        // macOS's privacy protection answers EPERM, which a test cannot
        // provoke: the code, and a listing's error over it.
        #expect(FolderAbsence(path: "/Users/x/Documents", code: EPERM) == .blockedByMacOS(name: "Documents"))
        let refused = NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
        ])
        #expect(FolderAbsence(path: "/Users/x/Documents", error: refused) == .blockedByMacOS(name: "Documents"))
        #expect(FolderAbsence(path: "/Users/x/Documents", code: EIO) == .unreadable(name: "Documents", reason: String(cString: strerror(EIO))))

        // Gone is only what lstat finds nothing at: an item SwiftRestic may
        // not look into is not taken for deleted.
        #expect(DiskFolder.exists(root + "/file"))
        #expect(!DiskFolder.exists(root + "/nope"))
        #expect(!DiskFolder.exists(root + "/file/below"))
        #expect(DiskFolder.exists(root + "/locked/inside"))
        try FileManager.default.createSymbolicLink(atPath: root + "/dangling", withDestinationPath: "nowhere")
        #expect(DiskFolder.exists(root + "/dangling"))
    }

    @Test("each absence has its headline and its sentence")
    func absenceWords() {
        #expect(FolderAbsence.volumeAway(volume: "TinyDisk").title == "“TinyDisk” is not connected")
        #expect(FolderAbsence.volumeAway(volume: "TinyDisk").detail == "The folder is on it.")
        #expect(FolderAbsence.missing(name: "Documents").title == "“Documents” is not on this Mac")
        #expect(FolderAbsence.missing(name: "Documents").detail == "It was moved, renamed or deleted.")
        #expect(FolderAbsence.blockedByMacOS(name: "Documents").title == "SwiftRestic can't read “Documents”")
        #expect(FolderAbsence.blockedByMacOS(name: "Documents").detail == "macOS blocked it: SwiftRestic needs Full Disk Access.")
        #expect(FolderAbsence.deniedByFilePermissions(name: "Documents").detail
            == "It can't be read with your account's file permissions.")
        #expect(FolderAbsence.unreadable(name: "Documents", reason: "Input/output error").detail == "Input/output error")
    }
}
