import Foundation
import GRDB

/// Housekeeping: space reclamation, and nothing else.
///
/// Every statement here is a DELETE — of closed runs that claim no indexed
/// snapshot, of a snapshot-less chain's runs and row, of queue rows, and of
/// nodes nothing holds. None writes `snap`, a window or `next_seq`, and a
/// claim is a run joined to an indexed snap row, so housekeeping can remove
/// claims but never add one. That is the property that makes it safe to skip
/// (a crash between reconcile and housekeeping costs space, not answers) and
/// makes its bugs conservative: deleting too much loses a claim, deleting too
/// little leaves garbage that `invariantViolations()` (b) reports.
extension SnapshotIndex {
    /// Where a queued seq sits between the chain's indexed seqs: the nearest
    /// indexed seq below and above it, either possibly absent.
    private struct Gap: Hashable {
        let below: Int64?
        let above: Int64?
    }

    /// Reclaims what the deaths since the last pass stranded, visiting only
    /// the chains and gaps `hk_pending` names — change-sized, whatever the
    /// snapshot count. The coordinator runs it after every applied reconcile;
    /// with an empty queue it costs one probe of an empty table.
    ///
    /// A chain with no snapshot rows left had its whole history forgotten:
    /// its runs and its row go. Otherwise each distinct gap loses the closed
    /// runs lying wholly inside it. TOP runs are never touched here: they
    /// describe `hi` for the next full compare, even after `hi` died. A
    /// BOTTOM run always reaches `lo`, and `first_seq > below ≥ 1` keeps it
    /// out of the gap and top shapes, so BOTTOM runs go only once `lo` died.
    func housekeeping() throws {
        try pool.write { db in
            session?.walk = nil
            var candidates: [Int64] = []
            for chainID in try Int64.fetchAll(db.cachedStatement(sql: SQL.hkChains)) {
                let queued = try Int64.fetchAll(db.cachedStatement(sql: SQL.hkSeqs), arguments: [chainID])
                if try Bool.fetchOne(db.cachedStatement(sql: SQL.hkChainHasSnap), arguments: [chainID]) != true {
                    candidates += try Int64.fetchAll(db.cachedStatement(sql: SQL.hkOrphanChainRuns), arguments: [chainID])
                    try db.cachedStatement(sql: SQL.hkChainDelete).execute(arguments: [chainID])
                } else {
                    var gaps = Set<Gap>()
                    for seq in queued {
                        gaps.insert(Gap(
                            below: try Int64.fetchOne(db.cachedStatement(sql: SQL.hkAliveBelow), arguments: [chainID, seq]),
                            above: try Int64.fetchOne(db.cachedStatement(sql: SQL.hkAliveAbove), arguments: [chainID, seq])
                        ))
                    }
                    for gap in gaps {
                        switch (gap.below, gap.above) {
                        case (nil, nil):
                            // No indexed snapshot left: every closed run is a
                            // dead fact.
                            candidates += try Int64.fetchAll(
                                db.cachedStatement(sql: SQL.hkBottom), arguments: [chainID, Self.top])
                        case (nil, let above?):
                            candidates += try Int64.fetchAll(
                                db.cachedStatement(sql: SQL.hkBottom), arguments: [chainID, above])
                        case (let below?, nil):
                            candidates += try Int64.fetchAll(
                                db.cachedStatement(sql: SQL.hkTop), arguments: [chainID, below, below])
                        case (let below?, let above?):
                            candidates += try Int64.fetchAll(
                                db.cachedStatement(sql: SQL.hkGap), arguments: [chainID, below, above, below])
                        }
                    }
                }
                try db.cachedStatement(sql: SQL.hkDone).execute(arguments: [chainID])
            }
            try Self.collectNodes(db, candidates)
        }
    }

    /// Gives every snapshot set aside as unreadable another chance: each
    /// becomes pending again, in place, with a fresh seq above everything
    /// its chain ever used — outside the window, exactly where a new
    /// arrival would land. The coordinator calls this once per
    /// process per repository, before that repository's first reconcile — a
    /// snapshot that failed for a reason that has since gone (a volume
    /// unplugged) must not stay out of the index forever.
    ///
    /// In place rather than deleted for the next reconcile to re-add: the
    /// release and that reconcile are two writes, and a read between them
    /// would find the snapshot neither pending nor set aside — the index
    /// reading complete while a listed snapshot is unread. The old seq is
    /// left with nothing to reclaim: it was never indexed, so no run ends
    /// there. The row keeps its id, so the next reconcile sees a known
    /// snapshot and reports nothing for it.
    ///
    /// Returns the IDs released. Above the window each is its chain's next
    /// forward step, ahead of every newer backup, so the caller holds them
    /// to a shorter count than a snapshot failing for the first time.
    @discardableResult
    func releaseUnreadable() throws -> [String] {
        try pool.write { db in
            let rows = try Row.fetchAll(db.cachedStatement(sql: SQL.unreadableList))
            let takeSeq = try db.cachedStatement(sql: SQL.chainTakeSeq)
            let repend = try db.cachedStatement(sql: SQL.snapRepend)
            var released: [String] = []
            for row in rows {
                let id: Int64 = row["id"]
                let chainID: Int64 = row["chain_id"]
                guard let seq = try Int64.fetchOne(takeSeq, arguments: [chainID]) else {
                    throw DatabaseError(message: "chain \(chainID) of an unreadable snapshot has no row")
                }
                guard let hash = try String.fetchOne(repend, arguments: [seq, id]) else {
                    throw DatabaseError(message: "unreadable snapshot row \(id) vanished inside its own transaction")
                }
                released.append(hash)
            }
            return released
        }
    }

    /// Deletes the candidate nodes nothing needs — no run, no child, no stage
    /// row — with their FTS rows, then retries their parents, level by level.
    /// A staged node must survive: were it collected, a new node could take
    /// its rowid and the stale stage row would hand that node a run. The
    /// session's cached walk is the only other holder of node ids across
    /// transactions, and every caller drops it first. The root is never a
    /// candidate.
    static func collectNodes(_ db: Database, _ candidates: [Int64]) throws {
        var level = Set(candidates)
        level.remove(rootID)
        let insert = try db.cachedStatement(sql: SQL.gcInsert)
        while !level.isEmpty {
            try db.cachedStatement(sql: SQL.gcClear).execute()
            for id in level { try insert.execute(arguments: [id]) }
            try db.cachedStatement(sql: SQL.gcKeepCollectable).execute()
            // Deduplicated here: a DISTINCT in the statement made the planner
            // walk the whole (parent, name) index.
            let parents = try Int64.fetchAll(db.cachedStatement(sql: SQL.gcParents))
            try db.cachedStatement(sql: SQL.gcDeleteFTS).execute()
            try db.cachedStatement(sql: SQL.gcDeleteNodes).execute()
            level = Set(parents)
            level.remove(rootID)
            level.remove(0)
        }
    }
}
