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
        return rows.enumerated()
            .sorted { a, b in
                let timeA = a.element.snapshotTime ?? .distantPast
                let timeB = b.element.snapshotTime ?? .distantPast
                return timeA != timeB ? timeA > timeB : a.offset < b.offset
            }
            .map(\.element)
    }
}
