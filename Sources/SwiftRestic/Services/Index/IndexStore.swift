import Foundation

/// One restic snapshot as the index sees it: identity, its position in a
/// chain, whether the repository still lists it, and how much of its content
/// has been read into the entry runs.
struct IndexedSnapshot: Sendable, Equatable, Hashable {
    var id: String
    var chain: String
    var seq: Int
    var time: Date
    var alive: Bool
    var coverage: IndexCoverage
}

/// How much of a snapshot's content the index holds.
///
/// `full` means every path came straight from a `restic ls` of that snapshot.
/// `delta` means the runs were derived from a `restic diff` against an already
/// indexed neighbor — existence is exact either way, which is all the reverse
/// queries need.
enum IndexCoverage: Int, Sendable, Equatable {
    case none = 0
    case full = 1
    case delta = 2
}

/// The chains snapshots are grouped into for run storage.
///
/// A chain is one plan's backup lineage: runs merge along a chain because the
/// diff between consecutive snapshots of one plan is cheap and its paths are
/// comparable. Snapshots no plan owns (restic CLI, other hosts) form singleton
/// chains — they still get indexed, they just never merge with a neighbor,
/// because nothing promises their paths mean the same thing as anyone else's.
enum IndexChain {
    static func chain(id: String, tags: [String]) -> String {
        tags.first { $0.hasPrefix(ResticService.planTagPrefix) } ?? "snap:\(id)"
    }
}

/// What one reconcile pass changed.
struct ReconcileOutcome: Sendable, Equatable {
    var added: [String] = []
    var died: [String] = []
    var revived: [String] = []
}

/// One run, raw — the row the equality test compares index-build paths with.
struct IndexEntryRow: Sendable, Equatable {
    var path: String
    var chain: String
    var firstSeq: Int
    var lastSeq: Int
}

/// One path handed to the index with its kind known — `ls` nodes carry it in
/// `type`, diffs in the trailing slash of directory paths.
struct IndexedEntry: Sendable, Equatable {
    var path: String
    var isDirectory: Bool
}

/// One search result: a distinct path the index has seen, and whether it is a
/// directory. `nil` means unknown — rows rebuilt from pre-`search`-table
/// indexes carry no kind; the caller resolves those on demand.
struct SearchHit: Sendable, Equatable, Identifiable {
    var path: String
    var isDirectory: Bool?

    var id: String { path }
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

extension Array where Element == IndexedSnapshot {
    /// The version a folder browser opens a path at: the newest covering
    /// version — unless the version the user was reading one level up still
    /// covers this path too, because flipping through time should survive
    /// walking down into a folder. The list arrives newest first from the
    /// store; this only picks among its head entries.
    func preferredVersion(previousID: String?) -> IndexedSnapshot? {
        if let previousID, let kept = first(where: { $0.id == previousID }) {
            return kept
        }
        return first
    }
}

/// Errors the index layer raises on its own behalf.
enum IndexError: Error, Equatable {
    /// `recordContent` named a snapshot the index has never reconciled.
    case unknownSnapshot(String)
    /// The repository was removed; its index was deleted with it and no new
    /// one may be opened, however late the caller arrived.
    case repositoryRemoved
}

/// Path text helpers shared by the store and the cache row types — neutral
/// ground, so protocol-level types need not reach into the SQLite
/// implementation.
enum IndexPathText {
    /// The path's last component, scalar-wise for the same combining-mark
    /// reason `parent(of:)` in the engine is.
    static func basename(of path: String) -> String {
        guard let last = path.unicodeScalars.lastIndex(of: "/") else { return path }
        return String(path.unicodeScalars[last...].dropFirst())
    }
}

/// The reverse lookup restic cannot answer: which snapshots contain a path.
///
/// The store holds runs — `(path, chain, first_seq, last_seq)` — where a run
/// asserts the path exists in every alive snapshot of the chain whose seq
/// falls in the interval. The seam rules are the engine's: the schema lives as
/// SQL text in `IndexSchema`, every query here is a SQL string, and nothing
/// above this protocol may reach for GRDB. A port swaps this implementation;
/// the SQLite file and its migration history are the artifact that survives.
protocol IndexStore: Sendable {
    /// Aligns the snapshot table with a fresh `restic snapshots` listing:
    /// inserts unknown snapshots into their chains, marks listings that have
    /// vanished (forget/prune, an unmounted volume) dead, and revives ones
    /// that came back — a snapshot ID is content-addressed, so a returned
    /// snapshot's runs are still true. Browse-cache rows naming an ID that is
    /// not alive afterwards — forgotten, or never reconciled (a browse that
    /// raced a forget) — are swept in the same transaction; a revived
    /// snapshot simply re-browses live. Idempotent.
    func reconcile(aliveSnapshots: [Snapshot]) throws -> ReconcileOutcome

    /// Records paths verified to exist in one snapshot — a full `restic ls`
    /// streamed in chunks. Runs merge with an indexed neighbor on either side
    /// (a file unchanged between seq 4 and 6 becomes one run [4, 6] once both
    /// neighbors are known), so the steady-state row count is the number of
    /// distinct file versions, not files × snapshots. Each entry also lands in
    /// the search index by basename. Call with `final: true` once the last
    /// chunk has been delivered. Idempotent per call.
    func recordContent(snapshotID: String, entries: [IndexedEntry], final: Bool) throws

    /// Applies a `restic diff` between an indexed snapshot at `previousSeq`
    /// and the snapshot `snapshotID`: added paths open runs, removed paths
    /// end theirs, and everything else — content, type, metadata changes —
    /// extends, because the path's existence is unchanged. The interval
    /// spans every alive snapshot between the two seqs, so the caller must
    /// guarantee there are none unindexed in between (`predecessorForDelta`
    /// enforces it); a dead snapshot in the span is fine, since nothing
    /// queries the dead. Idempotent; on a thrown error nothing is recorded
    /// and the snapshot stays pending for the backfill's full read.
    func applyDelta(snapshotID: String, previousSeq: Int, added: [String], removed: [String]) throws

    /// The newest alive, already-indexed snapshot of `snapshotID`'s chain
    /// that a diff could build it from — nil when the snapshot is unknown,
    /// no longer pending, or first in its chain (then the backfill's full
    /// read is the only correct route).
    func predecessorForDelta(of snapshotID: String) throws -> IndexedSnapshot?

    /// Alive snapshots with no content indexed yet, newest first — the
    /// backfill queue.
    func pendingBackfill(limit: Int) throws -> [IndexedSnapshot]

    /// Alive snapshots whose runs cover `path`, newest first. This is the
    /// query restic cannot answer and the whole point of the index.
    func versions(ofPath: String) throws -> [IndexedSnapshot]

    /// Distinct paths whose basename matches the query, via the FTS index —
    /// instant, no restic walk. Tokens are matched as prefixes, so "inv"
    /// finds "invoice-2026.pdf". An empty query matches nothing rather than
    /// everything.
    func searchPaths(matching query: String, limit: Int) throws -> [SearchHit]

    /// Caches one directory's `restic ls` answer — the fields the browser
    /// renders. A snapshot is content-addressed and immutable, so the pair
    /// (snapshot, directory) has one true answer forever: a repeated capture
    /// is the same content, and the write may keep the first. Directories
    /// with no children are cached too — an explicit empty row is what makes
    /// their re-expansion free.
    func recordListing(snapshotID: String, directory: String, nodes: [CachedListingNode]) throws

    /// The cached listing for one directory of one snapshot, or nil when
    /// nothing has been captured. The directory key is canonicalized at this
    /// boundary — trailing slashes stripped, "/" preserved — so a lookup
    /// meets its write whatever spelling the caller used.
    func listing(snapshotID: String, directory: String) throws -> [CachedListingNode]?

    /// Caches one `restic diff` between two full snapshot IDs, kept raw.
    /// Only the uncapped `walkDiff` may feed this: a change-limit-capped
    /// stream must never present itself as the whole answer.
    func recordDiff(olderID: String, newerID: String, changes: [CachedDiffChange]) throws

    /// The cached diff between two snapshots, or nil when none captured.
    func diff(olderID: String, newerID: String) throws -> [CachedDiffChange]?
}
