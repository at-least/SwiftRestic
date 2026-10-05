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

    /// "Since Oct 3, 2026 at 2:05 PM, in this folder: 1 added, 2 removed" —
    /// or that nothing in it changed since then. Its subfolders' contents
    /// are theirs to say, so the line says where it looked.
    func summary(since previous: Date) -> String {
        let since = Format.timestamp(previous)
        guard !isEmpty else { return "No changes in this folder since \(since)" }
        let counts = [
            (added.count, "added"),
            (modified.count, "modified"),
            (removed.count, "removed"),
            (uncertain.count, "may have changed"),
        ]
        .filter { $0.0 > 0 }
        .map { "\(Format.count($0.0)) \($0.1)" }
        return "Since \(since), in this folder: \(counts.joined(separator: ", "))"
    }

    /// What is gone since the backup before, by name, in the order the
    /// index lists them; nil when nothing is.
    var removedNames: String? {
        removed.isEmpty ? nil : "Removed: " + removed.map(ResticPath.basename(of:)).joined(separator: ", ")
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
