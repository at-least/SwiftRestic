import Foundation

/// One read of an index as Search All Backups' rows.
enum FindResultGrouping {
    /// Rows newest first by `time`, ties keeping arrival order, so equal times never shuffle
    /// between searches.
    fileprivate static func newestFirst<T>(_ rows: [T], time: (T) -> Date?) -> [T] {
        rows.enumerated()
            .sorted { a, b in
                let timeA = time(a.element) ?? .distantPast
                let timeB = time(b.element) ?? .distantPast
                return timeA != timeB ? timeA > timeB : a.offset < b.offset
            }
            .map(\.element)
    }

    struct IndexRow {
        var match: FindMatch
        var snapshotID: String
        var snapshotTime: Date
        var count: Int
        var hit: SearchHit
    }

    /// The rows from one read of the index — FTS over basenames, each hit
    /// read with its summary (the path's newest version and version count,
    /// not its whole list), so every row names a restorable snapshot.
    /// Newest-first by that snapshot. The dropped count comes back beside the
    /// rows, for the caller to set past its cancellation check: a hit
    /// without its summary is not expected — the search keeps only paths an
    /// indexed backup holds, and the summary comes from the same read — but
    /// one that went missing must read as a truncated list, never vanish
    /// silently.
    static func indexRows(hits: [SearchHit], summaries: [PathKey: VersionSummary]) -> (rows: [IndexRow], dropped: Int) {
        var rows: [IndexRow] = []
        var dropped = 0
        for hit in hits {
            guard let summary = summaries[PathKey(hit.path)] else {
                dropped += 1
                continue
            }
            rows.append(IndexRow(
                match: FindMatch(path: hit.path, type: hit.isDirectory ? .dir : .file, size: nil, mtime: nil),
                snapshotID: summary.newest.id,
                snapshotTime: summary.newest.time,
                count: summary.count,
                hit: hit
            ))
        }
        return (newestFirst(rows) { $0.snapshotTime }, dropped)
    }
}

/// One search of every repository's index: the rows of those that answered,
/// newest first, and what could not be covered, so a short list never passes
/// for the whole answer.
struct AllBackupsSearch: Equatable {
    struct Answer {
        enum Outcome {
            case rows([FindResultGrouping.IndexRow], isTruncated: Bool, isComplete: Bool)
            case failed(String)
        }

        var repositoryID: UUID
        var outcome: Outcome
    }

    struct Row: Identifiable, Equatable {
        /// Stored: SwiftUI reads it on every diff of the table. Byte-exact in
        /// the path (`PathKey.hex`): two paths whose names differ only in
        /// Unicode normalization are two rows.
        let id: String
        let repositoryID: UUID
        let path: String
        let name: String
        let isDirectory: Bool
        let snapshotID: String
        let snapshotTime: Date
        /// How many backups of the path's plan hold it.
        let versionsCount: Int
    }

    struct Failure: Equatable {
        var repositoryID: UUID
        var message: String
    }

    var rows: [Row] = []
    var isTruncated = false
    /// Repositories whose index has backups left to read.
    var stillReading: [UUID] = []
    var failures: [Failure] = []

    var isWhole: Bool { stillReading.isEmpty && failures.isEmpty }

    init(_ answers: [Answer]) {
        var merged: [Row] = []
        for answer in answers {
            switch answer.outcome {
            case let .failed(message):
                failures.append(Failure(repositoryID: answer.repositoryID, message: message))
            case let .rows(rows, isTruncated, isComplete):
                if isTruncated { self.isTruncated = true }
                if !isComplete { stillReading.append(answer.repositoryID) }
                merged += rows.map { row in
                    Row(
                        id: "\(answer.repositoryID.uuidString)/\(PathKey(row.match.path).hex)",
                        repositoryID: answer.repositoryID,
                        path: row.match.path,
                        name: row.match.name,
                        isDirectory: row.match.isDirectory,
                        snapshotID: row.snapshotID,
                        snapshotTime: row.snapshotTime,
                        versionsCount: row.count
                    )
                }
            }
        }
        rows = FindResultGrouping.newestFirst(merged) { $0.snapshotTime }
    }
}
