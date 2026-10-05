import Foundation

/// A backed-up file as this Mac holds it now, beside its versions in a Files
/// pane — the last fact a restore decision needs: is the copy here one of
/// these, or none, or gone? One `lstat` (FileManager's attributes, which do
/// not follow a link), no restic; it reads where Full Disk Access is not
/// granted too, since it opens nothing (FullDiskAccess.swift's probe).
enum DiskFile: Equatable {
    case missing
    /// A folder, a link or anything else that is not a regular file: no
    /// file to compare.
    case other
    case file(size: Int64, modified: Date)
    /// The attributes could not be read, and why.
    case unreadable(String)

    static func at(_ path: String) -> DiskFile {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date
            else { return .other }
            return .file(size: size.int64Value, modified: modified)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// Where an item of a chain's tree is on this Mac — its path itself —
    /// when the chain's newest backup was made here and names a folder
    /// holding it; nil otherwise. Another Mac's files are not on this disk,
    /// and a relative backup's tree holds them under a tail of the path it
    /// names (/Documents for /Users/…/Documents), which is no path here.
    static func localPath(of path: String, newestBackup: Snapshot?, localHostname: String) -> String? {
        guard let newestBackup, newestBackup.hostname == localHostname,
              newestBackup.paths.contains(where: { ResticPath.holds($0, path) })
        else { return nil }
        return path
    }

    /// How close a modification time must be to restic's to be the same
    /// one: restic's is read to the millisecond (`ResticDateFormat`), the
    /// disk's to the nanosecond — 0.81 ms apart for one untouched file,
    /// measured.
    static let mtimeTolerance: TimeInterval = 0.002

    /// The pane's line about it, given its versions newest first — each
    /// version's size and modification time as the find read them, nil
    /// while unknown — and whether that find still runs. Nil while it runs:
    /// which version the copy here is cannot be told yet, and a line that
    /// changed its mind a moment later would only flicker.
    func line(versions: [(size: Int64?, modified: Date?)], isReading: Bool) -> String? {
        switch self {
        case .missing:
            return "Not on this Mac"
        case .other:
            return "On this Mac it is not a file"
        case let .unreadable(reason):
            return "On this Mac it could not be read: \(Format.firstSentence(reason))"
        case let .file(size, modified):
            guard !isReading else { return nil }
            let match = versions.firstIndex { version in
                version.size == size
                    && version.modified.map { abs($0.timeIntervalSince(modified)) < Self.mtimeTolerance } == true
            }
            switch match {
            case 0?:
                return "On this Mac: the same as the newest version"
            case let index?:
                return "On this Mac: the same as the version modified \(Format.timestamp(versions[index].modified))"
            case nil:
                // Without every version's size and date — or with no
                // version at all — "matches none" would be a guess.
                let facts = "modified \(Format.timestamp(modified)), \(Format.bytes(size))"
                return !versions.isEmpty && versions.allSatisfy({ $0.size != nil && $0.modified != nil })
                    ? "On this Mac: \(facts) — no version here matches it"
                    : "On this Mac: \(facts)"
            }
        }
    }
}
