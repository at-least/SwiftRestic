import Foundation

/// The Compare sheet's selection as one restore: each row restored from the
/// backup of the two that holds it (`ResticDiffChange.holder`), as Find
/// Files restores a selection — one destination sheet, one run, a row inside
/// a selected folder of the same backup left to the folder
/// (`RestoreBatch.covering`).
enum DiffRestoreSelection {
    struct Item: Equatable {
        let change: ResticDiffChange
        let backup: Snapshot
        /// The path in the backup: a diff spells a folder with a trailing
        /// slash, restic's node does not.
        var path: String { ResticPath.normalized(change.path) }
    }

    /// The items to restore, in the rows' order, and the destination
    /// sheet's line about the rows a selected folder brings. A row whose
    /// backup is no longer listed (`holder` nil) is left out, as its own
    /// Restore… is grey. A folder covers only rows from its own backup: a
    /// file the newer backup removed is not inside the newer backup's
    /// folder of the same name.
    static func plan(
        _ changes: [ResticDiffChange],
        holder: (ResticDiffChange) -> Snapshot?
    ) -> (items: [Item], note: String?) {
        let held = changes.compactMap { change in holder(change).map { Item(change: change, backup: $0) } }
        let (items, covered) = RestoreBatch.covering(
            held,
            // A diff names a path and a kind, never a node: these stand in
            // for the folder test, and restic lists the real nodes before
            // restoring.
            node: { SnapshotNode(name: $0.change.name, type: $0.change.isDirectory ? .dir : .file, path: $0.path) },
            backup: \.backup.id
        )
        return (items, RestoreBatch.coveredNote(covered))
    }
}
