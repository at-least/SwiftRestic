import Foundation
import GRDB

/// Housekeeping: space reclamation, and nothing else.
///
/// Every statement here that writes the index's own tables is a DELETE — of
/// closed runs that claim no indexed snapshot, of content marks with no
/// indexed snapshot left on one side, of a snapshot-less chain's runs, marks
/// and row, of queue rows, and of nodes nothing holds, with their FTS rows
/// through FTS5's delete-by-INSERT and their edits; the only other inserts go to the
/// TEMP scratch list `gc`, which names nodes to consider, never a claim.
/// None writes `snap`, a window or `next_seq`, and a claim is a run joined
/// to an indexed snap row, so housekeeping can remove claims but never add
/// one. That is the property that makes it safe to skip (a crash between
/// reconcile and housekeeping costs space, not answers) and makes its bugs
/// conservative: deleting too much loses a claim, deleting too little leaves
/// garbage that `invariantViolations()` (b) reports.
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
            var queued = false
            /// One housekeeping delete: its fill first queues the nodes of
            /// the runs it is about to remove (the pair shares one
            /// predicate, see `SnapshotIndexSchema.Statements.hkBottomNodes`),
            /// then the delete.
            func reclaim(_ fill: String, _ delete: String, _ arguments: StatementArguments) throws {
                try db.cachedStatement(sql: fill).execute(arguments: arguments)
                // Read right after the fill: `changesCount` is the last
                // statement's.
                if db.changesCount > 0 { queued = true }
                try db.cachedStatement(sql: delete).execute(arguments: arguments)
            }
            /// The content marks with no indexed snapshot left on one side of
            /// them, which split nothing: at or below `upTo`, or above
            /// `above`.
            func dropMarks(upTo: Int64? = nil, above: Int64? = nil, _ chainID: Int64) throws {
                if let upTo {
                    try db.cachedStatement(sql: SQL.hkEditsUpTo).execute(arguments: [chainID, upTo])
                    try db.cachedStatement(sql: SQL.hkBlindsUpTo).execute(arguments: [chainID, upTo])
                }
                if let above {
                    try db.cachedStatement(sql: SQL.hkEditsAbove).execute(arguments: [chainID, above])
                    try db.cachedStatement(sql: SQL.hkBlindsAbove).execute(arguments: [chainID, above])
                }
            }
            for chainID in try Int64.fetchAll(db.cachedStatement(sql: SQL.hkChains)) {
                let seqs = try Int64.fetchAll(db.cachedStatement(sql: SQL.hkSeqs), arguments: [chainID])
                if try Bool.fetchOne(db.cachedStatement(sql: SQL.hkChainHasSnap), arguments: [chainID]) != true {
                    try reclaim(SQL.hkOrphanChainNodes, SQL.hkOrphanChainRuns, [chainID])
                    try dropMarks(upTo: Self.top, chainID)
                    try db.cachedStatement(sql: SQL.hkChainDelete).execute(arguments: [chainID])
                } else {
                    var gaps = Set<Gap>()
                    for seq in seqs {
                        gaps.insert(Gap(
                            below: try Int64.fetchOne(db.cachedStatement(sql: SQL.hkAliveBelow), arguments: [chainID, seq]),
                            above: try Int64.fetchOne(db.cachedStatement(sql: SQL.hkAliveAbove), arguments: [chainID, seq])
                        ))
                    }
                    for gap in gaps {
                        switch (gap.below, gap.above) {
                        case (nil, let above):
                            // Nothing indexed below: every closed run ending
                            // under `above` is a dead fact — every closed run
                            // at all when no indexed snapshot is left — and so
                            // is every content mark up to `above`, whose pair
                            // lost its lower snapshot.
                            try reclaim(SQL.hkBottomNodes, SQL.hkBottom, [chainID, above ?? Self.top])
                            try dropMarks(upTo: above ?? Self.top, chainID)
                        case (let below?, nil):
                            try reclaim(SQL.hkTopNodes, SQL.hkTop, [chainID, below, below])
                            try dropMarks(above: below, chainID)
                        case (let below?, let above?):
                            // The marks inside the gap stay: each still says
                            // the content may differ between `below` and
                            // `above`.
                            try reclaim(SQL.hkGapNodes, SQL.hkGap, [chainID, below, above, below])
                        }
                    }
                }
                try db.cachedStatement(sql: SQL.hkDone).execute(arguments: [chainID])
            }
            if queued { try collectNodes(db) }
        }
    }

    /// Gives every snapshot set aside as unreadable another chance: each
    /// becomes pending again, in place, with a fresh seq above everything
    /// its chain ever used — outside the window, exactly where a new
    /// arrival would land. The coordinator calls this once per process per
    /// repository, from that repository's first reconcile and before that
    /// reconcile's own listing — a snapshot that failed for a reason that
    /// has since gone (a volume unplugged) must not stay out of the index
    /// forever. A reconcile arriving while the release is in flight may land
    /// its listing first; either order leaves a whole index (see
    /// `IndexCoordinator.reconcile`).
    ///
    /// In place rather than deleted for the next reconcile to re-add: the
    /// release and that reconcile are two writes, and a read between them
    /// would find the snapshot neither pending nor set aside — the index
    /// reading complete while a listed snapshot is unread. The old seq is
    /// left with nothing to reclaim: it was never indexed, so no run ends
    /// there. The row keeps its id, so the next reconcile sees a known
    /// snapshot and leaves its row as it is: neither deleted nor added again.
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

    /// Deletes the nodes queued in `temp.gc` that nothing needs — no run, no
    /// child, no stage row, never the root — with their FTS rows, then queues
    /// their parents and goes again, level by level, until a level has
    /// nothing to delete; `gc` is empty when it returns. Callers queue the
    /// first level in SQL — the fill beside each housekeeping delete,
    /// `stageRunlessNodes` — and call this only when a fill queued
    /// something.
    ///
    /// A staged node must survive: were it collected, a new node could take
    /// its rowid and the stale stage row would hand that node a run. For the
    /// same reason this is where node ids go stale, so the open stream's
    /// cached walk — the only holder of node ids across transactions — is
    /// dropped here, whichever write collects, rather than by each caller
    /// remembering to.
    func collectNodes(_ db: Database) throws {
        session?.walk = nil
        let insert = try db.cachedStatement(sql: SQL.gcInsert)
        while true {
            try db.cachedStatement(sql: SQL.gcKeepCollectable).execute()
            // Deduplicated here: a DISTINCT in the statement made the planner
            // walk the whole (parent, name) index.
            let parents = Set(try Int64.fetchAll(db.cachedStatement(sql: SQL.gcParents)))
            try db.cachedStatement(sql: SQL.gcDeleteFTS).execute()
            try db.cachedStatement(sql: SQL.gcDeleteEdits).execute()
            try db.cachedStatement(sql: SQL.gcDeleteNodes).execute()
            try db.cachedStatement(sql: SQL.gcClear).execute()
            guard !parents.isEmpty else { return }
            for id in parents { try insert.execute(arguments: [id]) }
        }
    }
}
