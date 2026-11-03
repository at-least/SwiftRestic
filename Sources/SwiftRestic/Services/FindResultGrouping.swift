import Foundation

/// `restic find`'s answer, one result per backup, as Find Files' rows: one
/// per path — the index engine's shape, so a row reads the same whichever
/// engine answered and a common name does not flood the list with a row
/// per backup. Each row is the path at the newest backup that holds it,
/// with how many of the searched backups of that backup's chain do — the
/// count the Files tab the row opens lists.
enum FindResultGrouping {
    struct PathRow {
        var match: FindMatch
        var snapshotID: String
        var snapshotTime: Date?
        var count: Int
    }

    /// Newest first; paths at one backup keep restic's order, and a
    /// backup the listing does not know sorts last. A path whose backups'
    /// times are all unknown — a search run before the listing loaded —
    /// stays at the first that holds it, the newest: restic 0.19.1's
    /// `find` answers newest backup first.
    ///
    /// `chain` names a backup's chain — the page whose Files tab lists it;
    /// the backups the listing does not know count as one.
    static func rows<Chain: Hashable>(
        _ results: [FindResult],
        times: [String: Date],
        chain: (String) -> Chain
    ) -> [PathRow] {
        var rows: [PathRow] = []
        var index: [PathKey: Int] = [:]
        var counts: [PathKey: [Chain: Int]] = [:]
        for result in results {
            let time = times[result.snapshot]
            let resultChain = chain(result.snapshot)
            for match in result.matches {
                let key = PathKey(match.path)
                counts[key, default: [:]][resultChain, default: 0] += 1
                guard let at = index[key] else {
                    index[key] = rows.count
                    rows.append(PathRow(match: match, snapshotID: result.snapshot, snapshotTime: time, count: 0))
                    continue
                }
                if (time ?? .distantPast) > (rows[at].snapshotTime ?? .distantPast) {
                    rows[at].match = match
                    rows[at].snapshotID = result.snapshot
                    rows[at].snapshotTime = time
                }
            }
        }
        for at in rows.indices {
            rows[at].count = counts[PathKey(rows[at].match.path)]![chain(rows[at].snapshotID)]!
        }
        return newestFirst(rows) { $0.snapshotTime }
    }

    /// Rows newest first by `time`, ties keeping arrival order — both
    /// engines' row order, so equal times never shuffle between searches.
    static func newestFirst<T>(_ rows: [T], time: (T) -> Date?) -> [T] {
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
        var snapshotTime: Date?
        var count: Int
        var hit: SearchHit
    }

    /// The index engine's rows from one read of the index — FTS over
    /// basenames, each hit read with its summary (the path's newest version
    /// and version count, not its whole list), so every row names a
    /// restorable snapshot. Newest-first by that snapshot, matching the
    /// restic engine's row order. The dropped count comes back beside the
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
