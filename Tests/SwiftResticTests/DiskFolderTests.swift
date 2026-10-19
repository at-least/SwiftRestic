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

    @Test("each absence has its headline and its reason; a refusal has its fix, by Full Disk Access now")
    func absenceWords() {
        let away = FolderAbsence.volumeAway(volume: "TinyDisk")
        #expect(away.title == "“TinyDisk” is not connected")
        #expect(away.detail(fullDiskAccess: .notGranted) == "The folder is on it.")
        let gone = FolderAbsence.missing(name: "Documents")
        #expect(gone.title == "“Documents” is not on this Mac")
        #expect(gone.detail(fullDiskAccess: .notGranted) == "It was moved, renamed or deleted.")
        let unreadable = FolderAbsence.unreadable(name: "Documents", reason: "Input/output error")
        #expect(unreadable.detail(fullDiskAccess: .granted) == "Input/output error")
        // A drive to connect and a folder to put back: steps, no button —
        // the folder's in a failed backup's words; the system's own error
        // has none.
        for access: FullDiskAccessStatus in [.granted, .notGranted, .unknown] {
            #expect(away.remedy(fullDiskAccess: access)
                == FolderAbsence.Remedy(steps: "Connect “TinyDisk” to see the folder here.", fix: nil))
            #expect(gone.remedy(fullDiskAccess: access)
                == FolderAbsence.Remedy(steps: "Put it back, or back it up where it is now with a new plan.", fix: nil))
            #expect(unreadable.remedy(fullDiskAccess: access) == nil, "\(access)")
        }
        #expect(RunRecord.folderGoneMessage(path: "/Users/x/Documents")
            == "“Documents” is not on this Mac — it was moved, renamed or deleted. Put it back, or back it up where it is now with a new plan.")

        // macOS's block: the grant, while SwiftRestic lacks it — or the
        // probe found nothing to say it has it.
        let blocked = FolderAbsence.blockedByMacOS(name: "Documents")
        #expect(blocked.title == "SwiftRestic can't read “Documents”")
        let grant = FolderAbsence.Remedy(
            steps: "Turn SwiftRestic on in System Settings › Privacy & Security › Full Disk Access, then quit and reopen SwiftRestic.",
            fix: .openFullDiskAccessSettings
        )
        for access: FullDiskAccessStatus in [.notGranted, .unknown] {
            #expect(blocked.detail(fullDiskAccess: access) == "macOS blocked it: SwiftRestic needs Full Disk Access.")
            #expect(blocked.remedy(fullDiskAccess: access) == grant)
        }
        // With the grant on, macOS protects it itself: no fix to offer.
        #expect(blocked.detail(fullDiskAccess: .granted)
            == "macOS blocked it even with Full Disk Access on — it is likely protected by macOS itself.")
        #expect(blocked.remedy(fullDiskAccess: .granted) == nil)

        // The file permissions: Finder's Get Info, whatever the grant.
        let denied = FolderAbsence.deniedByFilePermissions(name: "Documents")
        #expect(denied.title == "SwiftRestic can't read “Documents”")
        for access: FullDiskAccessStatus in [.granted, .notGranted, .unknown] {
            #expect(denied.detail(fullDiskAccess: access) == "It can't be read with your account's file permissions.")
            #expect(denied.remedy(fullDiskAccess: access) == FolderAbsence.Remedy(
                steps: "Full Disk Access doesn't change that: select it in Finder, choose File › Get Info, and give your account Read access under Sharing & Permissions.",
                fix: .revealInFinder
            ))
        }
    }
}
