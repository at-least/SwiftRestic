import Foundation

/// What the Restore pane's search found, split by the backup that is open.
/// The pane lists only the hits the open backup contains; the index already
/// says which other backups hold the rest, and that answer used to be
/// thrown away — leaving "No matches in this backup" a dead end when the
/// file was one backup away.
struct RestorePaneSearch: Equatable, Sendable {
    /// Hits the open backup contains: the rows the pane lists, in index
    /// order, each carrying its kind in the open backup. The search's own
    /// kind is the path's kind in the newest backup holding it, and a path
    /// that is a file there may be a folder here. The pane restores from the
    /// open backup, and the restore picks `restic dump` for a file and
    /// `restic restore` for a folder by this kind.
    let inThisBackup: [SearchHit]
    /// Matching paths the index holds only in other backups of the
    /// repository: the hits the open backup lacks. The search returns only
    /// paths some indexed backup holds, so no second read is needed to
    /// place them — a path whose every version was pruned is never a hit.
    /// The search and the membership are one read of the index, so the
    /// count is exact for the index as that read saw it.
    let elsewhereCount: Int
    /// The index stopped at its hit ceiling, so both parts may be short.
    let isTruncated: Bool
    let limit: Int
    /// Whether the index had read every backup when the search ran. Until
    /// it has, the open backup may be one it has not read, and its own
    /// files then look as if only other backups held them.
    let indexIsComplete: Bool

    /// `inRecord` is the index's membership answer for the hits in the open
    /// backup — path to its kind there, true for a folder — keyed by the
    /// path's bytes: a hit whose name only canonically equals one the open
    /// backup holds is another path, and elsewhere.
    init(hits: [SearchHit], inRecord: [PathKey: Bool], limit: Int, indexIsComplete: Bool) {
        var inside: [SearchHit] = []
        for hit in hits {
            if let isDirectory = inRecord[PathKey(hit.path)] {
                inside.append(SearchHit(path: hit.path, isDirectory: isDirectory))
            }
        }
        inThisBackup = inside
        elsewhereCount = hits.count - inside.count
        isTruncated = hits.count >= limit
        self.limit = limit
        self.indexIsComplete = indexIsComplete
    }

    /// One line for the empty state's description and the footer; nil when
    /// the index knows of nothing beyond what the pane lists. An index still
    /// reading owns the line first — neither part can be trusted, so nothing
    /// is placed or counted — then a truncated search: its counts are
    /// floors, so no number is quoted.
    var note: String? {
        if !indexIsComplete {
            return "The search index is still reading this repository — some matches may be missing."
        }
        if isTruncated {
            return "The search stopped at the first \(limit) matches in this repository — narrow it to see more."
        }
        guard elsewhereCount > 0 else { return nil }
        return elsewhereCount == 1
            ? "1 matching item is only in other backups."
            : "\(Format.count(elsewhereCount)) matching items are only in other backups."
    }
}
