import Foundation
import GRDB

/// The live `IndexStore`: one SQLite file per repository.
///
/// WAL keeps readers (the version queries SwiftUI will drive) off the writer's
/// lock, and `synchronous = NORMAL` trades the last margin of durability for
/// speed — a safe trade only because the index is a rebuildable cache; the
/// repository itself is the truth. The pragma must be set at configuration
/// time: inside a transaction SQLite refuses it, and every GRDB `write` is
/// one.
final class SQLiteIndexStore: IndexStore {
    /// Chunks of paths per SQL statement. SQLite's variable limit is 32 766 on
    /// modern builds but the win from bigger statements is small next to the
    /// risk of tripping it on an older system SQLite.
    private static let chunkSize = 400

    private let db: any DatabaseWriter

    /// - Parameter path: `nil` builds an in-memory store; tests use that, the
    ///   app passes a per-repository file.
    init(path: String?) throws {
        if let path {
            db = try DatabasePool(path: path, configuration: Self.configuration())
        } else {
            db = try DatabaseQueue(configuration: Self.configuration())
        }
        try Self.migrator().migrate(db)
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return configuration
    }

    private static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("index-v1") { db in
            try db.execute(sql: IndexSchema.v1)
        }
        return migrator
    }

    // MARK: - IndexStore

    func reconcile(aliveSnapshots: [Snapshot]) throws -> ReconcileOutcome {
        try db.write { db in
            var seen = Set<String>()
            let alive = aliveSnapshots.filter { seen.insert($0.id).inserted }
            let aliveByID = Dictionary(alive.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            var outcome = ReconcileOutcome()
            var highestSeq: [String: Int] = [:]
            var knownIDs = Set<String>()
            for row in try Row.fetchAll(db, sql: "SELECT id, chain, seq, alive FROM snapshot") {
                let id: String = row["id"]
                knownIDs.insert(id)
                let chain: String = row["chain"]
                let seq: Int = row["seq"]
                highestSeq[chain] = max(highestSeq[chain] ?? 0, seq)
                let wasAlive: Bool = row["alive"]
                if aliveByID[id] != nil {
                    if !wasAlive {
                        try db.execute(sql: "UPDATE snapshot SET alive = 1 WHERE id = ?", arguments: [id])
                        outcome.revived.append(id)
                    }
                } else if wasAlive {
                    // Runs are left in place: revival is free, and the version
                    // queries filter dead snapshots out at read time.
                    try db.execute(sql: "UPDATE snapshot SET alive = 0 WHERE id = ?", arguments: [id])
                    outcome.died.append(id)
                }
            }

            let fresh = alive.filter { !knownIDs.contains($0.id) }
            let grouped = Dictionary(grouping: fresh) {
                IndexChain.chain(id: $0.id, tags: $0.tags)
            }
            for (chain, group) in grouped.sorted(by: { $0.key < $1.key }) {
                var next = (highestSeq[chain] ?? 0) + 1
                for snapshot in group.sorted(by: { ($0.time, $0.id) < ($1.time, $1.id) }) {
                    try db.execute(
                        sql: "INSERT INTO snapshot (id, chain, seq, time, alive, indexed) VALUES (?, ?, ?, ?, 1, 0)",
                        arguments: [snapshot.id, chain, next, snapshot.time]
                    )
                    outcome.added.append(snapshot.id)
                    next += 1
                }
            }
            return outcome
        }
    }

    func recordContent(snapshotID: String, paths: [String], final: Bool) throws {
        try db.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT chain, seq FROM snapshot WHERE id = ?",
                arguments: [snapshotID]
            ) else {
                throw IndexError.unknownSnapshot(snapshotID)
            }
            let chain: String = row["chain"]
            let seq: Int = row["seq"]

            for chunk in paths.chunked(into: Self.chunkSize) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                // The element-wise map matters: a bare `[int, string] + chunk`
                // concatenation degrades to [Any], which none of
                // StatementArguments' sequence initializers accept.
                let chunkArguments = chunk.map { $0 as (any DatabaseValueConvertible)? }
                // A run that ended at seq-1 resumes: the file was there before,
                // and this snapshot proves it is here now.
                try db.execute(
                    sql: """
                    UPDATE entry SET last_seq = ?
                    WHERE chain = ? AND last_seq = ? AND path IN (\(placeholders))
                    """,
                    arguments: StatementArguments([seq, chain, seq - 1] + chunkArguments)
                )
                // A run that starts at seq+1 reaches back: same proof, other
                // side, the case backfill walking newest-first lives in.
                try db.execute(
                    sql: """
                    UPDATE entry SET first_seq = ?
                    WHERE chain = ? AND first_seq = ? AND path IN (\(placeholders))
                    """,
                    arguments: StatementArguments([seq, chain, seq + 1] + chunkArguments)
                )

                // Both extensions fired: two runs now touch seq and must
                // become one. Rare — only when a snapshot between two indexed
                // neighbors is filled in late.
                let seams = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT e1.path AS path, e2.last_seq AS last_seq
                    FROM entry e1 JOIN entry e2
                        ON e1.path = e2.path AND e1.chain = e2.chain
                    WHERE e1.chain = ? AND e1.last_seq = ? AND e2.first_seq = ?
                        AND e1.path IN (\(placeholders))
                    """,
                    arguments: StatementArguments([chain, seq, seq] + chunkArguments)
                )
                for seam in seams {
                    let path: String = seam["path"]
                    let lastSeq: Int = seam["last_seq"]
                    try db.execute(
                        sql: "UPDATE entry SET last_seq = ? WHERE chain = ? AND path = ? AND last_seq = ?",
                        arguments: [lastSeq, chain, path, seq]
                    )
                    try db.execute(
                        sql: "DELETE FROM entry WHERE chain = ? AND path = ? AND first_seq = ?",
                        arguments: [chain, path, seq]
                    )
                }

                // New runs for paths no existing run covers. The gap guard
                // matters: a path whose run ended before seq-1 reappearing now
                // gets a fresh run, because claiming the gap would put the
                // path in snapshots that verifiably lack it. Per-row rather
                // than one bulk VALUES statement: the mixed String/Int
                // argument lists made the one-statement form unreadable, and
                // GRDB's statement cache keeps the loop cheap.
                for path in chunk {
                    try db.execute(
                        sql: """
                        INSERT INTO entry (path, chain, first_seq, last_seq)
                        SELECT ?, ?, ?, ? WHERE NOT EXISTS (
                            SELECT 1 FROM entry
                            WHERE path = ? AND chain = ?
                                AND first_seq <= ? AND last_seq >= ?
                        )
                        """,
                        arguments: [path, chain, seq, seq, path, chain, seq, seq]
                    )
                }
            }

            if final {
                try db.execute(
                    sql: "UPDATE snapshot SET indexed = MAX(indexed, ?) WHERE id = ?",
                    arguments: [IndexCoverage.full.rawValue, snapshotID]
                )
            }
        }
    }

    func applyDelta(snapshotID: String, previousSeq: Int, added: [String], removed: [String]) throws {
        try db.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT chain, seq FROM snapshot WHERE id = ?",
                arguments: [snapshotID]
            ) else {
                throw IndexError.unknownSnapshot(snapshotID)
            }
            let chain: String = row["chain"]
            let seq: Int = row["seq"]

            // restic marks directories in diffs with a trailing slash; the
            // paths this store holds — from `ls` nodes — never carry one.
            // Normalize before matching or a directory's runs never meet.
            func normalized(_ path: String) -> String {
                path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            }
            let removedSet = Set(removed.map(normalized))
            let addedSet = Set(added.map(normalized)).subtracting(removedSet)

            // Extend every run that ended at previousSeq except the changed
            // paths. The exclusion set lives in a temp table so the check is
            // SQLite-side set logic — no candidate path list crosses into
            // memory, whatever the snapshot size. Same-connection guarantee:
            // temp tables live per connection, and one db.write block is one
            // connection.
            try db.execute(sql: "CREATE TEMP TABLE IF NOT EXISTS delta_changed (path TEXT PRIMARY KEY)")
            try db.execute(sql: "DELETE FROM delta_changed")
            for path in addedSet.union(removedSet) {
                try db.execute(sql: "INSERT INTO delta_changed (path) VALUES (?)", arguments: [path])
            }
            try db.execute(
                sql: """
                UPDATE entry SET last_seq = ?
                WHERE chain = ? AND last_seq = ?
                    AND path NOT IN (SELECT path FROM delta_changed)
                """,
                arguments: [seq, chain, previousSeq]
            )

            // Added paths open fresh runs, guarded against claiming a gap:
            // a path whose run ended before previousSeq reappearing now has
            // two episodes, not one long life.
            for path in addedSet {
                try db.execute(
                    sql: """
                    INSERT INTO entry (path, chain, first_seq, last_seq)
                    SELECT ?, ?, ?, ? WHERE NOT EXISTS (
                        SELECT 1 FROM entry
                        WHERE path = ? AND chain = ?
                            AND first_seq <= ? AND last_seq >= ?
                    )
                    """,
                    arguments: [path, chain, seq, seq, path, chain, seq, seq]
                )
            }

            try db.execute(
                sql: "UPDATE snapshot SET indexed = MAX(indexed, ?) WHERE id = ?",
                arguments: [IndexCoverage.delta.rawValue, snapshotID]
            )
        }
    }

    func predecessorForDelta(of snapshotID: String) throws -> IndexedSnapshot? {
        try db.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT chain, seq FROM snapshot WHERE id = ? AND alive = 1 AND indexed = 0",
                arguments: [snapshotID]
            ) else { return nil }
            let chain: String = row["chain"]
            let seq: Int = row["seq"]
            guard let predecessor = try Self.snapshots(
                from: Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, chain, seq, time, alive, indexed FROM snapshot
                    WHERE chain = ? AND alive = 1 AND indexed > 0 AND seq < ?
                    ORDER BY seq DESC LIMIT 1
                    """,
                    arguments: [chain, seq]
                )
            ).first else { return nil }
            // The diff asserts existence across every snapshot it spans, so
            // none of the alive ones in between may go unread: a path deleted
            // in an unread gap snapshot would be claimed present there. A
            // dead snapshot in the gap is fine — nothing queries the dead.
            let unread = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM snapshot
                WHERE chain = ? AND alive = 1 AND indexed = 0 AND seq > ? AND seq < ?
                """,
                arguments: [chain, predecessor.seq, seq]
            )
            return unread == 0 ? predecessor : nil
        }
    }

    func pendingBackfill(limit: Int) throws -> [IndexedSnapshot] {
        try db.read { db in
            try Self.snapshots(
                from: Row.fetchAll(
                    db,
                    sql: "SELECT id, chain, seq, time, alive, indexed FROM snapshot WHERE alive = 1 AND indexed = 0 ORDER BY time DESC, id DESC LIMIT ?",
                    arguments: [limit]
                )
            )
        }
    }

    func versions(ofPath path: String) throws -> [IndexedSnapshot] {
        try db.read { db in
            try Self.snapshots(
                from: Row.fetchAll(
                    db,
                    sql: """
                    SELECT s.id, s.chain, s.seq, s.time, s.alive, s.indexed
                    FROM snapshot s
                    JOIN entry e ON e.chain = s.chain
                        AND s.seq BETWEEN e.first_seq AND e.last_seq
                    WHERE e.path = ? AND s.alive = 1
                    ORDER BY s.time DESC, s.seq DESC
                    """,
                    arguments: [path]
                )
            )
        }
    }

    /// Raw visibility into run storage: how many entry rows a path has in a
    /// chain. The tests assert merge behavior through this — that two
    /// neighbors plus the middle snapshot really collapsed into one run.
    func readEntryCount(ofPath path: String, chain: String) throws -> Int {
        try db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM entry WHERE path = ? AND chain = ?",
                arguments: [path, chain]
            ) ?? 0
        }
    }

    /// Every entry row, ordered — the whole-run-set view the equality test
    /// compares a diff-built index against a from-scratch ls load with.
    func readAllEntries() throws -> [IndexEntryRow] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT path, chain, first_seq, last_seq FROM entry ORDER BY path, chain, first_seq")
                .map { row in
                    IndexEntryRow(
                        path: row["path"],
                        chain: row["chain"],
                        firstSeq: row["first_seq"],
                        lastSeq: row["last_seq"]
                    )
                }
        }
    }

    // MARK: - Row mapping

    private static func snapshots(from rows: [Row]) -> [IndexedSnapshot] {
        rows.map { row in
            IndexedSnapshot(
                id: row["id"],
                chain: row["chain"],
                seq: row["seq"],
                time: row["time"],
                alive: row["alive"],
                coverage: IndexCoverage(rawValue: row["indexed"]) ?? .none
            )
        }
    }
}

private extension Array {
    /// Splits into consecutive chunks of at most `size` — the batch unit the
    /// entry statements are written against.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
