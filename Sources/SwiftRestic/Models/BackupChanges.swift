import Foundation

/// A backup's changes against the one before it, as Show Changes Only lists
/// them. Built once when the diff lands, never per render.
struct BackupChanges: Equatable, Sendable {
    /// The counts still cover every change past it.
    static let rowLimit = 20_000

    struct Row: Identifiable, Equatable, Sendable {
        /// Stored: SwiftUI reads it on every diff of the list. Byte-exact
        /// (`PathKey.hex`): two names differing only in Unicode normalization
        /// are two rows.
        let id: String
        /// No trailing slash on a folder.
        let path: String
        let change: ResticDiffChange
    }

    /// By the path's bytes, so a folder's contents sit together.
    let rows: [Row]
    let total: Int
    private let counts: ChangesInside

    init(changes: [PathKey: ResticDiffChange]) {
        total = changes.count
        var counts = ChangesInside()
        for change in changes.values { counts.add(change.category) }
        self.counts = counts
        rows = changes
            .sorted { SnapshotIndex.bytesLess($0.key.path, $1.key.path) }
            .prefix(Self.rowLimit)
            .map { Row(id: $0.key.hex, path: $0.key.path, change: $0.value) }
    }

    /// "12 added, 1 deleted · 410 MB of new data". `dataAdded` is nil for a
    /// backup whose run record is gone. Zero is left out: a run that stored
    /// nothing still has changes.
    func summary(dataAdded: Int64?) -> String {
        var parts = [total == 0 ? "No changes" : counts.summary]
        if let dataAdded, dataAdded > 0 { parts.append("\(Format.bytes(dataAdded)) of new data") }
        if rows.count < total { parts.append("Showing the first \(Format.count(rows.count))") }
        return parts.joined(separator: " · ")
    }
}
