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

struct IndexVersion: Sendable, Hashable, Identifiable {
    var id: String
    var time: Date
}

/// One hit of a search within a chain (`search(matching:inChain:limit:)`),
/// the Backups tab's ⌘F results, or one entry directly under a folder
/// somewhere in the chain's indexed history (`children(ofPath:inChain:)`).
struct IndexChild: Sendable, Equatable {
    var path: String
    /// The kind in `newest`: a path can change kind over its history.
    var isDirectory: Bool
    var newest: IndexVersion
    /// Whether the chain's newest indexed snapshot holds it — false for an
    /// item a later backup no longer had: deleted, moved, or excluded since.
    var isInNewest: Bool
}

/// One content of a path in a chain: the indexed snapshots holding it with
/// nothing to say it changed between them — a row of the Backups tab's
/// version list, where a file backed up daily for a year and edited twice
/// is three versions, not 365.
struct ContentVersion: Sendable, Equatable, Identifiable {
    enum Since: Sendable, Equatable {
        /// A `restic diff` between two of their snapshots said the content
        /// changed (`M`).
        case changed
        /// It may have: no diff compared them (a full read took the step),
        /// the path was absent in between, or the two sit apart in the
        /// backups' arrival order.
        case uncertain
    }

    /// Newest first; never empty — a version is the snapshots holding it.
    var snapshots: [IndexVersion]
    /// nil for the oldest version.
    var since: Since?

    /// The newest snapshot's ID: no two versions share a snapshot.
    var id: String { snapshots[0].id }
}

/// A path's version list reduced to what Search All Backups shows: the newest
/// indexed snapshot holding it, and how many of its chain's snapshots do —
/// the count the Backups tab its row opens lists, which is chain-scoped; a
/// copy under another plan is that plan's to list. Output-light whatever
/// the version count, which is the point.
struct VersionSummary: Sendable, Equatable {
    var count: Int
    var newest: IndexVersion
}

/// Version lists, newest first: `[IndexVersion]` for a folder,
/// `[ContentVersion]` for a file.
extension Array where Element: Identifiable, Element.ID == String {
    /// The version a picked ID names, else the newest — the version panes'
    /// "chosen", a pick of the newest being stored as none.
    func chosen(_ id: String?) -> Element? {
        id.flatMap { id in first { $0.id == id } } ?? first
    }

    /// The version below `version` in the list — the one it follows, the
    /// changes' older side. Nil past the oldest.
    func after(_ version: Element) -> Element? {
        guard let index = firstIndex(where: { $0.id == version.id }), index + 1 < count else { return nil }
        return self[index + 1]
    }
}

extension Array where Element == ContentVersion {
    /// The version holding `snapshotID` — a version's ID is its newest
    /// backup's — else the newest.
    func version(holding snapshotID: String?) -> ContentVersion? {
        guard let snapshotID else { return first }
        return first { $0.snapshots.contains { $0.id == snapshotID } } ?? first
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
/// spellings of one name are one String to Swift and two paths to restic.
/// A dictionary keyed by String keeps one entry for both, so a keyed read
/// would answer one path's question with the other's facts. The keyed
/// reads key on this instead. A string literal is one, so a path spelled
/// inline reads as itself.
struct PathKey: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible, Codable, CodingKeyRepresentable {
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

    /// As a dictionary's key: the JSON a [String: …] map wrote reads back
    /// unchanged.
    var codingKey: any CodingKey { Key(stringValue: path) }

    init?<T: CodingKey>(codingKey: T) {
        path = codingKey.stringValue
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

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
/// backup, since that is the snapshot it restores from.
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
/// The invariants every write keeps (checked by `invariantViolations()`):
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
    /// 4: version 3 with the file-node cache in the creation script, where
    /// an open had added it to every file since the cache came. 3: version 2
    /// had no `edit` or `blind`, and a file without them knows nothing of
    /// content changes, so it is rebuilt rather than read as if no file had
    /// ever changed. (1 is taken too: development builds wrote it.)
    private static let schemaVersion: Int32 = 4
    /// Node ids per batched read: under SQLite's pre-3.32 variable limit of
    /// 999, whatever the system library.
    static let lookupChunk = 400
    /// BackfillBuffer's chunk: the largest transaction a full read commits.
    static let chunkSize = 4_000
    /// `last_seq`'s sentinel "through hi". Real seqs start at 1, so no
    /// snapshot's seq equals it; the `first_seq` sentinel "from lo" is the
    /// literal `0` in the schema's SQL.
    static let top: Int64 = 2_147_483_647
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

    /// Whether an open failed because the file is no use as this index —
    /// another schema, or bytes SQLite cannot read as a database — which a
    /// rebuild fixes. Any other failure (a folder in the way, a full disk,
    /// a lock) is not the file's, and deleting it would throw a warm index
    /// away for nothing.
    static func isUnusableFile(_ error: Error) -> Bool {
        if case IndexError.schemaMismatch = error { return true }
        guard let database = error as? DatabaseError else { return false }
        return database.resultCode == .SQLITE_CORRUPT || database.resultCode == .SQLITE_NOTADB
    }

    /// Opens (or creates) the file at `path`. A file with any other schema —
    /// including an empty `user_version` over existing tables, which is what
    /// the older index format looks like — throws `schemaMismatch` with the
    /// pool already closed, so the owner can delete the file and open again.
    /// The file holds every indexed path in clear, names restic keeps
    /// encrypted in the repository: nothing more sensitive goes in it.
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
            // Keyed by bytes, as the chain table's UNIQUE key is: a String
            // key would merge NFC and NFD spellings of one lineage's paths.
            var chains: [PathKey: (id: Int64, next: Int64)] = [:]
            let insert = try db.cachedStatement(sql: SQL.snapInsert)
            for (snapshot, micros) in arrivals {
                let key = Self.chainKey(for: snapshot)
                let chain: (id: Int64, next: Int64)
                if let known = chains[PathKey(key)] {
                    chain = known
                } else {
                    try db.cachedStatement(sql: SQL.chainInsert).execute(arguments: [key])
                    guard let row = try Row.fetchOne(db.cachedStatement(sql: SQL.chainByKey), arguments: [key]) else {
                        throw DatabaseError(message: "chain row for \(key) vanished inside its own transaction")
                    }
                    chain = (row["id"], row["next_seq"])
                }
                try insert.execute(arguments: [snapshot.id, chain.id, chain.next, micros])
                chains[PathKey(key)] = (chain.id, chain.next + 1)
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
        if let tag = snapshot.planTags.first { return tag }
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
                // The chain row was just selected in this read.
                guard let window = try Self.chainWindow(db, chainID) else {
                    throw DatabaseError(message: "pending chain \(chainID) has no chain row")
                }
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

    /// A step past one end of a window: a delta from the end's snapshot
    /// while it lives, else a full compare against the runs that describe
    /// the dead end.
    private static func extending(_ hash: String, from base: String?) -> PlannedStep {
        guard let base else { return PlannedStep(step: .full(snapshotID: hash), deadWindowEnd: true) }
        return PlannedStep(step: .delta(snapshotID: hash, from: base))
    }

    /// The indexed snapshots holding `path`, newest first; equal times put
    /// the later arrival first. Only the exact spelling `restic ls` emits
    /// resolves (absolute, no `//`, no trailing `/`); anything else is an
    /// unknown path and answers `[]`.
    /// No production caller — the Backups tab reads the chain-restricted
    /// form below; this is the tests' chain-blind oracle.
    func versions(ofPath path: String) async throws -> [IndexVersion] {
        try await pool.read { db in
            var lookup = try NodeLookup(db)
            guard let node = try lookup.node(for: path) else { return [] }
            return try Row.fetchAll(db.cachedStatement(sql: SQL.versionsTimed), arguments: [node])
                .map(Self.version(from:))
        }
    }

    /// `versions(ofPath:)` restricted to one chain — the Backups tab's plan
    /// filter, in SQL. An unknown chain key answers `[]`.
    func versions(ofPath path: String, inChain chainKey: String) async throws -> [IndexVersion] {
        try await pool.read { db in
            var lookup = try NodeLookup(db)
            guard let node = try lookup.node(for: path) else { return [] }
            return try Row.fetchAll(db.cachedStatement(sql: SQL.versionsInChain), arguments: [node, chainKey])
                .map(Self.version(from:))
        }
    }

    /// Everything one chain's indexed snapshots ever held directly under
    /// `path`, by name bytewise — items a later backup no longer had
    /// included, marked by `isInNewest`. `/` lists the root's children; an
    /// unknown path or chain answers `[]`. Two snapshots of one chain at the
    /// same microsecond tie arbitrarily for `newest`.
    /// No production caller — the Backups tab's tree lists the backup's own
    /// folders through restic and the browse cache; this is the tests' view
    /// of the chain history.
    func children(ofPath path: String, inChain chainKey: String) async throws -> [IndexChild] {
        try await pool.read { db in
            var lookup = try NodeLookup(db)
            guard let parent = try lookup.folder(for: path) else { return [] }
            guard let newestSeq = try Int64.fetchOne(
                db.cachedStatement(sql: SQL.chainNewestIndexed), arguments: [chainKey]
            ) else { return [] }
            let prefix = path == "/" ? "" : path
            return try Row.fetchAll(db.cachedStatement(sql: SQL.childrenInChain), arguments: [chainKey, parent])
                .map { row in
                    let name: String = row[0]
                    let seq: Int64 = row[2]
                    return IndexChild(
                        path: prefix + "/" + name,
                        isDirectory: row[1],
                        newest: IndexVersion(id: row[3], time: Self.date(micros: row[4])),
                        isInNewest: seq == newestSeq
                    )
                }
        }
    }

    /// `path`'s content versions within one chain, newest first: the
    /// indexed snapshots holding it, in `versions(ofPath:inChain:)`'s order,
    /// cut wherever the content may differ between neighbours.
    ///
    /// Content is known equal across two snapshots one run covers with no
    /// edit or blind above the lower's seq and at or below the upper's, so
    /// the snapshots are first cut, in seq order, into segments of one
    /// content each; in time order — which back-dated arrivals can make
    /// differ from seq order — a version is a stretch of one segment. A cut
    /// is never missing: two snapshots of different content never share a
    /// version. One can be spare: when a death left two snapshots of the
    /// same content side by side across an edit, or a file came back as it
    /// was. Unknown paths and chains answer `[]`.
    func contentVersions(ofPath path: String, inChain chainKey: String) async throws -> [ContentVersion] {
        try await pool.read { db in
            var lookup = try NodeLookup(db)
            guard let node = try lookup.node(for: path) else { return [] }
            let held = try Row.fetchAll(db.cachedStatement(sql: SQL.heldInChain), arguments: [node, chainKey])
                .map { row in
                    (version: IndexVersion(id: row[0], time: Self.date(micros: row[1])), seq: row[2] as Int64, run: row[3] as Int64)
                }
            let bySeq = held.indices.sorted { held[$0].seq < held[$1].seq }
            guard let low = bySeq.first.map({ held[$0].seq }), let high = bySeq.last.map({ held[$0].seq }) else {
                return []
            }
            let edits = try Int64.fetchAll(db.cachedStatement(sql: SQL.editSeqs), arguments: [node, chainKey]).sorted()
            let blinds = try Int64.fetchAll(db.cachedStatement(sql: SQL.blindSeqs), arguments: [chainKey, low, high])
                .sorted()

            var segment = Array(repeating: 0, count: held.count)
            var begins: [ContentVersion.Since?] = [nil]
            var nextEdit = 0
            var nextBlind = 0
            for (k, i) in bySeq.enumerated() where k > 0 {
                let lower = held[bySeq[k - 1]]
                let upper = held[i]
                /// How many marks lie in `(lower.seq, upper.seq]`; the
                /// cursor walks the sorted marks once across the whole pass.
                func crossed(_ marks: [Int64], _ cursor: inout Int) -> Int {
                    while cursor < marks.count, marks[cursor] <= lower.seq { cursor += 1 }
                    var count = 0
                    while cursor < marks.count, marks[cursor] <= upper.seq {
                        count += 1
                        cursor += 1
                    }
                    return count
                }
                let edited = crossed(edits, &nextEdit)
                let blind = crossed(blinds, &nextBlind) > 0
                // Two or more edits may be a change undone across a backup
                // forgotten since.
                if upper.run != lower.run {
                    begins.append(.uncertain)
                } else if edited == 1, !blind {
                    begins.append(.changed)
                } else if edited > 0 || blind {
                    begins.append(.uncertain)
                }
                segment[i] = begins.count - 1
            }

            var versions: [ContentVersion] = []
            var segments: [Int] = []
            for i in held.indices {
                if segments.last == segment[i] {
                    versions[versions.count - 1].snapshots.append(held[i].version)
                } else {
                    versions.append(ContentVersion(snapshots: [held[i].version], since: nil))
                    segments.append(segment[i])
                }
            }
            // A boundary between seq-neighbouring segments is the upper
            // one's beginning; farther apart, nothing compared the two.
            for k in versions.indices.dropLast() {
                let (newer, older) = (segments[k], segments[k + 1])
                versions[k].since = abs(newer - older) == 1 ? begins[max(newer, older)] : .uncertain
            }
            return versions
        }
    }

    /// Per path: the newest indexed snapshot holding it and how many of its
    /// chain's snapshots do — that chain's `versions(ofPath:inChain:).first`
    /// and `.count`, without materialising a list that can run to
    /// thousands of versions. Not always `versions(ofPath:).first`: two
    /// chains holding it at one newest moment go to the higher chain id
    /// (`summaries`), where that list puts the later arrival first. Unknown
    /// paths, and paths with no indexed version, are absent. Keyed by the
    /// bytes asked for (`PathKey`), so canonically equal spellings keep
    /// their own answers. Search All Backups reads the summaries inside its search
    /// (`searchWithSummaries`); this path-keyed form is what the tests hold
    /// that read to, as `versions(ofPath:inChain:)` is the Backups tab's read.
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
    /// for (`PathKey`), as the summaries are. What the Restore pane's
    /// incomplete strip asks of the backup before, and what a restore by
    /// path asks of the backup it restores from.
    func kinds(of paths: [String], inSnapshot snapshotID: String) async throws -> [PathKey: Bool] {
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
    /// No production caller: the property tests' plain search oracle, that
    /// the composed searches (`searchWithSummaries`, `searchWithMembership`)
    /// must agree with.
    func searchPaths(matching query: String, limit: Int) async throws -> [SearchHit] {
        let match = Self.ftsQuery(from: query)
        guard !match.isEmpty, limit > 0 else { return [] }
        return try await pool.read { db in
            try Self.search(db, match: match, limit: limit).map(\.hit)
        }
    }

    /// `searchPaths`, plus which hits `snapshotID` holds and with what kind
    /// there, in the same read, keyed by the node ids the search already
    /// has. No production caller: the tests' oracle that `kinds(of:inSnapshot:)`
    /// and `searchPaths` must agree with.
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

    /// `searchPaths`, plus each hit's version summary — Search All Backups' rows —
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

    /// Each node's summary — the newest indexed snapshot holding it, and how
    /// many of that snapshot's chain hold it — for the nodes that have any,
    /// `lookupChunk` ids per statement. Node ids come from the caller's own
    /// transaction, `db`.
    ///
    /// Two statements, the counts and newest time per node and chain, then
    /// the newest hash in the chain that holds it latest, rather than one
    /// with window functions (`count(*) OVER` and `row_number()` by node):
    /// that form answers the same, ties included, but sorts every version
    /// of the chunk and runs about three times slower. Two chains holding a
    /// node at one moment — two backups of one second — go to the higher
    /// chain id, as the newest of one chain goes to the higher snapshot id.
    private static func summaries(_ db: Database, of nodes: [Int64]) throws -> [Int64: VersionSummary] {
        let newest = try db.cachedStatement(sql: SQL.summaryNewest)
        var latest: [Int64: (chain: Int64, count: Int, time: Int64)] = [:]
        for chunk in nodes.chunked(into: lookupChunk) {
            let sql = SQL.summaryCounts(placeholders: SQL.placeholders(chunk.count))
            for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(chunk)) {
                let node: Int64 = row[0]
                let chain: Int64 = row[1]
                let count: Int = row[2]
                let time: Int64 = row[3]
                if let held = latest[node], (held.time, held.chain) > (time, chain) { continue }
                latest[node] = (chain, count, time)
            }
        }
        var result: [Int64: VersionSummary] = [:]
        for (node, held) in latest {
            // The counts row above proved this snapshot, in this read.
            guard let hash = try String.fetchOne(newest, arguments: [node, held.chain, held.time]) else {
                throw DatabaseError(message: "node \(node)’s newest snapshot in chain \(held.chain) vanished inside one read")
            }
            result[node] = VersionSummary(count: held.count, newest: IndexVersion(id: hash, time: date(micros: held.time)))
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

    /// Basename search within one chain — the Backups tab's: `searchPaths`'s
    /// walk and order, keeping only the paths an indexed snapshot of the
    /// chain holds, so the limit counts the chain's hits alone and a chain
    /// whose names sort late still gets its own. Each hit is what the tree
    /// lists for it (`IndexChild`): its kind and newest backup are the
    /// chain's, and `isInNewest` says whether the chain's newest indexed
    /// snapshot holds it. An unknown chain answers `[]`.
    func search(matching query: String, inChain chainKey: String, limit: Int) async throws -> [IndexChild] {
        let match = Self.ftsQuery(from: query)
        guard !match.isEmpty, limit > 0 else { return [] }
        return try await pool.read { db in
            guard let chain = try Row.fetchOne(db.cachedStatement(sql: SQL.chainByKey), arguments: [chainKey]),
                  let newestSeq = try Int64.fetchOne(db.cachedStatement(sql: SQL.chainNewestIndexed), arguments: [chainKey])
            else { return [] }
            let chainID: Int64 = chain[0]
            let newestInChain = try db.cachedStatement(sql: SQL.newestInChain)
            return try Self.walk(db, match: match, limit: limit) { node in
                try Row.fetchOne(newestInChain, arguments: [node, chainID])
            }.map { found in
                let seq: Int64 = found.kept[1]
                return IndexChild(
                    path: found.path,
                    isDirectory: found.kept[0],
                    newest: IndexVersion(id: found.kept[2], time: Self.date(micros: found.kept[3])),
                    isInNewest: seq == newestSeq
                )
            }
        }
    }

    /// The search `searchPaths` describes, inside the caller's read: each
    /// hit with its node id, which the caller may use only within this same
    /// transaction (see `SearchWithMembership`).
    private static func search(_ db: Database, match: String, limit: Int) throws -> [(node: Int64, hit: SearchHit)] {
        let aliveRuns = try db.cachedStatement(sql: SQL.aliveRuns)
        let newestCover = try db.cachedStatement(sql: SQL.newestCover)
        return try walk(db, match: match, limit: limit) { node -> Bool? in
            let runs = try Row.fetchAll(aliveRuns, arguments: [node])
            guard let firstRun = runs.first else { return nil }
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
            return isDirectory
        }.map { (node: $0.node, hit: SearchHit(path: $0.path, isDirectory: $0.kept)) }
    }

    /// The walk both searches take, inside the caller's read: the MATCH
    /// cursor in name order, each candidate kept with what `accept` makes
    /// of it — nil drops it — until `limit` are kept; after that only names
    /// equal to the last kept one, so ties are cut by path, not by rowid.
    /// Ranked by name, then path, bytewise. Node ids are the caller's to use
    /// within this same transaction only.
    private static func walk<Kept>(
        _ db: Database,
        match: String,
        limit: Int,
        accept: (_ node: Int64) throws -> Kept?
    ) throws -> [(node: Int64, path: String, kept: Kept)] {
        var hits: [(name: String, node: Int64, kept: Kept)] = []
        var boundary: String?
        let cursor = try Row.fetchCursor(db.cachedStatement(sql: SQL.searchFTS), arguments: [match])
        while let row = try cursor.next() {
            let node: Int64 = row[0]
            let name: String = row[1]
            if let boundary, !name.utf8.elementsEqual(boundary.utf8) { break }
            guard node != Self.rootID, let kept = try accept(node) else { continue }
            hits.append((name, node, kept))
            if hits.count == limit { boundary = name }
        }
        var paths: [Int64: String] = [:]
        let ranked = try hits.map { hit in
            (name: hit.name, node: hit.node, path: try Self.path(db, of: hit.node, memo: &paths), kept: hit.kept)
        }.sorted { a, b in
            if !a.name.utf8.elementsEqual(b.name.utf8) { return Self.bytesLess(a.name, b.name) }
            return Self.bytesLess(a.path, b.path)
        }
        return ranked.prefix(limit).map { (node: $0.node, path: $0.path, kept: $0.kept) }
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

    /// Caches files' nodes as `restic find` reported them — by path's
    /// bytes, as the index keys paths, then by snapshot ID — in one write.
    /// As immutable as a listing: a repeated capture leaves the first
    /// standing.
    func recordFileNodes(_ nodes: [PathKey: [String: CachedListingNode]]) async throws {
        let payloads = try nodes.mapValues { try $0.mapValues { try Self.json($0) } }
        try await pool.write { db in
            for (path, bySnapshot) in payloads {
                for (snapshotID, payload) in bySnapshot {
                    try db.cachedStatement(sql: SQL.cacheOwnerPut).execute(arguments: [snapshotID])
                    try db.cachedStatement(sql: SQL.cacheFileNodePut).execute(arguments: [snapshotID, path.path, payload])
                }
            }
        }
    }

    /// The cached listing, or nil when none was captured. The directory key
    /// is normalized here too (`ResticPath.normalized`, as `recordListing`
    /// keys it), so a lookup meets its write whatever spelling either used.
    func listing(snapshotID: String, directory: String) async throws -> [CachedListingNode]? {
        try await cached(SQL.cacheListingGet, [snapshotID, ResticPath.normalized(directory)])
    }

    func diff(olderID: String, newerID: String) async throws -> [CachedDiffChange]? {
        try await cached(SQL.cacheDiffGet, [olderID, newerID])
    }

    /// One file's cached node in each of `snapshotIDs` that has one, by
    /// snapshot ID: a snapshot without one is absent, never an error.
    func fileNodes(path: String, snapshotIDs: [String]) async throws -> [String: CachedListingNode] {
        let payloads = try await pool.read { db in
            let statement = try db.cachedStatement(sql: SQL.cacheFileNodeGet)
            var found: [String: String] = [:]
            for snapshotID in snapshotIDs {
                found[snapshotID] = try String.fetchOne(statement, arguments: [snapshotID, path])
            }
            return found
        }
        return try payloads.mapValues { try JSONDecoder().decode(CachedListingNode.self, from: Data($0.utf8)) }
    }

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
            try db.cachedStatement(sql: SQL.cacheSweepFileNode).execute(arguments: [id])
            try db.cachedStatement(sql: SQL.cacheSweepOwner).execute(arguments: [id])
        }
    }

    /// The payload as TEXT: the cache columns are STRICT `TEXT`, which
    /// refuses the BLOB a bare `Data` binds as.
    private static func json(_ value: some Encodable) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

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
    private struct NodeLookup {
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

        /// `node(for:)`, except `/` answers the root: the folder whose
        /// children a listing reads.
        mutating func folder(for path: String) throws -> Int64? {
            path == "/" ? SnapshotIndex.rootID : try node(for: path)
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
    private static func isListedSpelling(_ path: String) -> Bool {
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
            // A missing ancestor would cut the path short ("/b" for "/a/b").
            guard let row = try Row.fetchOne(byID, arguments: [current]) else {
                throw DatabaseError(message: "node \(current), an ancestor of node \(id), is missing")
            }
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

    private static func date(micros: Int64) -> Date {
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
    ///
    /// A token whose composed and decomposed forms differ is asked in both:
    /// unicode61 folds Latin marks only, so a kana voicing mark or Hangul
    /// written decomposed (restic keeps the name's bytes) is another token.
    /// Not normalized in the index: its rows are node's own names, which
    /// FTS5's delete and integrity-check compare against.
    private static func ftsQuery(from input: String) -> String {
        input.split(whereSeparator: \.isWhitespace)
            .map { token in
                token
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    .replacingOccurrences(of: "\"", with: "\"\"")
            }
            // A token with no term character ("-", "&") is a zero-token
            // phrase, which under AND makes the whole query match nothing.
            .filter { $0.unicodeScalars.contains(where: isTermScalar) }
            .map { token in
                let composed = token.precomposedStringWithCanonicalMapping
                let decomposed = token.decomposedStringWithCanonicalMapping
                // By scalars: String's == is canonical, so the two compare equal.
                guard !composed.unicodeScalars.elementsEqual(decomposed.unicodeScalars) else {
                    return "\"\(composed)\"*"
                }
                // A trailing mark (the voicing of "が") is a separator, so a
                // star would land on the token before it: "か"* finds "かき".
                let star = isTermScalar(decomposed.unicodeScalars.last!) ? "*" : ""
                return "(\"\(composed)\"* OR \"\(decomposed)\"\(star))"
            }
            // Explicit: FTS5 refuses an implicit AND after a parenthesized group.
            .joined(separator: " AND ")
    }

    /// unicode61's default token characters (categories L* N* Co); every
    /// other scalar separates tokens.
    private static func isTermScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber, .privateUse:
            true
        default:
            false
        }
    }

    /// Every statement the index prepares — the open-time schema probe and
    /// scripts, the connection pragmas and the test-support invariant checks
    /// aside — under its property name in `SnapshotIndexSchema.Statements`,
    /// IN lists at `lookupChunk`. Read by reflection, so declaring a
    /// statement is registering it: `SnapshotIndexPlanTests` pins each one's
    /// plan and fails on a statement without a rule, on a rule without a
    /// statement, and on a stored property the reader cannot take for a
    /// statement.
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

    /// The index's stored-state checks, each violation a line that
    /// starts with its letter, plus (j), the premise `stageOwner` rests on,
    /// and (k), that every collection leaves `temp.gc` empty, so the next
    /// one starts from exactly what its own write queued, (l), that every
    /// content mark splits two indexed snapshots, and (m), that none names
    /// a node or chain that is gone. (d)–(k) and (m) hold after every write.
    /// (a)–(c) and (l) — the queue is empty, no closed run claims nothing, no
    /// chain is left without snapshots, no mark splits nothing — hold only
    /// right after `housekeeping()`, which is what establishes them; callers
    /// filter by letter. (i) has one allowed
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
            func splitsNothing(_ table: String) -> String {
                """
                (SELECT COUNT(*) FROM \(table) m WHERE NOT EXISTS (
                        SELECT 1 FROM snap s WHERE s.chain_id = m.chain_id AND s.state = 1 AND s.seq < m.seq)
                    OR NOT EXISTS (
                        SELECT 1 FROM snap s WHERE s.chain_id = m.chain_id AND s.state = 1 AND s.seq >= m.seq))
                """
            }
            try count(
                "(l) content marks with no indexed snapshot of their chain below them, or none at or above",
                "SELECT " + splitsNothing("edit") + " + " + splitsNothing("blind")
            )
            try count("(m) edits of a missing node or chain, blinds of a missing chain", """
                SELECT (SELECT COUNT(*) FROM edit e WHERE NOT EXISTS (SELECT 1 FROM node n WHERE n.id = e.node_id)
                        OR NOT EXISTS (SELECT 1 FROM chain c WHERE c.id = e.chain_id))
                    + (SELECT COUNT(*) FROM blind b WHERE NOT EXISTS (SELECT 1 FROM chain c WHERE c.id = b.chain_id))
                """)
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
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
