import Darwin
import Foundation

/// A folder of this Mac as it is now: what a plan's Files tab lists, each
/// item beside what the backups hold of it (`FilesTree`). A listed name has
/// the bytes the file system gave it, which restic records too — an NFC
/// and an NFD name each came back byte for byte from a listing and from
/// `restic ls --json` on APFS (2026-10-19) — so a listed path and an
/// indexed one are one `PathKey`. Each call reads the file system, which a
/// stalled share can hold for seconds: callers run it off the main actor.
enum DiskFolder {
    /// One item of a listing.
    struct Item: Equatable, Sendable {
        let name: String
        /// A folder, a package among them, as restic records a `dir`. A
        /// link is not one, whatever it points at: restic records the link.
        let isDirectory: Bool
        /// A dot name, or the hidden flag ~/Library carries.
        let isHidden: Bool
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]

    /// The items directly in the folder at `path`. Throws `FolderAbsence`
    /// when it cannot be listed.
    static func list(_ path: String) throws -> [Item] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path, isDirectory: true),
                includingPropertiesForKeys: keys
            )
        } catch {
            throw FolderAbsence(path: path, error: error)
        }
        return try urls.map { url in
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                throw FolderAbsence(path: url.path, error: error)
            }
            return Item(
                name: url.lastPathComponent,
                isDirectory: values.isDirectory == true,
                isHidden: values.isHidden == true
            )
        }
    }

    /// Whether the item at `path` is a folder, by `lstat`, so a link is the
    /// link. Throws `FolderAbsence` when nothing is there or it cannot be
    /// looked at.
    static func isDirectory(_ path: String) throws -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw FolderAbsence(path: path, code: errno) }
        return info.st_mode & S_IFMT == S_IFDIR
    }

    /// Whether anything is at `path` — false only when `lstat` finds
    /// nothing there, so an item whose folder SwiftRestic may not read is
    /// not taken for gone.
    static func exists(_ path: String) -> Bool {
        var info = stat()
        if lstat(path, &info) == 0 { return true }
        return errno != ENOENT && errno != ENOTDIR
    }
}

/// Why a folder of this Mac cannot be listed, in the Files tab's words —
/// the drive away and the folder gone as a backup's skip and failure say
/// them (`RunRecord`), macOS's privacy protection and the file permissions
/// as an unreadable item's diagnosis does (`ItemErrorDiagnosis`).
enum FolderAbsence: Error, Equatable, Sendable {
    /// The drive or network share it is on is not connected: its volume.
    case volumeAway(volume: String)
    /// Nothing is there: moved, renamed or deleted.
    case missing(name: String)
    /// EPERM: macOS's privacy protection said no.
    case blockedByMacOS(name: String)
    /// EACCES: the folder's own permissions keep the user out.
    case deniedByFilePermissions(name: String)
    /// Anything else, in the system's words.
    case unreadable(name: String, reason: String)

    init(path: String, code: Int32) {
        let name = ResticPath.basename(of: path)
        switch code {
        case ENOENT, ENOTDIR:
            if let volume = VolumePresence.volumeName(of: path), VolumePresence.isMounted(volumeOf: path) == false {
                self = .volumeAway(volume: volume)
            } else {
                self = .missing(name: name)
            }
        case EPERM: self = .blockedByMacOS(name: name)
        case EACCES: self = .deniedByFilePermissions(name: name)
        default: self = .unreadable(name: name, reason: String(cString: strerror(code)))
        }
    }

    /// A Foundation error's POSIX code underneath, which a listing's
    /// CocoaError carries (260 over ENOENT, 257 over EACCES, 256 over
    /// ENOTDIR, seen 2026-10-19).
    init(path: String, error: any Error) {
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        if let underlying, underlying.domain == NSPOSIXErrorDomain {
            self.init(path: path, code: Int32(underlying.code))
        } else {
            self = .unreadable(name: ResticPath.basename(of: path), reason: Format.firstSentence(error.localizedDescription))
        }
    }

    /// The headline: what is wrong, naming what it is wrong with.
    var title: String {
        switch self {
        case let .volumeAway(volume): "“\(volume)” is not connected"
        case let .missing(name): "“\(name)” is not on this Mac"
        case let .blockedByMacOS(name), let .deniedByFilePermissions(name), let .unreadable(name, _):
            "SwiftRestic can't read “\(name)”"
        }
    }

    /// The sentence under it.
    var detail: String {
        switch self {
        case .volumeAway: "The folder is on it."
        case .missing: "It was moved, renamed or deleted."
        case .blockedByMacOS: "macOS blocked it: SwiftRestic needs Full Disk Access."
        case .deniedByFilePermissions: "It can't be read with your account's file permissions."
        case let .unreadable(_, reason): reason
        }
    }
}
