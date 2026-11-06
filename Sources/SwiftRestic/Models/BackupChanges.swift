import Foundation

/// A backup's changes against the one before it, as a flat list: what Show
/// Changes Only lists. Built once when the diff lands, never per render.
struct BackupChanges: Equatable, Sendable {
    /// Past this the list stops; the counts still cover every change. A
    /// million-row SwiftUI list is not an answer anyone reads.
    static let rowLimit = 20_000

    struct Row: Identifiable, Equatable, Sendable {
        /// Stored: SwiftUI reads it on every diff of the list. Byte-exact
        /// (`PathKey.hex`): two names differing only in Unicode normalization
        /// are two rows.
        let id: String
        /// Normalized, as a tree row's: no trailing slash on a folder.
        let path: String
        let change: ResticDiffChange
    }

    /// By path's bytes, so a folder's contents sit together; cut at `rowLimit`.
    let rows: [Row]
    let total: Int
    private let counts: ChangesInside

    init(changes: [PathKey: ResticDiffChange]) {
        total = changes.count
        var counts = ChangesInside()
        for change in changes.values { counts.add(change.category) }
        self.counts = counts
        rows = changes
            .sorted { $0.key.path.utf8.lexicographicallyPrecedes($1.key.path.utf8) }
            .prefix(Self.rowLimit)
            .map { Row(id: $0.key.hex, path: $0.key.path, change: $0.value) }
    }

    /// "12 added, 1 deleted · 410 MB of new data". `dataAdded` is the run's
    /// own, nil for a backup whose run record is gone. Zero says nothing: a
    /// run that stored nothing still has changes.
    func summary(dataAdded: Int64?) -> String {
        var parts = [total == 0 ? "No changes" : counts.summary]
        if let dataAdded, dataAdded > 0 { parts.append("\(Format.bytes(dataAdded)) of new data") }
        if rows.count < total { parts.append("Showing the first \(Format.count(rows.count))") }
        return parts.joined(separator: " · ")
    }
}
