import Foundation

/// What the Restore pane's search found, split by the backup that is open.
/// The pane lists only the hits the open backup contains; the index already
/// says which other backups hold the rest, and that answer used to be
/// thrown away — leaving "No matches in this backup" a dead end when the
/// file was one backup away.
struct RestorePaneSearch: Equatable, Sendable {
    /// Hits the open backup contains: the rows the pane lists, in index order.
    let inThisBackup: [SearchHit]
    /// Matching paths the index holds only in other backups of the
    /// repository. A path whose every version was pruned counts nowhere:
    /// the index keeps only live snapshots' versions, so it has none.
    let elsewhereCount: Int
    /// The index stopped at its hit ceiling, so both parts may be short.
    let isTruncated: Bool
    let limit: Int
    /// Whether the index had read every backup when the search ran. Until
    /// it has, the open backup may be one it has not read, and its own
    /// files then look as if only other backups held them.
    let indexIsComplete: Bool

    init(hits: [SearchHit], versionsByPath: [String: [IndexedSnapshot]], recordID: String, limit: Int, indexIsComplete: Bool) {
        var inside: [SearchHit] = []
        var elsewhere = 0
        for hit in hits {
            guard let versions = versionsByPath[hit.path], !versions.isEmpty else { continue }
            if versions.contains(where: { $0.id == recordID }) {
                inside.append(hit)
            } else {
                elsewhere += 1
            }
        }
        inThisBackup = inside
        elsewhereCount = elsewhere
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
