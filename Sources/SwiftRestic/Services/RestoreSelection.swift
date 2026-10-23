import Foundation

/// One picked item of a restore — a row of the Restore pane, Find Files or
/// the Compare sheet: where it is in which backup, and restic's node for it
/// when the row carries one.
struct RestoreSource: RestoreBatchItem, Sendable, Equatable {
    let name: String
    /// Its path in the backup, as restic's node spells it: no trailing slash.
    let path: String
    let isDirectory: Bool
    let snapshotID: String
    let backupTime: Date?
    /// restic's node for it, or one whose kind was read for this very
    /// backup: the restore takes its file or folder route from it as it is.
    /// Nil when the kind in hand was read anywhere else — another backup, a
    /// diff, the disk — and the restore reads its kind in this backup first:
    /// the index's, or restic's listing where the index has not read the
    /// backup (`AppModel.restore(_:repositoryID:into:overwrite:)`): a path
    /// can be a file in one backup and a
    /// folder in the next, and the other route fails it. A file restored as
    /// a folder is refused as "not a directory", an empty folder left at its
    /// landing; a folder restored as a file, where a folder of its name
    /// already stands, is kept whole under Keep and, holding anything,
    /// refused under Replace.
    let node: SnapshotNode?
}

extension RestoreSource {
    /// An item whose node is in hand.
    init(_ node: SnapshotNode, snapshotID: String, backupTime: Date?) {
        self.init(
            name: node.name,
            path: node.path,
            isDirectory: node.isDirectory,
            snapshotID: snapshotID,
            backupTime: backupTime,
            node: node
        )
    }
}

/// A picked selection as one restore through the destination sheet: the
/// items it restores, each from its own backup (`RestoreBatch.covering`),
/// and what the sheet says of them. Every surface that restores a selection
/// builds one, so they read and restore alike.
struct RestoreSelection: Sendable, Equatable {
    /// The items to restore, in the picked order; never empty.
    let sources: [RestoreSource]
    /// The sheet's line about picked items a selected folder brings.
    let note: String?

    /// Nil when the picked items restore nothing.
    init?(_ picked: [RestoreSource]) {
        let (kept, covered) = RestoreBatch.covering(picked, backup: \.snapshotID)
        guard !kept.isEmpty else { return nil }
        sources = kept
        note = RestoreBatch.coveredNote(covered)
    }

    /// One item restores as a single item always has, several together.
    var subject: RestoreSubject {
        guard sources.count > 1 else {
            return .item(name: sources[0].name, path: sources[0].path, isDirectory: sources[0].isDirectory)
        }
        return .items(sources.map { RestoreItem(name: $0.name, path: $0.path, isDirectory: $0.isDirectory) })
    }

    /// How many backups the items come from.
    var backupCount: Int { Set(sources.map(\.snapshotID)).count }

    /// The one backup's time; nil for items from several, which the sheet
    /// counts instead.
    var backupTime: Date? { backupCount == 1 ? sources[0].backupTime : nil }

    /// The first item's backup as restic shortens its ID: `short_id` is the
    /// ID's first eight characters.
    var snapshotShortID: String { String(sources[0].snapshotID.prefix(8)) }

    /// The destination sheet's second line: where the bytes come from.
    /// Several backups are counted; one is dated — and when the request
    /// came from a version row, named by its modified time rather than its
    /// backup's, that time leads, so the confirmation repeats the words the
    /// user picked by ("the version modified Sep 17, 2026 at 9:00 PM, from
    /// the backup of Sep 17, 2026 at 11:00 PM").
    static func backupLine(backupCount: Int, backupTime: Date?, snapshotShortID: String, versionModified: Date?) -> String {
        if backupCount > 1 { return "from \(Format.count(backupCount)) backups, each item from the one it was found in" }
        guard let backupTime else { return "from backup \(snapshotShortID)" }
        if let versionModified {
            return "the version modified \(Format.timestamp(versionModified)), from the backup of \(Format.timestamp(backupTime))"
        }
        return "from \(Format.timestamp(backupTime))"
    }
}
