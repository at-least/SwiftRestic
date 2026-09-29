import Foundation
import GRDB

/// What the backfill should do next: read a snapshot in full, build it from a
/// `restic diff` against an indexed neighbour, or nothing (every listed
/// snapshot is indexed or set aside). Hashable so the backfill can remember
/// which steps the index already refused this pass.
enum IndexStep: Sendable, Hashable {
    case full(snapshotID: String)
    case delta(snapshotID: String, from: String)
    case done
}

/// A planned step with the planner's reason for a full read. The backfill
/// counts full reads by cause, and only the planner knows the cause as it
/// offers the step: asked afterwards, the store may already have moved on —
/// a reconcile can land between the two reads.
struct PlannedStep: Sendable, Equatable {
    var step: IndexStep
    /// A `.full` step for a chain that already has a window: the snapshot at
    /// the end it extends died, so no delta has a base and a population-sized
    /// read stands in for a change-sized one. False for a chain's first
    /// build, for a delta and for `.done`.
    var deadWindowEnd = false
}

/// One snapshot that holds a path — an element of a version list.
struct IndexVersion: Sendable, Hashable {
    var id: String
    var time: Date
}

/// A path's version list reduced to what Find Files shows: how many indexed
/// snapshots hold it, and the newest of them. Output-light whatever the
/// version count, which is the point.
struct VersionSummary: Sendable, Equatable {
    var count: Int
    var newest: IndexVersion
}

extension Array where Element == IndexVersion {
    /// The version a folder browser opens a path at: the newest — unless the
    /// version the user was reading one level up holds this path too,
    /// because flipping through time should survive walking down into a
    /// folder. The list arrives newest first from the index.
    func preferredVersion(previousID: String?) -> IndexVersion? {
        if let previousID, let kept = first(where: { $0.id == previousID }) {
            return kept
        }
        return first
    }
}

/// One path handed to the index with its kind known — the one form both
/// routes cross into the store in: the path as the index keys it (no
/// trailing `/`), and the kind, from an `ls` node's `type` or from the
/// trailing `/` a diff puts on a directory (`init(diffSpelling:)`).
struct IndexedEntry: Sendable, Equatable {
    var path: String
    var isDirectory: Bool
}

extension IndexedEntry {
    /// A path as `restic diff` spells it: a directory's trailing `/` becomes
    /// the kind, and the path loses it (`ResticPath`, bytewise).
    init(diffSpelling path: String) {
        self.init(path: ResticPath.normalized(path), isDirectory: ResticPath.isDirectorySpelling(path))
    }
}

/// A path as restic spells it, compared and hashed by its UTF-8 bytes.
///
/// Swift's `==` on String is canonical equivalence: the NFC and NFD
/// spellings of one name are one String to Swift and two paths to restic —
/// two nodes in the index, and two files a Linux folder can hold side by
/// side. A dictionary keyed by String keeps one entry for both, so a keyed
/// read would answer one path's question with the other's facts: which
/// backup holds it, of what kind. The keyed reads are keyed by this
/// instead. A string literal is one, so a path spelled inline reads as
/// itself.
struct PathKey: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    let path: String

    init(_ path: String) {
        self.path = path
    }

    init(stringLiteral path: String) {
        self.path = path
    }

    static func == (a: PathKey, b: PathKey) -> Bool {
        a.path.utf8.elementsEqual(b.path.utf8)
    }

    func hash(into hasher: inout Hasher) {
        var bytes = path
        bytes.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        hasher.combine(path.utf8.count)
    }

    var description: String { path }

    /// The bytes in lowercase hex: a String whose `==` is byte equality,
    /// for the places that must hand SwiftUI a String identity or tag.
    var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(path.utf8.count * 2)
        for byte in path.utf8 {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// One search result: a distinct path an indexed snapshot holds, and
/// whether it is a directory. From the index, the kind is the one in the
/// newest indexed snapshot holding the path — a path can change kind over
/// its history. The Restore pane replaces it with the kind in the open
/// backup (`RestorePaneSearch`), since that is the snapshot it restores from.
///
/// Identity and equality are byte-exact (`PathKey`): two hits whose names
/// differ only in Unicode normalization are two paths, two rows and two
/// selections, never one.
struct SearchHit: Sendable, Equatable, Identifiable {
    let path: String
    let isDirectory: Bool
    /// The path's bytes in hex — never a path, so it cannot collide with
    /// the tree rows' path tags in a list that shares their selection.
    /// Stored: SwiftUI reads it on every diff of the list.
    let id: String

    init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
        id = PathKey(path).hex
    }

    static func == (a: SearchHit, b: SearchHit) -> Bool {
        PathKey(a.path) == PathKey(b.path) && a.isDirectory == b.isDirectory
    }
}

/// A search and, from the same read, which of its hits one snapshot holds —
/// the Restore pane's question. One read, not a search and then a lookup:
/// the search knows each hit's node, but a node id means nothing outside
/// the transaction that read it — housekeeping may delete the node and a
/// later ingest reuse its id — and asking again by path text resolves every
/// hit a second time, component by component.
struct SearchWithMembership: Sendable, Equatable {
    /// The search's hits, ordered and limited as `searchPaths` orders and
    /// limits them.
    let hits: [SearchHit]
    /// The hits the snapshot holds, each with its kind in that snapshot
    /// (true for a directory), keyed by the hit's bytes (`PathKey`). `[:]`
    /// when the snapshot is not listed or not indexed: nothing about it is
    /// known, which the caller's completeness check owns.
    let inSnapshot: [PathKey: Bool]
}

/// A search and, from the same read, each hit's version summary — Find
/// Files' rows. One read for the reason `SearchWithMembership` gives. Within
/// it every hit has a summary: the search keeps only paths an indexed
/// snapshot holds, and the summary counts exactly those snapshots.
struct SearchWithSummaries: Sendable, Equatable {
    /// The search's hits, ordered and limited as `searchPaths` orders and
    /// limits them.
    let hits: [SearchHit]
    /// Each hit's summary, keyed by the hit's bytes (`PathKey`).
    let summaries: [PathKey: VersionSummary]
}

/// One node of a cached directory listing — the fields a browser row shows,
/// as `restic ls` reported them. The cache stores these rather than whole
/// `SnapshotNode`s so the JSON carries nothing the UI never reads.
struct CachedListingNode: Sendable, Equatable, Codable {
    var path: String
    var kind: SnapshotNode.Kind
    var size: Int64?
    var mtime: Date?

    init(_ node: SnapshotNode) {
        path = node.path
        kind = node.type
        size = node.size
        mtime = node.mtime
    }

    /// The node form the browser's rows render; the name is re-derived from
    /// the path, which for restic nodes is what it originally decoded from.
    var snapshotNode: SnapshotNode {
        SnapshotNode(
            name: ResticPath.basename(of: path),
            type: kind,
            path: path,
            size: size,
            mtime: mtime
        )
    }
}

/// One cached `restic diff` change row, kept raw — the modifier string is the
/// fact, and the categories derive from it exactly as `ResticDiffChange` does.
struct CachedDiffChange: Sendable, Equatable, Codable {
    var path: String
    var modifier: String

    init(_ change: ResticDiffChange) {
        path = change.path
        modifier = change.modifier
    }

    var resticDiffChange: ResticDiffChange {
        ResticDiffChange(path: path, modifier: modifier)
    }
}

/// Errors the index layer raises on its own behalf. Every case up to
/// `schemaMismatch` is a refusal that leaves the index exactly as it was
/// (the write's transaction rolled back).
enum IndexError: Error, Equatable {
    /// A write named a snapshot the index does not list (never reconciled,
    /// or gone from the latest listing).
    case unknownSnapshot(String)
    /// The ingest does not extend its chain's window by one step: a pending
    /// snapshot lies between, or the target sits inside the window.
    case notAdjacent(String)
    /// A delta whose base is not the alive window-end snapshot on the side
    /// the target extends.
    case wrongBase(snapshot: String, from: String)
    /// A delta that changes a path between file and directory without
    /// listing the old kind as removed — restic's `T` line, which omits both
    /// subtrees. The snapshot must take the full route. `path` is spelled
    /// as the index keys it, without restic's trailing `/`.
    case kindChanged(snapshot: String, path: String)
    /// The snapshot was set aside by `markUnreadable`.
    case unreadable(String)
    /// A chunk whose snapshot row is no longer the one its stream began on:
    /// it left the listing, and perhaps returned as a new row.
    case streamIdentityChanged(String)
    /// A chunk of this stream failed earlier; read it again from the top.
    case poisonedStream(String)
    /// A chunk or final with no stream begun for its snapshot.
    case noSession(String)
    /// The file holds another schema (`found` is its `user_version`). The
    /// index is a cache: the owner deletes the file and opens it afresh.
    case schemaMismatch(found: Int32)
    /// The repository was removed; its index was deleted with it and no new
    /// one may be opened, however late the caller arrived.
    case repositoryRemoved
}

/// One repository's snapshot index: which snapshots hold a path — the
/// question restic cannot answer — plus the browse caches.
///
/// The model (the SQL is in `SnapshotIndexSchema`). Snapshots group into
/// chains: a plan's tag, else restic's own host-plus-paths lineage. Each
/// snapshot gets a per-chain `seq` on arrival that is never reused. A chain's
/// indexed snapshots form one contiguous window `[lo, hi]` of seqs, and a run
/// `(node, chain, first_seq, last_seq, is_dir)` claims the path for every
/// indexed snapshot of the chain in that closed interval. The window grows one
/// adjacent step at a time — a delta from the alive snapshot at the end it
/// extends, or a full `restic ls` compared with the runs that describe that
/// end — so a steady-state backup writes only its own changes. A snapshot
/// that leaves the listing loses its row: runs over its seq then claim nothing
/// there, and deaths write no runs at all.
///
/// The invariants every write keeps (FINAL.md 2.2, checked by
/// `invariantViolations()`):
/// - seqs are never reused (`next_seq` only grows); `snap.id` is
///   AUTOINCREMENT, so a snapshot that dies and returns is a new row — the
///   stream identity and the equal-time arrival tiebreak both rest on it;
/// - pending snapshots lie outside their chain's window, indexed ones inside;
///   `lo`/`hi` move only on ingest;
/// - the runs ending at TOP describe `hi` even after `hi` died, and the runs
///   starting at BOTTOM describe `lo` while it lives — which is what makes a
///   full compare exact at a dead window end;
/// - runs of one path in one chain never overlap;
/// - every read requires `state = 1`;
/// - housekeeping writes only deletions — of rows that claim nothing, and,
///   through FTS5's delete-by-INSERT, of their FTS rows — plus the node ids
///   it queues in the TEMP scratch list `gc`, so a bug in it can lose a
///   claim or leave garbage but never invent one.
///
/// Concurrency: every write is serialized by GRDB's single writer
/// connection — the browse-cache captures await it, the rest block on it —
/// which also owns the TEMP tables `stage` and `gc`.
/// The two pieces of Swift state, `session` and `appliedGeneration`, are
/// read and written only inside writer closures, so the writer's queue
/// serializes them too — hence `@unchecked Sendable`. Reads run async on
/// pool readers, beside the writer.
final class SnapshotIndex: @unchecked Sendable {
    /// 2, not 1: development builds wrote this schema as 1 before
    /// `listing_applied` existed, and such a file must be rebuilt rather
    /// than read without the table.
    static let schemaVersion: Int32 = 2
    /// Node ids per batched read: under SQLite's pre-3.32 variable limit of
    /// 999, whatever the system library.
    static let lookupChunk = 400
    /// BackfillBuffer's chunk: the largest transaction a full read commits.
    static let chunkSize = 4_000
    /// `last_seq` sentinel "through hi"; `first_seq` `bottom` is "from lo".
    /// Real seqs start at 1, so neither sentinel is ever a snapshot's seq.
    static let top: Int64 = 2_147_483_647
    static let bottom: Int64 = 0
    /// The node for "/" (parent 0). Never searchable, never collected.
    static let rootID: Int64 = 1

    /// `snap.state` values.
    enum State {
        static let pending: Int64 = 0
        static let indexed: Int64 = 1
        /// Set aside by `markUnreadable`: passed over by the planner, claimed
        /// by no read, and counted by `isComplete`.
        static let unreadable: Int64 = 2
    }

    typealias SQL = SnapshotIndexSchema.SQL

    /// Internal only so the extensions in the sibling files reach it; nothing
    /// outside `SnapshotIndex*.swift` touches GRDB.
    let pool: DatabasePool
    /// The one open full-listing stream. Touched only inside writer closures
    /// (see the type's comment); the ingest file owns its rules.
    var session: Session?
    /// The generation of the newest listing `reconcile(listing:generation:)`
    /// took; nil until the first. Touched only inside writer closures. In
    /// memory by design: a new object — the next launch, or the fresh file
    /// a reset leaves — has taken nothing, so it accepts whatever listing
    /// comes first, a rebuild's re-sent one included.
    private var appliedGeneration: UInt64?

    // MARK: - Opening

    /// Opens (or creates) the file at `path`. A file with any other schema —
    /// including an empty `user_version` over existing tables, which is what
    /// the older index format looks like — throws `schemaMismatch` with the
    /// pool already closed, so the owner can delete the file and open again.
    init(path: String) throws {
        let pool = try DatabasePool(path: path, configuration: Self.configuration())
        do {
            let (version, objects) = try pool.read { db in
                (
                    try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? 0,
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_schema") ?? 0
                )
            }
            switch (version, objects) {
            case (0, 0):
                try pool.write { try $0.execute(sql: SnapshotIndexSchema.create) }
            case (Self.schemaVersion, _):
                break
            default:
                throw IndexError.schemaMismatch(found: version)
            }
            try pool.writeWithoutTransaction { try $0.execute(sql: SnapshotIndexSchema.temporary) }
        } catch {
            try? pool.close()
            throw error
        }
        self.pool = pool
    }

    /// WAL (a `DatabasePool`) lets the reads run beside the writer, and
    /// `synchronous = NORMAL` trades the last margin of durability for speed
    /// — safe only because the index is a rebuildable cache. The pragmas must
    /// be set at configuration time: inside a transaction SQLite refuses
    /// them. Nothing here ever ANALYZEs, and the plan tests open files with
    /// this configuration so a future pragma that did would trip their
    /// `sqlite_stat1` assertion.
    static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            // The largest transaction is one chunk or one delta, but a
            // checkpoint can still leave a fat -wal behind; this caps how far
            // past the checkpoint it may stay.
            try db.execute(sql: "PRAGMA journal_size_limit = 33554432")
        }
        return configuration
    }

    /// Closes every connection. For reset and drop only: the files may be
    /// deleted afterwards, and any later call on this object throws.
    func close() throws {
        try pool.close()
    }

    // MARK: - Reconcile

    /// Aligns the snapshot table with a complete `restic snapshots` listing.
    ///
    /// A snapshot no longer listed loses its row — its seq is never reused,
    /// so runs over it simply claim nothing there — and is queued for
    /// housekeeping. Its stage rows, if a stream was reading it, stay until
    /// the next `beginFull` collects them. A new or returning snapshot
    /// becomes pending with a fresh seq: a return is always read again, so
    /// nothing needs to tell the two apart. Arrivals take their seqs in one
    /// pass sorted by (time, id bytes) across every chain, so `snap.id`
    /// grows with arrival and "equal times, later arrival first" is
    /// `ORDER BY time DESC, id DESC`.
    ///
    /// Browse-cache rows naming an ID the listing does not hold are swept in
    /// the same transaction, after the arrivals, so a listing captured for a
    /// snapshot this very listing introduces survives. The first reconcile
    /// of a file also marks it as having applied a listing, which
    /// `isComplete` requires. Idempotent: a listing already applied writes
    /// nothing.
    ///
    /// `generation` numbers the listing by when it was read; the
    /// coordinator always passes one, and a listing without one (the tests'
    /// direct writes) is applied unconditionally and leaves the number
    /// alone. A numbered listing not newer than the last one this store
    /// took answers false, with nothing written. The compare and the write
    /// share one writer turn, the one place the writes are ordered: callers
    /// that compared first and wrote after could each pass the compare and
    /// reach the writer in the other order — an older listing applied last.
    /// The number is taken before the statements run, so it stays taken when
    /// they fail: an older listing is no better a retry than the next
    /// refresh. A write that fails before its closure runs — at `BEGIN` —
    /// takes no number, so an older listing may still land after it;
    /// nothing newer did.
    @discardableResult
    func reconcile(listing: [Snapshot], generation: UInt64? = nil) throws -> Bool {
        var seen = Set<String>()
        let listed = listing.filter { seen.insert($0.id).inserted }
        return try pool.write { db in
            if let generation {
                if let applied = appliedGeneration, generation <= applied { return false }
                appliedGeneration = generation
            }
            var known: [String: (id: Int64, chainID: Int64, seq: Int64)] = [:]
            for row in try Row.fetchAll(db.cachedStatement(sql: SQL.snapAll)) {
                known[row["hash"]] = (row["id"], row["chain_id"], row["seq"])
            }

            let delete = try db.cachedStatement(sql: SQL.snapDelete)
            let enqueue = try db.cachedStatement(sql: SQL.hkEnqueue)
            for (hash, snap) in known where !seen.contains(hash) {
                try delete.execute(arguments: [snap.id])
                try enqueue.execute(arguments: [snap.chainID, snap.seq])
            }

            let arrivals = listed
                .filter { known[$0.id] == nil }
                .map { (snapshot: $0, micros: Self.micros($0.time)) }
                .sorted { a, b in
                    a.micros != b.micros ? a.micros < b.micros : Self.bytesLess(a.snapshot.id, b.snapshot.id)
                }
            var chains: [String: (id: Int64, next: Int64)] = [:]
            let insert = try db.cachedStatement(sql: SQL.snapInsert)
            for (snapshot, micros) in arrivals {
                let key = Self.chainKey(for: snapshot)
                if chains[key] == nil {
                    try db.cachedStatement(sql: SQL.chainInsert).execute(arguments: [key])
                    guard let chain = try Row.fetchOne(db.cachedStatement(sql: SQL.chainByKey), arguments: [key]) else {
                        throw DatabaseError(message: "chain row for \(key) vanished inside its own transaction")
                    }
                    chains[key] = (chain["id"], chain["next_seq"])
                }
                guard let chain = chains[key] else { continue }
                try insert.execute(arguments: [snapshot.id, chain.id, chain.next, micros])
                chains[key] = (chain.id, chain.next + 1)
            }
            for chain in chains.values {
                try db.cachedStatement(sql: SQL.chainNextSeq).execute(arguments: [chain.next, chain.id])
            }

            try db.cachedStatement(sql: SQL.listingMarkApplied).execute()
            try Self.sweepCaches(db)
            return true
        }
    }

    /// The run-grouping key. A plan's snapshots share its tag; any other
    /// snapshot chains by restic's own default grouping, host plus sorted
    /// paths, so consecutive untagged backups of one source cost a delta
    /// each rather than a full read. Answers never depend on the grouping —
    /// only what a step costs does.
    ///
    /// The lineage fields are written as a JSON array of strings: a
    /// separator byte cannot collide with a path, and NUL — the obvious
    /// separator — is where GRDB's text binding stops reading, which would
    /// fold every untagged snapshot of every host into one chain.
    static func chainKey(for snapshot: Snapshot) -> String {
        if let tag = snapshot.tags.first(where: { $0.hasPrefix(ResticService.planTagPrefix) }) {
            return tag
        }
        let fields = [snapshot.hostname ?? ""] + snapshot.paths.sorted(by: bytesLess)
        return "lineage:[" + fields.map(jsonString).joined(separator: ",") + "]"
    }

    /// A JSON string literal, escaped by hand so the key's bytes never depend
    /// on an encoder's formatting choices across OS releases.
    private static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: - Planner

    /// The next backfill step, read-only on a pool reader.
    ///
    /// Per chain with pending snapshots: a chain with no window offers a full
    /// read of its newest pending snapshot (class 0); otherwise the lowest
    /// pending seq above `hi` (class 1, forward), else the highest below `lo`
    /// (class 2, reverse) — as a delta from the window end when that
    /// snapshot is alive, and as a full compare when it died. The best offer
    /// wins by class, then newest time, then greatest id bytes: every
    /// chain's first build before anything else, then new backups, then
    /// history newest to oldest.
    ///
    /// `skipping` holds the snapshots the caller gave up on for this pass. A
    /// skipped forward candidate removes the chain's forward step — the
    /// window cannot jump over a snapshot — but not its reverse one.
    ///
    /// The answer carries the planner's reason for a full read of a chain
    /// that already has a window (`PlannedStep.deadWindowEnd`), known here
    /// as the step is chosen.
    func plannedStep(skipping: Set<String> = []) throws -> PlannedStep {
        try pool.read { db in
            var best: (rank: Int, time: Int64, hash: String, planned: PlannedStep)?
            func offer(_ rank: Int, _ time: Int64, _ hash: String, _ planned: PlannedStep) {
                if let current = best {
                    if rank > current.rank { return }
                    if rank == current.rank {
                        if time < current.time { return }
                        if time == current.time, !Self.bytesLess(current.hash, hash) { return }
                    }
                }
                best = (rank, time, hash, planned)
            }
            for chainID in try Int64.fetchAll(db.cachedStatement(sql: SQL.pendingChains)) {
                guard let window = try Self.chainWindow(db, chainID) else { continue }
                guard let lo = window.lo, let hi = window.hi else {
                    let pending = try Row.fetchCursor(db.cachedStatement(sql: SQL.pendingDesc), arguments: [chainID])
                    while let row = try pending.next() {
                        let hash: String = row["hash"]
                        guard !skipping.contains(hash) else { continue }
                        offer(0, row["time"], hash, PlannedStep(step: .full(snapshotID: hash)))
                        break
                    }
                    continue
                }
                // Forward first: the lowest pending seq above hi (class 1),
                // else the highest below lo (class 2). Only an offer ends the
                // search: a skipped forward candidate removes the chain's
                // forward step — the window cannot jump over it — but lets its
                // reverse one through.
                for (rank, candidate, end) in [(1, SQL.lowestPendingAbove, hi), (2, SQL.highestPendingBelow, lo)] {
                    guard let row = try Row.fetchOne(db.cachedStatement(sql: candidate), arguments: [chainID, end])
                    else { continue }
                    let hash: String = row["hash"]
                    guard !skipping.contains(hash) else { continue }
                    let base = try String.fetchOne(db.cachedStatement(sql: SQL.windowEnd), arguments: [chainID, end])
                    offer(rank, row["time"], hash, Self.extending(hash, from: base))
                    break
                }
            }
            return best?.planned ?? PlannedStep(step: .done)
        }
    }

    /// `plannedStep`'s step alone — what the tests' planner loops drive.
    func nextStep(skipping: Set<String> = []) throws -> IndexStep {
        try plannedStep(skipping: skipping).step
    }

    /// A step past one end of a window: a delta from the end's snapshot
    /// while it lives, else a full compare against the runs that describe
    /// the dead end.
    private static func extending(_ hash: String, from base: String?) -> PlannedStep {
        guard let base else { return PlannedStep(step: .full(snapshotID: hash), deadWindowEnd: true) }
        return PlannedStep(step: .delta(snapshotID: hash, from: base))
    }

    // MARK: - Reads

    /// The indexed snapshots holding `path`, newest first; equal times put
    /// the later arrival first. Only the exact spelling `restic ls` emits
    /// resolves (absolute, no `//`, no trailing `/`); anything else is an
    /// unknown path and answers `[]`.
    func versions(ofPath path: String) async throws -> [IndexVersion] {
        try await pool.read { db in
            var lookup = try NodeLookup(db)
            guard let node = try lookup.node(for: path) else { return [] }
            return try Row.fetchAll(db.cachedStatement(sql: SQL.versionsTimed), arguments: [node])
                .map(Self.version(from:))
        }
    }

    /// `versions(ofPath:)` restricted to one chain — Browse Folders' plan
    /// filter, in SQL. An unknown chain key answers `[]`.
    func versions(ofPath path: String, inChain chainKey: String) async throws -> [IndexVersion] {
        try await pool.read { db in
            var lookup = try NodeLookup(db)
            guard let node = try lookup.node(for: path) else { return [] }
            return try Row.fetchAll(db.cachedStatement(sql: SQL.versionsInChain), arguments: [node, chainKey])
                .map(Self.version(from:))
        }
    }

    /// Per path: how many indexed snapshots hold it and the newest of them —
    /// `count == versions(ofPath:).count` and `newest == .first`, without
    /// materialising a list that can run to thousands of versions. Unknown
    /// paths, and paths with no indexed version, are absent. Keyed by the
    /// bytes asked for (`PathKey`), so canonically equal spellings keep
    /// their own answers. Find Files reads the summaries inside its search
    /// (`searchWithSummaries`); this path-keyed form is what the tests hold
    /// that read to, as `versions(ofPath:)` is for the folder browser.
    func versionSummaries(ofPaths paths: [String]) async throws -> [PathKey: VersionSummary] {
        try await pool.read { db in
            var lookup = try NodeLookup(db)
            let spellings = try lookup.nodes(for: paths)
            var result: [PathKey: VersionSummary] = [:]
            for (node, summary) in try Self.summaries(db, of: Array(spellings.keys)) {
                if let spelling = spellings[node] { result[PathKey(spelling)] = summary }
            }
            return result
        }
    }

    /// Which of `paths` the snapshot holds, each with its kind in *that*
    /// snapshot (true for a directory). `[:]` when the snapshot is not listed
    /// or not indexed: nothing about it is known. Keyed by the bytes asked
    /// for (`PathKey`), as the summaries are. The Restore pane reads the
    /// membership inside its search (`searchWithMembership`); this
    /// path-keyed form is what the tests hold that read to.
    func contains(paths: [String], inSnapshot snapshotID: String) async throws -> [PathKey: Bool] {
        try await pool.read { db in
            guard let target = try Target.fetch(db, snapshotID), target.state == State.indexed else { return [:] }
            var lookup = try NodeLookup(db)
            let spellings = try lookup.nodes(for: paths)
            var result: [PathKey: Bool] = [:]
            for (node, isDirectory) in try Self.kinds(db, of: Array(spellings.keys), in: target) {
                if let spelling = spellings[node] { result[PathKey(spelling)] = isDirectory }
            }
            return result
        }
    }

    /// Basename search across every indexed path, `ORDER BY name, path`
    /// bytewise, at most `limit` hits. The MATCH cursor runs in name order
    /// and a candidate counts only if one of its runs covers an indexed
    /// snapshot, so paths no listed snapshot holds never use up the limit.
    /// After `limit` hits the walk keeps reading only names equal to the last
    /// hit's, so ties are cut by path, not by rowid. A hit's kind is its kind
    /// in the newest indexed snapshot holding it.
    func searchPaths(matching query: String, limit: Int) async throws -> [SearchHit] {
        let match = Self.ftsQuery(from: query)
        guard !match.isEmpty, limit > 0 else { return [] }
        return try await pool.read { db in
            try Self.search(db, match: match, limit: limit).map(\.hit)
        }
    }

    /// `searchPaths`, plus which hits `snapshotID` holds and with what kind
    /// there — the Restore pane's split of a search by the open backup, in
    /// the same read, keyed by the node ids the search already has.
    func searchWithMembership(
        matching query: String,
        limit: Int,
        inSnapshot snapshotID: String
    ) async throws -> SearchWithMembership {
        let match = Self.ftsQuery(from: query)
        guard !match.isEmpty, limit > 0 else { return SearchWithMembership(hits: [], inSnapshot: [:]) }
        return try await pool.read { db in
            let target = try Target.fetch(db, snapshotID)
            let found = try Self.search(db, match: match, limit: limit)
            var inSnapshot: [PathKey: Bool] = [:]
            if let target, target.state == State.indexed {
                let kinds = try Self.kinds(db, of: found.map(\.node), in: target)
                for (node, hit) in found {
                    if let isDirectory = kinds[node] { inSnapshot[PathKey(hit.path)] = isDirectory }
                }
            }
            return SearchWithMembership(hits: found.map(\.hit), inSnapshot: inSnapshot)
        }
    }

    /// `searchPaths`, plus each hit's version summary — Find Files' rows —
    /// in the same read, keyed by the node ids the search already has.
    func searchWithSummaries(matching query: String, limit: Int) async throws -> SearchWithSummaries {
        let match = Self.ftsQuery(from: query)
        guard !match.isEmpty, limit > 0 else { return SearchWithSummaries(hits: [], summaries: [:]) }
        return try await pool.read { db in
            let found = try Self.search(db, match: match, limit: limit)
            let byNode = try Self.summaries(db, of: found.map(\.node))
            var summaries: [PathKey: VersionSummary] = [:]
            for (node, hit) in found {
                if let summary = byNode[node] { summaries[PathKey(hit.path)] = summary }
            }
            return SearchWithSummaries(hits: found.map(\.hit), summaries: summaries)
        }
    }

    /// Each node's summary — how many indexed snapshots hold it, and the
    /// newest — for the nodes that have any, `lookupChunk` ids per
    /// statement. Node ids come from the caller's own transaction, `db`.
    ///
    /// Two statements, the counts per chunk and then the newest hash at
    /// each node's newest time, rather than one with window functions
    /// (`count(*) OVER` and `row_number()` by node): that form answered the
    /// same, ties included, but measured about three times slower on SQLite
    /// 3.51.0 and 3.43.2 alike, because it sorts every version of the chunk.
    private static func summaries(_ db: Database, of nodes: [Int64]) throws -> [Int64: VersionSummary] {
        let newest = try db.cachedStatement(sql: SQL.summaryNewest)
        var result: [Int64: VersionSummary] = [:]
        for chunk in nodes.chunked(into: lookupChunk) {
            let sql = SQL.summaryCounts(placeholders: SQL.placeholders(chunk.count))
            for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(chunk)) {
                let node: Int64 = row[0]
                let count: Int = row[1]
                let time: Int64 = row[2]
                guard let hash = try String.fetchOne(newest, arguments: [node, time]) else { continue }
                result[node] = VersionSummary(count: count, newest: IndexVersion(id: hash, time: date(micros: time)))
            }
        }
        return result
    }

    /// Each node's kind in `target` (true for a directory), for the nodes it
    /// holds, `lookupChunk` ids per statement. `target` must be indexed — a
    /// run claims nothing for a snapshot outside its chain's window — and
    /// the node ids must come from the caller's own transaction, `db`.
    private static func kinds(_ db: Database, of nodes: [Int64], in target: Target) throws -> [Int64: Bool] {
        var result: [Int64: Bool] = [:]
        for chunk in nodes.chunked(into: lookupChunk) {
            let sql = SQL.containsKind(placeholders: SQL.placeholders(chunk.count))
            let arguments = StatementArguments(chunk + [target.chainID, target.seq, target.seq])
            for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
                let node: Int64 = row[0]
                let isDirectory: Bool = row[1]
                result[node] = isDirectory
            }
        }
        return result
    }

    /// The search `searchPaths` describes, inside the caller's read: each
    /// hit with its node id, which the caller may use only within this same
    /// transaction (see `SearchWithMembership`).
    private static func search(_ db: Database, match: String, limit: Int) throws -> [(node: Int64, hit: SearchHit)] {
        let aliveRuns = try db.cachedStatement(sql: SQL.aliveRuns)
        let newestCover = try db.cachedStatement(sql: SQL.newestCover)
        var hits: [(name: String, node: Int64, isDirectory: Bool)] = []
        var boundary: String?
        let cursor = try Row.fetchCursor(db.cachedStatement(sql: SQL.searchFTS), arguments: [match])
        while let row = try cursor.next() {
            let node: Int64 = row[0]
            let name: String = row[1]
            if let boundary, !name.utf8.elementsEqual(boundary.utf8) { break }
            guard node != Self.rootID else { continue }
            let runs = try Row.fetchAll(aliveRuns, arguments: [node])
            guard let firstRun = runs.first else { continue }
            var isDirectory: Bool = firstRun["is_dir"]
            if runs.contains(where: { ($0["is_dir"] as Bool) != isDirectory }) {
                // The path changed kind somewhere in its history: the
                // newest indexed snapshot holding it decides.
                var newest: (time: Int64, arrival: Int64)?
                for run in runs {
                    guard let cover = try Row.fetchOne(
                        newestCover, arguments: [run["chain_id"], run["first_seq"], run["last_seq"]]
                    ) else { continue }
                    let time: Int64 = cover["time"]
                    let arrival: Int64 = cover["id"]
                    if let current = newest, current.time > time || (current.time == time && current.arrival > arrival) {
                        continue
                    }
                    newest = (time, arrival)
                    isDirectory = run["is_dir"]
                }
            }
            hits.append((name, node, isDirectory))
            if hits.count == limit { boundary = name }
        }
        var paths: [Int64: String] = [:]
        let ranked = try hits.map { hit in
            (name: hit.name, node: hit.node, path: try Self.path(db, of: hit.node, memo: &paths), isDirectory: hit.isDirectory)
        }.sorted { a, b in
            if !a.name.utf8.elementsEqual(b.name.utf8) { return Self.bytesLess(a.name, b.name) }
            return Self.bytesLess(a.path, b.path)
        }
        return ranked.prefix(limit).map { (node: $0.node, hit: SearchHit(path: $0.path, isDirectory: $0.isDirectory)) }
    }

    /// True when a listing has been applied and every listed snapshot is
    /// indexed: none pending, none set aside as unreadable. The consumers'
    /// "the index answers exactly" flag. A file no listing has reached — a
    /// repository never refreshed, a rebuild whose reconcile has not landed
    /// — has read nothing, so it is not complete, though nothing is pending;
    /// an applied empty listing is.
    func isComplete() async throws -> Bool {
        try await pool.read { db in
            try Bool.fetchOne(db.cachedStatement(sql: SQL.notComplete)) == false
        }
    }

    // MARK: - Browse caches

    /// Caches one directory's `restic ls` answer. A snapshot is immutable, so
    /// a repeated capture is the same content and the first write stands. An
    /// empty directory is cached too — the explicit `[]` is what makes its
    /// re-expansion free. IDs never reconciled are accepted (a browse that
    /// raced a forget); the next reconcile sweeps them.
    func recordListing(snapshotID: String, directory: String, nodes: [CachedListingNode]) async throws {
        let payload = try Self.json(nodes)
        try await pool.write { db in
            try db.cachedStatement(sql: SQL.cacheOwnerPut).execute(arguments: [snapshotID])
            try db.cachedStatement(sql: SQL.cacheListingPut)
                .execute(arguments: [snapshotID, ResticPath.normalized(directory), payload])
        }
    }

    /// Caches one `restic diff`. Only complete, uncapped walks may feed this:
    /// a capped stream must never present itself as the whole answer.
    func recordDiff(olderID: String, newerID: String, changes: [CachedDiffChange]) async throws {
        let payload = try Self.json(changes)
        try await pool.write { db in
            let owner = try db.cachedStatement(sql: SQL.cacheOwnerPut)
            try owner.execute(arguments: [olderID])
            try owner.execute(arguments: [newerID])
            try db.cachedStatement(sql: SQL.cacheDiffPut).execute(arguments: [olderID, newerID, payload])
        }
    }

    /// The cached listing, or nil when none was captured. The directory key
    /// is normalized here too (`ResticPath.normalized`, as `recordListing`
    /// keys it), so a lookup meets its write whatever spelling either used.
    func listing(snapshotID: String, directory: String) async throws -> [CachedListingNode]? {
        try await cached(SQL.cacheListingGet, [snapshotID, ResticPath.normalized(directory)])
    }

    /// The cached diff between two snapshots, or nil when none was captured.
    func diff(olderID: String, newerID: String) async throws -> [CachedDiffChange]? {
        try await cached(SQL.cacheDiffGet, [olderID, newerID])
    }

    /// The payload one cache row holds, decoded; nil when there is no row.
    private func cached<T: Decodable>(_ sql: String, _ key: [String]) async throws -> T? {
        let payload = try await pool.read { db in
            try String.fetchOne(db.cachedStatement(sql: sql), arguments: StatementArguments(key))
        }
        guard let payload else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(payload.utf8))
    }

    /// Deletes every cache row of an ID with no snap row. Keyed through
    /// `cache_owner`, so its cost follows the number of cached snapshots,
    /// not the number of cached directories.
    private static func sweepCaches(_ db: Database) throws {
        let gone = try String.fetchAll(db.cachedStatement(sql: SQL.cacheSweepIDs))
        for id in gone {
            try db.cachedStatement(sql: SQL.cacheSweepListing).execute(arguments: [id])
            try db.cachedStatement(sql: SQL.cacheSweepDiffOlder).execute(arguments: [id])
            try db.cachedStatement(sql: SQL.cacheSweepDiffNewer).execute(arguments: [id])
            try db.cachedStatement(sql: SQL.cacheSweepOwner).execute(arguments: [id])
        }
    }

    /// The payload as TEXT: the cache columns are STRICT `TEXT`, which
    /// refuses the BLOB a bare `Data` binds as.
    private static func json(_ value: some Encodable) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    // MARK: - Shared helpers

    /// One `snap` row, as every write and snapshot-scoped read sees it.
    struct Target {
        var id: Int64
        var hash: String
        var chainID: Int64
        var seq: Int64
        var state: Int64

        static func fetch(_ db: Database, _ hash: String) throws -> Target? {
            guard let row = try Row.fetchOne(db.cachedStatement(sql: SQL.snapByHash), arguments: [hash]) else {
                return nil
            }
            return Target(id: row["id"], hash: hash, chainID: row["chain_id"], seq: row["seq"], state: row["state"])
        }
    }

    /// Read-side path resolution: `descend` with `nodeLookup` as its step,
    /// never creating anything — the only statement this holds, so a read
    /// cannot prepare a write. Shared prefixes are looked up once per call.
    struct NodeLookup {
        let statement: Statement
        var memo: [[UInt8]: Int64] = [:]

        init(_ db: Database) throws {
            statement = try db.cachedStatement(sql: SQL.nodeLookup)
        }

        /// The node of an exactly spelled path, or nil (unknown, misspelt, or
        /// the root, which holds no versions). The spelling guard is the read
        /// side's own: a read answers only the spelling `restic ls` emits,
        /// while a write resolves whatever path it is handed by its
        /// components, which skip an empty one.
        mutating func node(for path: String) throws -> Int64? {
            guard SnapshotIndex.isListedSpelling(path) else { return nil }
            // A local, so the step captures the statement and not `self`,
            // whose `memo` the walk holds inout.
            let lookup = statement
            let node = try SnapshotIndex.descend(path, memo: &memo) { parent, name, _ in
                try Int64.fetchOne(lookup, arguments: [parent, name]).map { (id: $0, created: false) }
            }?.last?.id
            return node == SnapshotIndex.rootID ? nil : node
        }

        /// The node of each resolvable path, mapped back to the spelling
        /// asked for. Paths are deduplicated by their bytes, not by Swift's
        /// `==`, which is canonical equivalence: the NFC and NFD spellings
        /// of a name are one String and two paths to restic, and only one of
        /// them may name a node. Lookups compare bytes, so no node has two
        /// spellings.
        mutating func nodes(for paths: [String]) throws -> [Int64: String] {
            var spellings: [Int64: String] = [:]
            var seen = Set<[UInt8]>()
            for path in paths where seen.insert(Array(path.utf8)).inserted {
                guard let node = try node(for: path) else { continue }
                spellings[node] = path
            }
            return spellings
        }
    }

    /// The spelling `restic ls` emits: absolute, no empty component, no
    /// trailing slash. Reads accept only this, which pins exact-text lookup.
    static func isListedSpelling(_ path: String) -> Bool {
        let slash = UInt8(ascii: "/")
        var previous: UInt8?
        for byte in path.utf8 {
            if byte == slash, previous == slash { return false }
            previous = byte
        }
        return path.utf8.first == slash && previous != slash
    }

    static func components(_ path: String) -> [String] {
        path.utf8.split(separator: UInt8(ascii: "/")).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A resolved path, component by component from the root: each prefix's
    /// key bytes ("/", "/a", "/a/b"), its node, and whether the transaction
    /// resolving it created the node. `descend` returns one; a full
    /// listing's stream keeps one across chunks as its DFS ancestry (the
    /// session's walk). A child of a directory created moments ago almost
    /// never exists yet, so its insert is tried before any lookup — but the
    /// flag is a hint, not a promise: a repeated entry, a child listed before
    /// its parent, or a delta between chunks may have created that child
    /// already, and the insert then yields to it.
    typealias Walk = [(key: [UInt8], id: Int64, created: Bool)]

    /// The walk of "/": the root, which nothing creates.
    static var rootWalk: Walk { [([UInt8(ascii: "/")], rootID, false)] }

    /// The one component walk behind every path resolution — reads, a
    /// delta's paths, a streamed listing's reseed. From the root, each
    /// component resolves through `step(parent, name, parentCreated)`; a nil
    /// step — a read or a removal meeting a path the index never held — ends
    /// the walk with nil. The walk holds no statement of its own, so what it
    /// may do is exactly what `step` does: on a pool reader, a read-only
    /// connection, the step is a lookup and nothing here can write.
    ///
    /// Every resolved prefix is memoized by its key bytes, so paths sharing a
    /// prefix resolve it once per memo. A prefix is memoized only after its
    /// parent was, so in any one path the memo's hits all come before its
    /// misses, and a hit reports `created` false: a creation is a hint for
    /// the step right after it, never recalled from an earlier path.
    ///
    /// Returns the trail, root first: `.last` is the path's node.
    static func descend(
        _ path: String,
        memo: inout [[UInt8]: Int64],
        step: (_ parent: Int64, _ name: String, _ parentCreated: Bool) throws -> (id: Int64, created: Bool)?
    ) rethrows -> Walk? {
        var trail = rootWalk
        var key: [UInt8] = []
        var parent: (id: Int64, created: Bool) = (rootID, false)
        for component in components(path) {
            key += [UInt8(ascii: "/")] + Array(component.utf8)
            if let known = memo[key] {
                parent = (known, false)
            } else {
                guard let next = try step(parent.id, component, parent.created) else { return nil }
                memo[key] = next.id
                parent = next
            }
            trail.append((key, parent.id, parent.created))
        }
        return trail
    }

    /// Byte order, not Swift's canonical-equivalence order: two names that
    /// differ only in Unicode normalization are two paths to restic.
    static func bytesLess(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    /// Rebuilds a node's path through its parents. `memo` keeps every path
    /// built on the way, so nodes sharing ancestors read each one once.
    static func path(_ db: Database, of id: Int64, memo: inout [Int64: String]) throws -> String {
        var climbed: [(node: Int64, name: String)] = []
        var prefix = ""
        var current = id
        let byID = try db.cachedStatement(sql: SQL.nodeByID)
        while current != rootID {
            if let known = memo[current] {
                prefix = known
                break
            }
            guard let row = try Row.fetchOne(byID, arguments: [current]) else { break }
            climbed.append((current, row["name"]))
            current = row["parent"]
        }
        var path = prefix
        for (node, name) in climbed.reversed() {
            path += "/" + name
            memo[node] = path
        }
        return path.isEmpty ? "/" : path
    }

    /// A chain's window `[lo, hi]`, both nil while nothing of it is indexed;
    /// nil for a chain with no row.
    static func chainWindow(_ db: Database, _ chainID: Int64) throws -> (lo: Int64?, hi: Int64?)? {
        guard let row = try Row.fetchOne(db.cachedStatement(sql: SQL.chainByID), arguments: [chainID]) else {
            return nil
        }
        return (row["lo"], row["hi"])
    }

    /// Snapshot time as stored: integer microseconds, compared numerically.
    static func micros(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }

    static func date(micros: Int64) -> Date {
        Date(timeIntervalSince1970: Double(micros) / 1_000_000)
    }

    private static func version(from row: Row) -> IndexVersion {
        IndexVersion(id: row[0], time: date(micros: row[1]))
    }

    /// User text to an FTS5 MATCH expression: every whitespace-separated
    /// token becomes a quoted prefix term, so "inv 2026" finds basenames with
    /// tokens starting with both, and metacharacters the user typed travel
    /// inside the quotes instead of being parsed as syntax. No tokens, no
    /// query — which the caller reads as "match nothing".
    static func ftsQuery(from input: String) -> String {
        input.split(whereSeparator: \.isWhitespace)
            .map { token in
                token
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    .replacingOccurrences(of: "\"", with: "\"\"")
            }
            // A token that was nothing but quotes carries no term; emitting
            // it would make the whole query a zero-token phrase.
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"*" }
            .joined(separator: " ")
    }

    // MARK: - Test support

    /// Every statement the index prepares — the open-time schema probe, the
    /// connection pragmas and the test-support invariant checks aside —
    /// under its property name in `SnapshotIndexSchema.Statements`, IN lists
    /// at `lookupChunk`. Read by
    /// reflection, so declaring a statement is registering it:
    /// `SnapshotIndexPlanTests` pins each one's plan and fails on a
    /// statement without a rule, on a rule without a statement, and on a
    /// stored property the reader cannot take for a statement.
    static var registeredStatements: [(name: String, sql: String)] {
        reflectStatements(SQL.statements, inList: SQL.placeholders(lookupChunk)).statements
    }

    /// `value`'s stored properties, in declaration order, as statements: a
    /// `String` as it is, an `InList` applied to `inList`. Any other stored
    /// property lands in `others` under its name — never silently dropped,
    /// which would leave a statement unpinned; the plan tests require it
    /// empty.
    static func reflectStatements(
        _ value: Any, inList: String
    ) -> (statements: [(name: String, sql: String)], others: [String]) {
        var statements: [(name: String, sql: String)] = []
        var others: [String] = []
        for child in Mirror(reflecting: value).children {
            let name = child.label ?? "(unlabelled)"
            if let sql = child.value as? String {
                statements.append((name, sql))
            } else if let inListStatement = child.value as? SnapshotIndexSchema.InList {
                statements.append((name, inListStatement(placeholders: inList)))
            } else {
                others.append(name)
            }
        }
        return (statements, others)
    }

    /// The stored-state checks of FINAL.md 2.2, each violation a line that
    /// starts with its letter, plus (j), the premise `stageOwner` rests on,
    /// and (k), that every collection leaves `temp.gc` empty, so the next
    /// one starts from exactly what its own write queued. (d)–(k) hold after
    /// every write. (a)–(c) —
    /// the queue is empty, no closed run claims nothing, no chain is left
    /// without snapshots — hold only right after `housekeeping()`, which is
    /// what establishes them; callers filter by letter. (i) has one allowed
    /// exception the store cannot see: the nodes of a stream that was open
    /// when its connection went away (a crash or a reopen), which nothing
    /// collects. Runs on the writer, because `stage` lives there.
    func invariantViolations() throws -> [String] {
        try pool.write { db in
            var out: [String] = []
            func count(_ label: String, _ sql: String) throws {
                let n = try Int.fetchOne(db, sql: sql) ?? 0
                if n != 0 { out.append("\(label): \(n)") }
            }
            try count("(a) hk_pending rows", "SELECT COUNT(*) FROM hk_pending")
            try count("(b) closed runs claiming no indexed snapshot", """
                SELECT COUNT(*) FROM run r WHERE r.last_seq < 2147483647 AND NOT EXISTS (
                    SELECT 1 FROM snap s WHERE s.chain_id = r.chain_id AND s.state = 1
                        AND s.seq BETWEEN r.first_seq AND r.last_seq)
                """)
            try count("(c) chains without snapshots", """
                SELECT COUNT(*) FROM chain c WHERE NOT EXISTS (SELECT 1 FROM snap s WHERE s.chain_id = c.id)
                """)
            try count("(d) overlapping or inverted runs of one (node, chain)", """
                SELECT (SELECT COUNT(*) FROM run WHERE first_seq > last_seq)
                    + (SELECT COUNT(*) FROM run a JOIN run b ON a.node_id = b.node_id AND a.chain_id = b.chain_id
                        AND a.first_seq < b.first_seq AND b.first_seq <= a.last_seq)
                """)
            try count("(e) nodes with a self or missing parent", """
                SELECT COUNT(*) FROM node n WHERE n.id <> 1
                    AND (n.parent = n.id OR NOT EXISTS (SELECT 1 FROM node p WHERE p.id = n.parent))
                """)
            try count("(f) pending snapshots inside their chain's window", """
                SELECT COUNT(*) FROM snap s JOIN chain c ON c.id = s.chain_id
                WHERE s.state = 0 AND c.lo IS NOT NULL AND s.seq BETWEEN c.lo AND c.hi
                """)
            try count("(g) runs outside a windowed chain, or snapshots of a missing chain", """
                SELECT (SELECT COUNT(*) FROM run r WHERE NOT EXISTS (
                        SELECT 1 FROM chain c WHERE c.id = r.chain_id AND c.lo IS NOT NULL))
                    + (SELECT COUNT(*) FROM snap s WHERE NOT EXISTS (SELECT 1 FROM chain c WHERE c.id = s.chain_id))
                """)
            // The root has no FTS row by design, and FTS5's content check
            // fails on exactly that, so the check runs with the root's row
            // added inside a savepoint that is rolled back.
            do {
                try db.inSavepoint {
                    try db.execute(sql: "INSERT INTO node_fts (rowid, name) VALUES (1, '')")
                    try db.execute(sql: "INSERT INTO node_fts (node_fts, rank) VALUES ('integrity-check', 1)")
                    return .rollback
                }
            } catch {
                out.append("(h) FTS integrity-check failed: \(error)")
            }
            try count("(i) nodes with no run, child or stage row", "SELECT COUNT(*) " + Self.strandedNodes)
            try count("(j) snapshots with rows in the stage, when more than one", """
                SELECT CASE WHEN COUNT(DISTINCT snap_id) > 1 THEN COUNT(DISTINCT snap_id) ELSE 0 END FROM temp.stage
                """)
            try count("(k) node ids left queued in temp.gc", "SELECT COUNT(*) FROM temp.gc")
            return out
        }
    }

    /// Invariant (i)'s nodes, as a FROM clause over `node n`: no run, no
    /// child, no stage row. The tests list them by path from the same text.
    static let strandedNodes = """
        FROM node n WHERE n.id <> 1
            AND NOT EXISTS (SELECT 1 FROM run r WHERE r.node_id = n.id)
            AND NOT EXISTS (SELECT 1 FROM node c WHERE c.parent = n.id)
            AND NOT EXISTS (SELECT 1 FROM temp.stage g WHERE g.node_id = n.id)
        """
}

extension Array {
    /// Consecutive slices of at most `size` elements — the IN-list unit, and
    /// the property test's random chunking of a streamed listing.
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
