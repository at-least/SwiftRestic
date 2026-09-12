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
    /// snapshot's runs are still true. Idempotent.
    func reconcile(aliveSnapshots: [Snapshot]) throws -> ReconcileOutcome

    /// Records paths verified to exist in one snapshot — a full `restic ls`
    /// streamed in chunks. Runs merge with an indexed neighbor on either side
    /// (a file unchanged between seq 4 and 6 becomes one run [4, 6] once both
    /// neighbors are known), so the steady-state row count is the number of
    /// distinct file versions, not files × snapshots. Call with `final: true`
    /// once the last chunk has been delivered. Idempotent per call.
    func recordContent(snapshotID: String, paths: [String], final: Bool) throws

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
}
