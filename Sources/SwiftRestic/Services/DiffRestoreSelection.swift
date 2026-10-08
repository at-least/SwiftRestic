import Foundation

/// The Compare sheet's rows as restore sources (`RestoreSelection`): each
/// from the backup of the two that holds it (`ResticDiffChange.holder`),
/// restic listing its node first — a diff names a path and a kind, never a
/// node. A row whose backup is no longer listed (`holder` nil) is left out,
/// as its own Restore… is grey.
enum DiffRestoreSelection {
    static func sources(
        _ changes: [ResticDiffChange],
        holder: (ResticDiffChange) -> Snapshot?
    ) -> [RestoreSource] {
        changes.compactMap { change in
            holder(change).map { backup in
                RestoreSource(
                    name: change.name,
                    // A diff spells a folder with a trailing slash, restic's
                    // node does not.
                    path: ResticPath.normalized(change.path),
                    isDirectory: change.isDirectory,
                    snapshotID: backup.id,
                    backupTime: backup.time,
                    node: nil
                )
            }
        }
    }
}
