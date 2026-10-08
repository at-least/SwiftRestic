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
    /// restic's node for it when the row carries one — a tree row's, a
    /// restic-engine hit's. Nil to have restic list it before restoring
    /// (`AppModel.listedNode`): a diff names a path and a kind, never a
    /// node, and an index row's kind is the index's, a cache's — a folder it
    /// called a file would go to `dump`, which writes its tar into one file
    /// with no error.
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
}
