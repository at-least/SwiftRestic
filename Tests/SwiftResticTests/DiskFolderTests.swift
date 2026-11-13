import Darwin
import Foundation
import Testing

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
    }

    @Test("a folder that can't be listed says why: nothing there, a drive away, its permissions, or macOS")
    func absences() throws {
        let root = try scratch()
        defer {
            chmod(root + "/locked", 0o755)
            try? FileManager.default.removeItem(atPath: root)
        }
        #expect(throws: FolderAbsence.missing(name: "nope")) { try DiskFolder.list(root + "/nope") }
        #expect(FileManager.default.createFile(atPath: root + "/file", contents: Data()))
        #expect(throws: FolderAbsence.missing(name: "file")) { try DiskFolder.list(root + "/file") }

        try FileManager.default.createDirectory(atPath: root + "/locked", withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: root + "/locked/inside", contents: Data()))
        #expect(chmod(root + "/locked", 0) == 0)
        #expect(throws: FolderAbsence.deniedByFilePermissions(name: "locked")) { try DiskFolder.list(root + "/locked") }

        let volume = "SwiftResticNoSuchVolume-\(UUID().uuidString)"
        #expect(throws: FolderAbsence.volumeAway(volume: volume)) { try DiskFolder.list("/Volumes/\(volume)/Data") }

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

    @Test("presence is a listing's bytes, as the tree's rows: a name in another case or normalization than the disk's is gone, as is all of a folder gone or a file; a refused folder's items are not taken for gone")
    func presence() throws {
        let root = try scratch()
        defer {
            chmod(root + "/locked", 0o755)
            try? FileManager.default.removeItem(atPath: root)
        }
        #expect(FileManager.default.createFile(atPath: root + "/report.txt", contents: Data()))
        // An NFD name, written by its bytes; lstat finds it by its NFC
        // spelling too, and "Report.txt" for "report.txt", on APFS as Macs
        // ship it.
        let nfd = root + "/cafe\u{301}.txt"
        let nfc = root + "/caf\u{E9}.txt"
        let descriptor = open(nfd, O_CREAT | O_WRONLY, 0o644)
        #expect(descriptor >= 0)
        close(descriptor)
        try FileManager.default.createDirectory(atPath: root + "/locked", withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: root + "/locked/inside", contents: Data()))
        #expect(chmod(root + "/locked", 0) == 0)

        let present = DiskFolder.present([
            root + "/report.txt", root + "/Report.txt", nfd, nfc, root + "/gone.txt",
            root + "/nope/x.txt", root + "/report.txt/below", root + "/locked/inside",
        ])
        #expect(present == [PathKey(root + "/report.txt"), PathKey(nfd), PathKey(root + "/locked/inside")])
    }

}
