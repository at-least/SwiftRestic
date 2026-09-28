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
    /// DFS ancestry of the last resolved path: key bytes, node id, and
    /// whether this stream created the directory. A child of a directory
    /// created moments ago almost never exists yet, so its insert is tried
    /// before any lookup — but the flag is a hint, not a promise: a repeated
    /// entry, a child listed before its parent, or a delta between chunks
    /// may have created that child already, and the insert then yields to it.
    typealias Walk = [(key: [UInt8], id: Int64, created: Bool)]

    /// The one open full-listing stream.
    ///
    /// `snapID` is the target's `snap.id` when the stream began: AUTOINCREMENT
    /// never reuses it, so a snapshot that died and returned between two
    /// chunks is a different id, and the continuation is refused rather than
    /// finalised over a partial stage. Any throw poisons the stream: later
    /// chunks are dropped and the final is refused until `beginFull` starts
    /// over. The walk caches node ids across transactions, so it is replaced
    /// only after its chunk commits and dropped by anything that may change
    /// node rows — a delta, housekeeping, a throw, the next `beginFull` — and
    /// the whole session ends when its target is set aside as unreadable.
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
    /// are collected before the stage is cleared, since after that nothing
    /// would ever know to.
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
                if try Self.stageOwner(db) != target.id { try Self.discardStage(db) }
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
                        let key = [UInt8](Self.canonical(entry.path).utf8)
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
        guard let window = try Row.fetchOne(db.cachedStatement(sql: SQL.chainByID), arguments: [target.chainID]) else {
            throw IndexError.unknownSnapshot(target.hash)
        }
        let lo: Int64? = window["lo"]
        let hi: Int64? = window["hi"]
        if let lo, let hi {
            if target.seq > hi {
                try requireNoPending(db, target, between: hi, and: target.seq)
                try enqueueIfDead(db, target.chainID, hi)
                try db.cachedStatement(sql: SQL.fullForwardClose).execute(arguments: [hi, target.chainID, target.id])
                try db.cachedStatement(sql: SQL.fullForwardInsert)
                    .execute(arguments: [target.chainID, target.seq, target.id, target.chainID])
                try setWindow(db, target.chainID, lo: lo, hi: target.seq)
            } else if target.seq < lo {
                try requireNoPending(db, target, between: target.seq, and: lo)
                try enqueueIfDead(db, target.chainID, lo)
                try db.cachedStatement(sql: SQL.fullReverseFreeze).execute(arguments: [lo, target.chainID, target.id])
                try db.cachedStatement(sql: SQL.fullReverseInsert)
                    .execute(arguments: [target.chainID, target.seq, target.id, target.chainID])
                try setWindow(db, target.chainID, lo: target.seq, hi: hi)
            } else {
                throw IndexError.notAdjacent(target.hash)
            }
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
    /// `added` holds paths in the target absent from the base and `removed`
    /// the reverse, both in restic diff spelling (a trailing `/` marks a
    /// directory); the base may be older or newer.
    ///
    /// Accepted only when `base` is the alive snapshot at the window end the
    /// target extends (`wrongBase` otherwise) with no pending snapshot
    /// between (`notAdjacent`). Removed paths apply first, because a complete
    /// diff spells a kind change in both lists and the old-kind run must end
    /// before the new one starts. An added path the window end already holds
    /// under the other kind — restic's `T`, which omits both subtrees — is
    /// refused (`kindChanged`) and the snapshot must take the full route.
    /// Idempotent for an already indexed target.
    func ingestDelta(snapshotID: String, from base: String, added: [String], removed: [String]) throws {
        try pool.write { db in
            session?.walk = nil
            guard let target = try Target.fetch(db, snapshotID) else { throw IndexError.unknownSnapshot(snapshotID) }
            guard target.state != State.indexed else { return }
            guard target.state == State.pending else { throw IndexError.unreadable(snapshotID) }
            guard let from = try Target.fetch(db, base) else { throw IndexError.unknownSnapshot(base) }
            guard let window = try Row.fetchOne(db.cachedStatement(sql: SQL.chainByID), arguments: [target.chainID])
            else { throw IndexError.wrongBase(snapshot: snapshotID, from: base) }
            let lo: Int64? = window["lo"]
            let hi: Int64? = window["hi"]
            guard from.state == State.indexed, from.chainID == target.chainID, let lo, let hi
            else { throw IndexError.wrongBase(snapshot: snapshotID, from: base) }

            let forward: Bool
            if target.seq > hi, from.seq == hi {
                forward = true
                try Self.requireNoPending(db, target, between: hi, and: target.seq)
            } else if target.seq < lo, from.seq == lo {
                forward = false
                try Self.requireNoPending(db, target, between: target.seq, and: lo)
            } else {
                throw IndexError.wrongBase(snapshot: snapshotID, from: base)
            }

            let nodes = try NodeWriter(db)
            let close = try db.cachedStatement(sql: forward ? SQL.forwardClose : SQL.reverseFreeze)
            let endRun = try db.cachedStatement(sql: forward ? SQL.forwardOpenRun : SQL.reverseBottomRun)
            let open = try db.cachedStatement(sql: forward ? SQL.forwardInsert : SQL.reverseInsert)
            let end = forward ? hi : lo
            var memo: [[UInt8]: Int64] = [:]
            for path in removed {
                guard let node = try Self.resolve(nodes, Self.canonical(path), create: false, memo: &memo) else { continue }
                try close.execute(arguments: [end, node, target.chainID])
            }
            for path in added {
                let isDirectory = path.utf8.count > 1 && path.utf8.last == UInt8(ascii: "/")
                guard let node = try Self.resolve(nodes, Self.canonical(path), create: true, memo: &memo) else { continue }
                if let kind = try Bool.fetchOne(endRun, arguments: [node, target.chainID]) {
                    // Present at the base already: the same kind is a
                    // file<->symlink `T` and changes nothing; another kind is
                    // a file<->dir change the diff did not spell as removed.
                    if kind == isDirectory { continue }
                    throw IndexError.kindChanged(snapshot: snapshotID, path: path)
                }
                try open.execute(arguments: [node, target.chainID, target.seq, isDirectory])
            }
            try nodes.indexNewNames()
            if forward {
                try Self.setWindow(db, target.chainID, lo: lo, hi: target.seq)
            } else {
                try Self.setWindow(db, target.chainID, lo: target.seq, hi: hi)
            }
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
    /// the stage's nodes that no run holds are collected before the stage
    /// is cleared. Nothing would resume that stream, and the planner reports
    /// done, so no `beginFull` may come to collect them before the app quits
    /// and takes the TEMP stage along — stranding them for good. Another
    /// snapshot's stream is left alone.
    func markUnreadable(snapshotID: String) throws {
        try pool.write { db in
            guard let target = try Target.fetch(db, snapshotID), target.state == State.pending else { return }
            try db.cachedStatement(sql: SQL.snapMarkUnreadable).execute(arguments: [target.id])
            if session?.snapID == target.id { session = nil }
            if try Self.stageOwner(db) == target.id { try Self.discardStage(db) }
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
    /// collected with their FTS rows, then every row goes. Collected before
    /// the clear, since after it nothing would know to. The caller has
    /// dropped the session's walk: collected ids may be reused.
    static func discardStage(_ db: Database) throws {
        let runless = try Int64.fetchAll(db.cachedStatement(sql: SQL.stageRunless))
        try db.cachedStatement(sql: SQL.stageClear).execute()
        try collectNodes(db, runless)
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

    private static var rootWalk: Walk { [([UInt8(ascii: "/")], rootID, false)] }

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

        /// The child node `name` of `parent`, created when missing and
        /// `create` allows. `parentIsNew` skips the lookup and tries the
        /// insert first; when the child exists after all, the insert does
        /// nothing and the lookup finds it — reported as not created, since
        /// children of its own may exist too.
        func child(parent: Int64, name: String, create: Bool, parentIsNew: Bool = false) throws -> (id: Int64, created: Bool)? {
            if !parentIsNew, let id = try Int64.fetchOne(lookup, arguments: [parent, name]) {
                return (id, false)
            }
            guard create else { return nil }
            let insert = try self.insert ?? db.cachedStatement(sql: SQL.nodeInsert)
            if self.insert == nil {
                self.insert = insert
                firstNew = try Int64.fetchOne(db.cachedStatement(sql: SQL.nodeMaxID)) ?? 0
            }
            if let id = try Int64.fetchOne(insert, arguments: [parent, name]) {
                return (id, true)
            }
            guard let id = try Int64.fetchOne(lookup, arguments: [parent, name]) else {
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
    /// yields to a node the stream created itself.
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
        let parentKey: [UInt8] = cut == 0 ? [slash] : Array(bytes[..<cut])
        let name = String(decoding: bytes[(cut + 1)...], as: UTF8.self)
        while let top = walk.last, top.key != parentKey { walk.removeLast() }
        if let top = walk.last {
            return try created(nodes.child(parent: top.id, name: name, create: true, parentIsNew: top.created))
        }
        var fresh: Walk = rootWalk
        var id = rootID
        var isNew = false
        var key: [UInt8] = []
        for component in components(String(decoding: parentKey, as: UTF8.self)) {
            (id, isNew) = try created(nodes.child(parent: id, name: component, create: true, parentIsNew: isNew))
            key += [slash] + Array(component.utf8)
            fresh.append((key, id, isNew))
        }
        walk = fresh
        return try created(nodes.child(parent: id, name: name, create: true, parentIsNew: isNew))
    }

    /// A creating lookup always yields a node; this unwraps it without `!`.
    private static func created(_ result: (id: Int64, created: Bool)?) throws -> (id: Int64, created: Bool) {
        guard let result else { throw DatabaseError(message: "a creating node lookup returned nothing") }
        return result
    }

    /// Resolves a delta path component by component, creating missing nodes
    /// only when asked (added paths); a removed path the index never held
    /// resolves to nil and is skipped.
    private static func resolve(
        _ nodes: NodeWriter,
        _ path: String,
        create: Bool,
        memo: inout [[UInt8]: Int64]
    ) throws -> Int64? {
        var id = rootID
        var key: [UInt8] = []
        var isNew = false
        for component in components(path) {
            key += [UInt8(ascii: "/")] + Array(component.utf8)
            if let known = memo[key] {
                id = known
                continue
            }
            guard let next = try nodes.child(parent: id, name: component, create: create, parentIsNew: isNew) else {
                return nil
            }
            memo[key] = next.id
            (id, isNew) = next
        }
        return id
    }
}
