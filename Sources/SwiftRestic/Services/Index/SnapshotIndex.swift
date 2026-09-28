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

/// What one reconcile pass changed.
struct ReconcileOutcome: Sendable, Equatable {
    var added: [String] = []
    var died: [String] = []
    var revived: [String] = []
}

/// One path handed to the index with its kind known — `ls` nodes carry it in
/// `type`, diffs in the trailing slash of directory paths.
struct IndexedEntry: Sendable, Equatable {
    var path: String
    var isDirectory: Bool
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
    var path: String
    var isDirectory: Bool

    /// The path's bytes in hex — never a path, so it cannot collide with
    /// the tree rows' path tags in a list that shares their selection.
    var id: String { PathKey(path).hex }

    static func == (a: SearchHit, b: SearchHit) -> Bool {
        PathKey(a.path) == PathKey(b.path) && a.isDirectory == b.isDirectory
    }
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
            name: IndexPathText.basename(of: path),
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
    /// subtrees. The snapshot must take the full route.
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

/// Path text helpers shared by the index and the cache row types.
enum IndexPathText {
    /// The path's last component, scalar-wise for the same combining-mark
    /// reason `parent(of:)` in the engine is.
    static func basename(of path: String) -> String {
        guard let last = path.unicodeScalars.lastIndex(of: "/") else { return path }
        return String(path.unicodeScalars[last...].dropFirst())
    }
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
/// - housekeeping only deletes, and only rows that claim nothing, so a bug in
///   it can lose a claim or leave garbage but never invent one.
///
/// Concurrency: writes are synchronous and serialized by GRDB's single writer
/// connection, which also owns the TEMP tables `stage`, `gone` and `gc`.
/// The one piece of Swift state, `session`, is read and written only inside
/// writer closures, so the writer's queue serializes it too — hence
/// `@unchecked Sendable`. Reads run async on pool readers, beside the writer.
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
    /// housekeeping and tombstoned for `revived`. Its stage rows, if a stream
    /// was reading it, stay until the next `beginFull` collects them. A new
    /// or returning snapshot becomes pending with a fresh seq: a return is
    /// always read again. Arrivals take their seqs in one pass sorted by
    /// (time, id bytes) across every chain, so `snap.id` grows with arrival
    /// and "equal times, later arrival first" is `ORDER BY time DESC, id DESC`.
    ///
    /// Browse-cache rows naming an ID the listing does not hold are swept in
    /// the same transaction, after the arrivals, so a listing captured for a
    /// snapshot this very listing introduces survives. The first reconcile
    /// of a file also marks it as having applied a listing, which
    /// `isComplete` requires. Idempotent.
    @discardableResult
    func reconcile(listing: [Snapshot]) throws -> ReconcileOutcome {
        var seen = Set<String>()
        let listed = listing.filter { seen.insert($0.id).inserted }
        return try pool.write { db in
            var outcome = ReconcileOutcome()
            var known: [String: (id: Int64, chainID: Int64, seq: Int64)] = [:]
            for row in try Row.fetchAll(db.cachedStatement(sql: SQL.snapAll)) {
                known[row["hash"]] = (row["id"], row["chain_id"], row["seq"])
            }

            let delete = try db.cachedStatement(sql: SQL.snapDelete)
            let enqueue = try db.cachedStatement(sql: SQL.hkEnqueue)
            let tombstone = try db.cachedStatement(sql: SQL.goneInsert)
            for (hash, snap) in known where !seen.contains(hash) {
                try delete.execute(arguments: [snap.id])
                try enqueue.execute(arguments: [snap.chainID, snap.seq])
                try tombstone.execute(arguments: [hash])
                outcome.died.append(hash)
            }

            let arrivals = listed
                .filter { known[$0.id] == nil }
                .map { (snapshot: $0, micros: Self.micros($0.time)) }
                .sorted { a, b in
                    a.micros != b.micros ? a.micros < b.micros : Self.bytesLess(a.snapshot.id, b.snapshot.id)
                }
            var chains: [String: (id: Int64, next: Int64)] = [:]
            let insert = try db.cachedStatement(sql: SQL.snapInsert)
            let untomb = try db.cachedStatement(sql: SQL.goneDelete)
            for (snapshot, micros) in arrivals {
                try untomb.execute(arguments: [snapshot.id])
                if db.changesCount > 0 {
                    outcome.revived.append(snapshot.id)
                } else {
                    outcome.added.append(snapshot.id)
                }
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
            outcome.added.sort(by: Self.bytesLess)
            outcome.died.sort(by: Self.bytesLess)
            outcome.revived.sort(by: Self.bytesLess)
            return outcome
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
    func nextStep(skipping: Set<String> = []) throws -> IndexStep {
        try pool.read { db in
            var best: (rank: Int, time: Int64, hash: String, step: IndexStep)?
            func offer(_ rank: Int, _ time: Int64, _ hash: String, _ step: IndexStep) {
                if let current = best {
                    if rank > current.rank { return }
                    if rank == current.rank {
                        if time < current.time { return }
                        if time == current.time, !Self.bytesLess(current.hash, hash) { return }
                    }
                }
                best = (rank, time, hash, step)
            }
            for chainID in try Int64.fetchAll(db.cachedStatement(sql: SQL.pendingChains)) {
                guard let window = try Row.fetchOne(db.cachedStatement(sql: SQL.chainByID), arguments: [chainID])
                else { continue }
                let lo: Int64? = window["lo"]
                let hi: Int64? = window["hi"]
                guard let lo, let hi else {
                    let pending = try Row.fetchCursor(db.cachedStatement(sql: SQL.pendingDesc), arguments: [chainID])
                    while let row = try pending.next() {
                        let hash: String = row["hash"]
                        guard !skipping.contains(hash) else { continue }
                        offer(0, row["time"], hash, .full(snapshotID: hash))
                        break
                    }
                    continue
                }
                var offeredForward = false
                if let row = try Row.fetchOne(db.cachedStatement(sql: SQL.lowestPendingAbove), arguments: [chainID, hi]) {
                    let hash: String = row["hash"]
                    if !skipping.contains(hash) {
                        let base = try String.fetchOne(db.cachedStatement(sql: SQL.windowEnd), arguments: [chainID, hi])
                        offer(1, row["time"], hash, base.map { .delta(snapshotID: hash, from: $0) } ?? .full(snapshotID: hash))
                        offeredForward = true
                    }
                }
                if !offeredForward,
                   let row = try Row.fetchOne(db.cachedStatement(sql: SQL.highestPendingBelow), arguments: [chainID, lo]) {
                    let hash: String = row["hash"]
                    if !skipping.contains(hash) {
                        let base = try String.fetchOne(db.cachedStatement(sql: SQL.windowEnd), arguments: [chainID, lo])
                        offer(2, row["time"], hash, base.map { .delta(snapshotID: hash, from: $0) } ?? .full(snapshotID: hash))
                    }
                }
            }
            return best?.step ?? .done
        }
    }

    /// Whether the chain of `snapshotID` already has a window — so a `.full`
    /// step for it compares against indexed runs (a dead window end, or the
    /// fallback of a refused delta) rather than building the chain's first
    /// snapshot. The backfill counts those: each is a population-sized read
    /// where a delta would have cost only the change. False for an unknown
    /// snapshot.
    func chainHasWindow(of snapshotID: String) throws -> Bool {
        try pool.read { db in
            guard let target = try Target.fetch(db, snapshotID),
                  let window = try Row.fetchOne(db.cachedStatement(sql: SQL.chainByID), arguments: [target.chainID])
            else { return false }
            let hi: Int64? = window["hi"]
            return hi != nil
        }
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
    /// their own answers.
    func versionSummaries(ofPaths paths: [String]) async throws -> [PathKey: VersionSummary] {
        try await pool.read { db in
            var lookup = try NodeLookup(db)
            let spellings = try lookup.nodes(for: paths)
            let newest = try db.cachedStatement(sql: SQL.summaryNewest)
            var result: [PathKey: VersionSummary] = [:]
            for chunk in Array(spellings.keys).chunked(into: Self.lookupChunk) {
                let sql = SQL.summaryCounts(placeholders: SQL.placeholders(chunk.count))
                for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(chunk)) {
                    let node: Int64 = row[0]
                    let count: Int = row[1]
                    let time: Int64 = row[2]
                    guard let hash = try String.fetchOne(newest, arguments: [node, time]) else { continue }
                    let summary = VersionSummary(count: count, newest: IndexVersion(id: hash, time: Self.date(micros: time)))
                    if let spelling = spellings[node] { result[PathKey(spelling)] = summary }
                }
            }
            return result
        }
    }

    /// Which of `paths` the snapshot holds, each with its kind in *that*
    /// snapshot (true for a directory). `[:]` when the snapshot is not listed
    /// or not indexed: nothing about it is known. Keyed by the bytes asked
    /// for (`PathKey`), as the summaries are.
    func contains(paths: [String], inSnapshot snapshotID: String) async throws -> [PathKey: Bool] {
        try await pool.read { db in
            guard let target = try Target.fetch(db, snapshotID), target.state == State.indexed else { return [:] }
            var lookup = try NodeLookup(db)
            let spellings = try lookup.nodes(for: paths)
            var result: [PathKey: Bool] = [:]
            for chunk in Array(spellings.keys).chunked(into: Self.lookupChunk) {
                let sql = SQL.containsKind(placeholders: SQL.placeholders(chunk.count))
                let arguments = StatementArguments(chunk + [target.chainID, target.seq, target.seq])
                for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
                    let node: Int64 = row[0]
                    let isDirectory: Bool = row[1]
                    if let spelling = spellings[node] { result[PathKey(spelling)] = isDirectory }
                }
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
            let ranked = try hits.map { hit in
                (name: hit.name, path: try Self.path(db, of: hit.node), isDirectory: hit.isDirectory)
            }.sorted { a, b in
                if !a.name.utf8.elementsEqual(b.name.utf8) { return Self.bytesLess(a.name, b.name) }
                return Self.bytesLess(a.path, b.path)
            }
            return ranked.prefix(limit).map { SearchHit(path: $0.path, isDirectory: $0.isDirectory) }
        }
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
    func recordListing(snapshotID: String, directory: String, nodes: [CachedListingNode]) throws {
        let payload = try Self.json(nodes)
        try pool.write { db in
            try db.cachedStatement(sql: SQL.cacheOwnerPut).execute(arguments: [snapshotID])
            try db.cachedStatement(sql: SQL.cacheListingPut)
                .execute(arguments: [snapshotID, ResticService.normalize(directory), payload])
        }
    }

    /// Caches one `restic diff`. Only complete, uncapped walks may feed this:
    /// a capped stream must never present itself as the whole answer.
    func recordDiff(olderID: String, newerID: String, changes: [CachedDiffChange]) throws {
        let payload = try Self.json(changes)
        try pool.write { db in
            let owner = try db.cachedStatement(sql: SQL.cacheOwnerPut)
            try owner.execute(arguments: [olderID])
            try owner.execute(arguments: [newerID])
            try db.cachedStatement(sql: SQL.cacheDiffPut).execute(arguments: [olderID, newerID, payload])
        }
    }

    /// The cached listing, or nil when none was captured. The directory key
    /// is canonicalised here too, so a lookup meets its write whatever
    /// spelling either used.
    func listing(snapshotID: String, directory: String) async throws -> [CachedListingNode]? {
        let key = ResticService.normalize(directory)
        let payload = try await pool.read { db in
            try String.fetchOne(db.cachedStatement(sql: SQL.cacheListingGet), arguments: [snapshotID, key])
        }
        guard let payload else { return nil }
        return try JSONDecoder().decode([CachedListingNode].self, from: Data(payload.utf8))
    }

    /// The cached diff between two snapshots, or nil when none was captured.
    func diff(olderID: String, newerID: String) async throws -> [CachedDiffChange]? {
        let payload = try await pool.read { db in
            try String.fetchOne(db.cachedStatement(sql: SQL.cacheDiffGet), arguments: [olderID, newerID])
        }
        guard let payload else { return nil }
        return try JSONDecoder().decode([CachedDiffChange].self, from: Data(payload.utf8))
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

    /// Read-side path resolution: component by component through
    /// `node.lookup`, never creating anything. Shared prefixes are looked up
    /// once per call.
    struct NodeLookup {
        let statement: Statement
        var memo: [[UInt8]: Int64] = [:]

        init(_ db: Database) throws {
            statement = try db.cachedStatement(sql: SQL.nodeLookup)
        }

        /// The node of an exactly spelled path, or nil (unknown, misspelt, or
        /// the root, which holds no versions).
        mutating func node(for path: String) throws -> Int64? {
            guard SnapshotIndex.isListedSpelling(path) else { return nil }
            var id = SnapshotIndex.rootID
            var key: [UInt8] = []
            for component in SnapshotIndex.components(path) {
                key += [UInt8(ascii: "/")] + Array(component.utf8)
                if let known = memo[key] {
                    id = known
                    continue
                }
                guard let next = try Int64.fetchOne(statement, arguments: [id, component]) else { return nil }
                memo[key] = next
                id = next
            }
            return id == SnapshotIndex.rootID ? nil : id
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

    /// Absolute, no trailing slash, root "/": how writes key a path, whatever
    /// spelling restic's diff used for a directory.
    static func canonical(_ path: String) -> String {
        var bytes = Array(path.utf8)
        while bytes.count > 1, bytes.last == UInt8(ascii: "/") { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func components(_ path: String) -> [String] {
        path.utf8.split(separator: UInt8(ascii: "/")).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Byte order, not Swift's canonical-equivalence order: two names that
    /// differ only in Unicode normalization are two paths to restic.
    static func bytesLess(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    /// Rebuilds a node's path through its parents.
    static func path(_ db: Database, of id: Int64) throws -> String {
        var names: [String] = []
        var current = id
        let byID = try db.cachedStatement(sql: SQL.nodeByID)
        while current != rootID {
            guard let row = try Row.fetchOne(byID, arguments: [current]) else { break }
            names.append(row["name"])
            current = row["parent"]
        }
        return "/" + names.reversed().joined(separator: "/")
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

    /// Every statement the index prepares, by the name FINAL.md's plan table
    /// uses; IN lists at `lookupChunk`. `SnapshotIndexPlanTests` pins each
    /// one's plan, so a statement missing here is a statement nobody pins —
    /// every constant in `SnapshotIndexSchema.SQL` belongs in this list.
    static var registeredStatements: [(name: String, sql: String)] {
        let inList = SQL.placeholders(lookupChunk)
        return [
            ("node.lookup", SQL.nodeLookup),
            ("node.insert", SQL.nodeInsert),
            ("node.maxID", SQL.nodeMaxID),
            ("node.byID", SQL.nodeByID),
            ("node.ftsIndexNew", SQL.nodeFTSIndexNew),
            ("snap.all", SQL.snapAll),
            ("snap.byHash", SQL.snapByHash),
            ("snap.delete", SQL.snapDelete),
            ("snap.insert", SQL.snapInsert),
            ("snap.markIndexed", SQL.snapMarkIndexed),
            ("snap.markUnreadable", SQL.snapMarkUnreadable),
            ("snap.repend", SQL.snapRepend),
            ("chain.insert", SQL.chainInsert),
            ("chain.byKey", SQL.chainByKey),
            ("chain.nextSeq", SQL.chainNextSeq),
            ("chain.takeSeq", SQL.chainTakeSeq),
            ("chain.byID", SQL.chainByID),
            ("chain.setWindow", SQL.chainSetWindow),
            ("gone.insert", SQL.goneInsert),
            ("gone.delete", SQL.goneDelete),
            ("hk.enqueue", SQL.hkEnqueue),
            ("listing.markApplied", SQL.listingMarkApplied),
            ("unreadable.list", SQL.unreadableList),
            ("fwd.close", SQL.forwardClose),
            ("fwd.openRun", SQL.forwardOpenRun),
            ("fwd.insert", SQL.forwardInsert),
            ("rev.freeze", SQL.reverseFreeze),
            ("rev.bottomRun", SQL.reverseBottomRun),
            ("rev.insert", SQL.reverseInsert),
            ("stage.insert", SQL.stageInsert),
            ("stage.clear", SQL.stageClear),
            ("stage.owner", SQL.stageOwner),
            ("stage.runless", SQL.stageRunless),
            ("full.firstInsert", SQL.fullFirstInsert),
            ("full.fwdClose", SQL.fullForwardClose),
            ("full.fwdInsert", SQL.fullForwardInsert),
            ("full.revFreeze", SQL.fullReverseFreeze),
            ("full.revInsert", SQL.fullReverseInsert),
            ("plan.pendingChains", SQL.pendingChains),
            ("plan.pendingDesc", SQL.pendingDesc),
            ("plan.lowestAbove", SQL.lowestPendingAbove),
            ("plan.highestBelow", SQL.highestPendingBelow),
            ("plan.windowEnd", SQL.windowEnd),
            ("plan.pendingBetween", SQL.pendingBetween),
            ("hk.chains", SQL.hkChains),
            ("hk.seqs", SQL.hkSeqs),
            ("hk.done", SQL.hkDone),
            ("hk.chainHasSnap", SQL.hkChainHasSnap),
            ("hk.chainDelete", SQL.hkChainDelete),
            ("hk.aliveBelow", SQL.hkAliveBelow),
            ("hk.aliveAbove", SQL.hkAliveAbove),
            ("hk.bottom", SQL.hkBottom),
            ("hk.gap", SQL.hkGap),
            ("hk.top", SQL.hkTop),
            ("hk.orphanChainRuns", SQL.hkOrphanChainRuns),
            ("gc.clear", SQL.gcClear),
            ("gc.insert", SQL.gcInsert),
            ("gc.keepCollectable", SQL.gcKeepCollectable),
            ("gc.parents", SQL.gcParents),
            ("gc.deleteFTS", SQL.gcDeleteFTS),
            ("gc.deleteNodes", SQL.gcDeleteNodes),
            ("q.versionsTimed", SQL.versionsTimed),
            ("q.versionsInChain", SQL.versionsInChain),
            ("q.summaryCounts", SQL.summaryCounts(placeholders: inList)),
            ("q.summaryNewest", SQL.summaryNewest),
            ("q.containsKind", SQL.containsKind(placeholders: inList)),
            ("q.aliveRuns", SQL.aliveRuns),
            ("q.newestCover", SQL.newestCover),
            ("q.searchFTS", SQL.searchFTS),
            ("q.notComplete", SQL.notComplete),
            ("cache.ownerPut", SQL.cacheOwnerPut),
            ("cache.listingPut", SQL.cacheListingPut),
            ("cache.diffPut", SQL.cacheDiffPut),
            ("cache.listingGet", SQL.cacheListingGet),
            ("cache.diffGet", SQL.cacheDiffGet),
            ("cache.sweepIDs", SQL.cacheSweepIDs),
            ("cache.sweepListing", SQL.cacheSweepListing),
            ("cache.sweepDiffOlder", SQL.cacheSweepDiffOlder),
            ("cache.sweepDiffNewer", SQL.cacheSweepDiffNewer),
            ("cache.sweepOwner", SQL.cacheSweepOwner),
        ]
    }

    /// The stored-state checks of FINAL.md 2.2, each violation a line that
    /// starts with its letter, plus (j), the premise `stageOwner` rests on.
    /// (d)–(j) hold after every write. (a)–(c) —
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
            try count("(i) nodes with no run, child or stage row", """
                SELECT COUNT(*) FROM node n WHERE n.id <> 1
                    AND NOT EXISTS (SELECT 1 FROM run r WHERE r.node_id = n.id)
                    AND NOT EXISTS (SELECT 1 FROM node c WHERE c.parent = n.id)
                    AND NOT EXISTS (SELECT 1 FROM temp.stage g WHERE g.node_id = n.id)
                """)
            try count("(j) snapshots with rows in the stage, when more than one", """
                SELECT CASE WHEN COUNT(DISTINCT snap_id) > 1 THEN COUNT(DISTINCT snap_id) ELSE 0 END FROM temp.stage
                """)
            return out
        }
    }
}

extension Array {
    /// Consecutive slices of at most `size` elements — the IN-list unit.
    fileprivate func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
