import Foundation

/// A Files tab's folder at one backup against the backup before that holds
/// it, in the pane's words: one line of what changed in the folder itself,
/// the names of what is gone — which the listing, being the chosen backup's,
/// cannot show — and the mark each listed item wears. The Restore pane's
/// Change column words: Added, Modified; "May have changed" where no diff
/// compared the two.
extension FolderChanges {
    var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && modified.isEmpty && uncertain.isEmpty
    }

    /// "Since Oct 3, 2026 at 2:05 PM, in this folder: 1 added, 2 deleted" —
    /// or that nothing in it changed since then. Its subfolders' contents
    /// are theirs to say, so the line says where it looked. `notRead`
    /// counts what `separatingUnread(_:)` took out of the removals.
    func summary(since previous: Date, notRead: Int = 0) -> String {
        let since = Format.timestamp(previous)
        guard !isEmpty || notRead > 0 else { return "No changes in this folder since \(since)" }
        let counts = [
            (added.count, "added"),
            (modified.count, "modified"),
            (removed.count, "deleted"),
            (notRead, "not read"),
            (uncertain.count, "may have changed"),
        ]
        .filter { $0.0 > 0 }
        .map { "\(Format.count($0.0)) \($0.1)" }
        return "Since \(since), in this folder: \(counts.joined(separator: ", "))"
    }

    /// The removals the chosen backup's own run could not read
    /// (`AppModel.unreadItems(inBackup:)`), taken out, each with why:
    /// restic left them out for want of reading them, and the disk may
    /// still hold them — not read, not removed. The rest stays as it was.
    func separatingUnread(_ unread: UnreadItems) -> (changes: FolderChanges, notRead: [RemovedItem]) {
        let notRead = removedItems.compactMap { item in
            unread.reason(for: item.path).map { RemovedItem(path: item.path, isDirectory: item.isDirectory, reason: $0) }
        }
        guard !notRead.isEmpty else { return (self, []) }
        var changes = self
        changes.removed.removeAll { unread.item(holding: $0) != nil }
        return (changes, notRead)
    }

    /// What is gone since the backup before, by name, in the order the
    /// index lists them — the "Deleted:" line's tooltip, every name; nil
    /// when nothing is.
    var removedNames: String? {
        removed.isEmpty ? nil : removed.map(ResticPath.basename(of:)).joined(separator: ", ")
    }

    /// What is gone, each with its kind, in the order the index lists
    /// them — the "Deleted:" line's routes.
    var removedItems: [RemovedItem] {
        removed.map { RemovedItem(path: $0, isDirectory: removedFolders.contains(PathKey($0))) }
    }

    /// Each listed child's mark, keyed by its path's bytes.
    var marks: [PathKey: String] {
        var marks: [PathKey: String] = [:]
        for path in added { marks[PathKey(path)] = "Added" }
        for path in modified { marks[PathKey(path)] = "Modified" }
        for path in uncertain { marks[PathKey(path)] = "May have changed" }
        return marks
    }
}
