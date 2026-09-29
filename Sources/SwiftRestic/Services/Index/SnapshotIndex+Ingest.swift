import Foundation
import GRDB

/// Ingest: the full-listing stream, deltas, and the quarantine.
///
/// A snapshot enters the index one window step at a time, by one of two
/// routes. A delta (`restic diff` against the alive window-end snapshot) is
/// accepted only from exactly that base, on the side it extends. Everything
/// else — a chain's first snapshot, a dead window end, a failed diff, a
/// restic `T` line — takes the full route: `beginFull`, the `restic ls`
/// stream in chunks, then a final that compares the staged listing with the
/// sentinel-ended runs. That compare needs only the runs, never the window
/// end's row, so it is exact even when that snapshot has died.
extension SnapshotIndex {
    /// The one open full-listing stream.
    ///
    /// `snapID` is the target's `snap.id` when the stream began: AUTOINCREMENT
    /// never reuses it, so a snapshot that died and returned between two
    /// chunks is a different id, and the continuation is refused rather than
    /// finalised over a partial stage. Any throw poisons the stream: later
    /// chunks are dropped and the final is refused until `beginFull` starts
    /// over. The walk caches node ids across transactions, so it is replaced
    /// only after its chunk commits, and dropped where node ids go stale:
    /// `collectNodes`, the one path that deletes nodes, drops it whichever
    /// write collects; a throw poisons the stream and its walk with it (that
    /// chunk's new ids rolled back); the next `beginFull` replaces the
    /// session. A delta between chunks may give a directory the walk
    /// believes new a child, which the walk's `created` hint tolerates (see
    /// `Walk`), so a delta keeps it. The whole session ends when its target
    /// is set aside as unreadable.
    struct Session {
        let hash: String
        let snapID: Int64
        var poisoned: Bool
        /// The target was already indexed when the stream began: chunks and
        /// the final are no-ops (a repeated read has nothing to teach).
        var done: Bool
        var walk: Walk?
    }

    // MARK: - Full route

    /// Starts the full-listing stream for `snapshotID`, ending any other: one
    /// stream at a time, and the stage belongs to it. The old stage's nodes
    /// that no run holds — a cancelled stream's, or one whose target died —
    /// are queued for collection before the stage is cleared, since after
    /// that nothing would ever know to, and collected in the same
    /// transaction.
    ///
    /// A retry of the same snapshot keeps its stage instead. A snapshot is
    /// immutable and the retry streams it from the top, so what the failed
    /// attempt staged is part of the listing (a repeated row is ignored);
    /// collecting it would delete, in one transaction, the nodes of most of
    /// a first build only for the retry to create them all again. The same
    /// `snap.id` is the same listing: a snapshot that died and returned has
    /// a new one, and its old stage is collected.
    func beginFull(snapshotID: String) throws {
        try pool.writeWithoutTransaction { db in
            session = nil
            var begun: Session?
            try db.inTransaction {
                guard let target = try Target.fetch(db, snapshotID) else {
                    throw IndexError.unknownSnapshot(snapshotID)
                }
                guard target.state != State.unreadable else { throw IndexError.unreadable(snapshotID) }
                if try Self.stageOwner(db) != target.id { try discardStage(db) }
                begun = Session(
                    hash: snapshotID, snapID: target.id, poisoned: false,
                    done: target.state == State.indexed, walk: nil
                )
                return .commit
            }
            session = begun
        }
    }

    /// One chunk of the stream begun by `beginFull`, in one transaction;
    /// `final: true` also applies the whole staged listing in that same
    /// transaction (its entries may be empty).
    ///
    /// Refusals: `noSession` without a stream for this snapshot — applying
    /// an empty stage would read as an empty snapshot and close every run;
    /// `poisonedStream` for the final of a stream that lost a chunk (its
    /// other chunks are dropped silently); and, re-resolving the target each
    /// time, `unknownSnapshot`, `streamIdentityChanged` and `unreadable`.
    func ingestFull(snapshotID: String, entries: [IndexedEntry], final: Bool) throws {
        try pool.writeWithoutTransaction { db in
            guard var active = session, active.hash == snapshotID else {
                throw IndexError.noSession(snapshotID)
            }
            if active.done {
                if final { session = nil }
                return
            }
            if active.poisoned {
                if final { throw IndexError.poisonedStream(snapshotID) }
                return
            }
            do {
                var walk = active.walk ?? Self.rootWalk
                var applied = false
                try db.inTransaction {
                    guard let target = try Target.fetch(db, snapshotID) else {
                        throw IndexError.unknownSnapshot(snapshotID)
                    }
                    guard target.id == active.snapID else { throw IndexError.streamIdentityChanged(snapshotID) }
                    switch target.state {
                    case State.indexed:
                        applied = final
                        return .commit
                    case State.unreadable:
                        throw IndexError.unreadable(snapshotID)
                    default:
                        break
                    }
                    let nodes = try NodeWriter(db)
                    let stage = try db.cachedStatement(sql: SQL.stageInsert)
                    for entry in entries {
                        let key = ResticPath.normalizedBytes(entry.path)
                        let (node, created) = try Self.resolveStreaming(nodes, key, &walk)
                        try stage.execute(arguments: [node, target.id, entry.isDirectory])
                        if entry.isDirectory { walk.append((key, node, created)) }
                    }
                    try nodes.indexNewNames()
                    if final {
                        try Self.applyFull(db, target)
                        applied = true
                    }
                    return .commit
                }
                if applied {
                    session = nil
                } else {
                    active.walk = walk
                    session = active
                }
            } catch {
                // The transaction rolled back, so node ids in the walk may
                // name rows that no longer exist, and the stage misses this
                // chunk for good.
                session = Session(hash: snapshotID, snapID: active.snapID, poisoned: true, done: false, walk: nil)
                throw error
            }
        }
    }

    /// Compares the staged listing with the runs at the window end it
    /// extends. TOP runs describe `hi` and BOTTOM runs `lo` whether or not
    /// that snapshot still lives, so the compare is exact either way; closing
    /// runs at a dead end may leave runs that claim nothing, so that seq is
    /// queued for housekeeping. Inside the window is `notAdjacent`: the
    /// planner never asks for it, because pending snapshots lie outside.
    private static func applyFull(_ db: Database, _ target: Target) throws {
        guard let window = try chainWindow(db, target.chainID) else {
            throw IndexError.unknownSnapshot(target.hash)
        }
        if let lo = window.lo, let hi = window.hi {
            // One step past either end of the window, as a delta extends it;
            // inside it is `notAdjacent`.
            let forward: Bool
            if target.seq > hi {
                forward = true
            } else if target.seq < lo {
                forward = false
            } else {
                throw IndexError.notAdjacent(target.hash)
            }
            let end = forward ? hi : lo
            try requireNoPending(db, target, between: forward ? hi : target.seq, and: forward ? target.seq : lo)
            try enqueueIfDead(db, target.chainID, end)
            try db.cachedStatement(sql: forward ? SQL.fullForwardClose : SQL.fullReverseFreeze)
                .execute(arguments: [end, target.chainID, target.id])
            try db.cachedStatement(sql: forward ? SQL.fullForwardInsert : SQL.fullReverseInsert)
                .execute(arguments: [target.chainID, target.seq, target.id, target.chainID])
            try setWindow(db, target.chainID, lo: forward ? lo : target.seq, hi: forward ? target.seq : hi)
        } else {
            // The chain's first snapshot: every path spans the whole window.
            try db.cachedStatement(sql: SQL.fullFirstInsert).execute(arguments: [target.chainID, target.id])
            try setWindow(db, target.chainID, lo: target.seq, hi: target.seq)
        }
        try markIndexed(db, target)
    }

    private static func enqueueIfDead(_ db: Database, _ chainID: Int64, _ seq: Int64) throws {
        if try String.fetchOne(db.cachedStatement(sql: SQL.windowEnd), arguments: [chainID, seq]) == nil {
            try db.cachedStatement(sql: SQL.hkEnqueue).execute(arguments: [chainID, seq])
        }
    }

    // MARK: - Delta route

    /// Builds `snapshotID` from a diff against `base`, in one transaction.
    /// `added` holds the target's paths absent from the base and `removed`
    /// the reverse, as entries — the form a full read hands over too, which
    /// `IndexedEntry(diffSpelling:)` makes of restic's diff spelling (a
    /// directory's trailing `/` becomes the kind). A removed entry's kind is
    /// not consulted: the run at the window end closes whatever kind it
    /// holds. The base may be older or newer.
    ///
    /// Accepted only when `base` is the alive snapshot at the window end the
    /// target extends (`wrongBase` otherwise) with no pending snapshot
    /// between (`notAdjacent`). Removed paths apply first, because a complete
    /// diff spells a kind change in both lists and the old-kind run must end
    /// before the new one starts. An added path the window end already holds
    /// under the other kind — restic's `T`, which omits both subtrees — is
    /// refused (`kindChanged`) and the snapshot must take the full route.
    /// Idempotent for an already indexed target.
    func ingestDelta(snapshotID: String, from base: String, added: [IndexedEntry], removed: [IndexedEntry]) throws {
        try pool.write { db in
            guard let target = try Target.fetch(db, snapshotID) else { throw IndexError.unknownSnapshot(snapshotID) }
            guard target.state != State.indexed else { return }
            guard target.state == State.pending else { throw IndexError.unreadable(snapshotID) }
            guard let from = try Target.fetch(db, base) else { throw IndexError.unknownSnapshot(base) }
            guard let window = try Self.chainWindow(db, target.chainID),
                  from.state == State.indexed, from.chainID == target.chainID,
                  let lo = window.lo, let hi = window.hi
            else { throw IndexError.wrongBase(snapshot: snapshotID, from: base) }

            let forward: Bool
            if target.seq > hi, from.seq == hi {
                forward = true
            } else if target.seq < lo, from.seq == lo {
                forward = false
            } else {
                throw IndexError.wrongBase(snapshot: snapshotID, from: base)
            }
            try Self.requireNoPending(db, target, between: forward ? hi : target.seq, and: forward ? target.seq : lo)

            let nodes = try NodeWriter(db)
            let close = try db.cachedStatement(sql: forward ? SQL.forwardClose : SQL.reverseFreeze)
            let endRun = try db.cachedStatement(sql: forward ? SQL.forwardOpenRun : SQL.reverseBottomRun)
            let open = try db.cachedStatement(sql: forward ? SQL.forwardInsert : SQL.reverseInsert)
            let end = forward ? hi : lo
            var memo: [[UInt8]: Int64] = [:]
            for entry in removed {
                guard let node = try Self.resolve(nodes, entry.path, create: false, memo: &memo) else { continue }
                try close.execute(arguments: [end, node, target.chainID])
            }
            for entry in added {
                guard let node = try Self.resolve(nodes, entry.path, create: true, memo: &memo) else { continue }
                if let kind = try Bool.fetchOne(endRun, arguments: [node, target.chainID]) {
                    // Present at the base already: the same kind is a
                    // file<->symlink `T` and changes nothing; another kind is
                    // a file<->dir change the diff did not spell as removed.
                    if kind == entry.isDirectory { continue }
                    throw IndexError.kindChanged(snapshot: snapshotID, path: entry.path)
                }
                try open.execute(arguments: [node, target.chainID, target.seq, entry.isDirectory])
            }
            try nodes.indexNewNames()
            try Self.setWindow(db, target.chainID, lo: forward ? lo : target.seq, hi: forward ? target.seq : hi)
            try Self.markIndexed(db, target)
        }
    }

    // MARK: - Quarantine

    /// Sets a pending snapshot aside (state 2) when the backfill cannot read
    /// it. The planner and the adjacency check see only state 0, so the
    /// window moves past it; no read claims it; `isComplete` stays false
    /// while it is listed. It leaves with the listing like any death, or
    /// through `releaseUnreadable` at the next launch, and a return is a new
    /// pending row that is tried again. A no-op for any other state.
    ///
    /// Its stream, if one got that far, ends here: the session goes, and
    /// the stage's nodes that no run holds are queued for collection before
    /// the stage is cleared, then collected. Nothing would resume that
    /// stream, and the planner reports done, so no `beginFull` may come to
    /// collect them before the app quits and takes the TEMP stage along —
    /// stranding them for good. Another snapshot's stream is left alone.
    func markUnreadable(snapshotID: String) throws {
        try pool.write { db in
            guard let target = try Target.fetch(db, snapshotID), target.state == State.pending else { return }
            try db.cachedStatement(sql: SQL.snapMarkUnreadable).execute(arguments: [target.id])
            if session?.snapID == target.id { session = nil }
            if try Self.stageOwner(db) == target.id { try discardStage(db) }
        }
    }

    // MARK: - The stage

    /// The snapshot whose stream the stage holds rows of, if any. It holds
    /// one snapshot's at most — `beginFull` clears it before its session can
    /// stage a row, and only that session stages — so the first row answers
    /// (`invariantViolations()` (j) checks the premise).
    static func stageOwner(_ db: Database) throws -> Int64? {
        try Int64.fetchOne(db.cachedStatement(sql: SQL.stageOwner))
    }

    /// Ends whatever the stage holds: its nodes that no run holds — a
    /// cancelled stream's, one whose target died or was set aside — are
    /// queued for collection before the stage is cleared, since after it
    /// nothing would know to, and collected once the clear has let go of
    /// them. The collection drops the session's walk itself.
    func discardStage(_ db: Database) throws {
        try db.cachedStatement(sql: SQL.stageRunlessNodes).execute()
        // Read right after the fill: `changesCount` is the last statement's.
        let queued = db.changesCount > 0
        try db.cachedStatement(sql: SQL.stageClear).execute()
        if queued { try collectNodes(db) }
    }

    // MARK: - Shared write helpers

    private static func requireNoPending(_ db: Database, _ target: Target, between low: Int64, and high: Int64) throws {
        if try Bool.fetchOne(db.cachedStatement(sql: SQL.pendingBetween), arguments: [target.chainID, low, high]) == true {
            throw IndexError.notAdjacent(target.hash)
        }
    }

    private static func setWindow(_ db: Database, _ chainID: Int64, lo: Int64, hi: Int64) throws {
        try db.cachedStatement(sql: SQL.chainSetWindow).execute(arguments: [lo, hi, chainID])
    }

    /// Marks the target indexed and ends its own stage, if the stage is
    /// its: a full read's, or an abandoned attempt of a snapshot a delta
    /// has now built. Every path staged for it has a run claiming it, so the
    /// clear strands nothing. Another snapshot's stage is left alone, and
    /// only one row of it is read: a delta must cost its own change, not
    /// the size of whatever stream last failed.
    private static func markIndexed(_ db: Database, _ target: Target) throws {
        try db.cachedStatement(sql: SQL.snapMarkIndexed).execute(arguments: [target.id])
        if try stageOwner(db) == target.id {
            try db.cachedStatement(sql: SQL.stageClear).execute()
        }
    }

    // MARK: - Node writes

    /// Node-dictionary writes for one transaction. The FTS rows of every node
    /// it creates are written by one statement at the end (`indexNewNames`),
    /// keyed on the largest id before the first insert.
    final class NodeWriter {
        private let db: Database
        private let lookup: Statement
        private var insert: Statement?
        private var firstNew: Int64?

        init(_ db: Database) throws {
            self.db = db
            lookup = try db.cachedStatement(sql: SQL.nodeLookup)
        }

        /// The existing child `name` of `parent`, or nil: a lookup, never
        /// a write.
        func existing(parent: Int64, name: String) throws -> Int64? {
            try Int64.fetchOne(lookup, arguments: [parent, name])
        }

        /// The child node `name` of `parent`, created when missing.
        /// `parentIsNew` skips the lookup and tries the insert first; when
        /// the child exists after all, the insert does nothing and the
        /// lookup finds it — reported as not created, since children of its
        /// own may exist too.
        func child(parent: Int64, name: String, parentIsNew: Bool) throws -> (id: Int64, created: Bool) {
            if !parentIsNew, let id = try existing(parent: parent, name: name) {
                return (id, false)
            }
            let insert = try self.insert ?? db.cachedStatement(sql: SQL.nodeInsert)
            if self.insert == nil {
                self.insert = insert
                firstNew = try Int64.fetchOne(db.cachedStatement(sql: SQL.nodeMaxID)) ?? 0
            }
            if let id = try Int64.fetchOne(insert, arguments: [parent, name]) {
                return (id, true)
            }
            guard let id = try existing(parent: parent, name: name) else {
                throw DatabaseError(message: "node insert for \(name) yielded to a row the lookup cannot find")
            }
            return (id, false)
        }

        func indexNewNames() throws {
            guard let firstNew else { return }
            try db.cachedStatement(sql: SQL.nodeFTSIndexNew).execute(arguments: [firstNew])
            self.firstNew = nil
            insert = nil
        }
    }

    /// Resolves a path of a full listing through the DFS ancestry `walk`.
    /// `restic ls` is depth-first, so the parent is almost always on the
    /// stack; a parent that is not — a resumed or unordered stream — reseeds
    /// the walk from the root, creating whatever is missing. Order and
    /// repetition cost lookups, never correctness: `NodeWriter.child`
    /// yields to a node the stream created itself. `bytes` is the path as
    /// `ResticPath.normalizedBytes` keys it; the parent's key is a view into
    /// it, compared in place rather than copied for every path.
    private static func resolveStreaming(
        _ nodes: NodeWriter,
        _ bytes: [UInt8],
        _ walk: inout Walk
    ) throws -> (id: Int64, created: Bool) {
        let slash = UInt8(ascii: "/")
        guard bytes != [slash] else { return (rootID, false) }
        guard bytes.first == slash, let cut = bytes.lastIndex(of: slash) else {
            throw DatabaseError(message: "not an absolute path: \(String(decoding: bytes, as: UTF8.self))")
        }
        // A child of the root keeps the leading "/" as its parent's key.
        let parentKey = bytes[..<max(cut, 1)]
        let name = String(decoding: bytes[(cut + 1)...], as: UTF8.self)
        while let top = walk.last, !top.key.elementsEqual(parentKey) { walk.removeLast() }
        if let top = walk.last {
            return try nodes.child(parent: top.id, name: name, parentIsNew: top.created)
        }
        // The parent is not on the stack: the walk starts over from the
        // root, creating whatever is missing. A fresh memo, so each
        // component's `created` comes from this very resolution.
        var scratch: [[UInt8]: Int64] = [:]
        guard let fresh = try descend(String(decoding: parentKey, as: UTF8.self), memo: &scratch, step: {
            try nodes.child(parent: $0, name: $1, parentIsNew: $2)
        }), let parent = fresh.last else {
            throw DatabaseError(message: "a creating walk found no node")
        }
        walk = fresh
        return try nodes.child(parent: parent.id, name: name, parentIsNew: parent.created)
    }

    /// Resolves a delta path through `descend`, creating missing nodes only
    /// when asked (added paths); a removed path the index never held
    /// resolves to nil and is skipped. `components` drops empty components,
    /// so a trailing `/` could not change which node a path names.
    private static func resolve(
        _ nodes: NodeWriter,
        _ path: String,
        create: Bool,
        memo: inout [[UInt8]: Int64]
    ) throws -> Int64? {
        try descend(path, memo: &memo) { parent, name, parentIsNew in
            create
                ? try nodes.child(parent: parent, name: name, parentIsNew: parentIsNew)
                : try nodes.existing(parent: parent, name: name).map { (id: $0, created: false) }
        }?.last?.id
    }
}
