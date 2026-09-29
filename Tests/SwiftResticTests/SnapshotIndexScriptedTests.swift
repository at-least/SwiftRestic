import Foundation
import GRDB
import Testing

/// Scripted interleavings that the unit tests and the property test do not
/// reach on their own: the correctness judge's S1–S5, the complexity judge's
/// fault probe and fixtures, closedfinal's X1–X8, the abandoned-stage GC,
/// the quarantine's release, and the schema check at open. Each names the
/// harness check it ports (FINAL.md 5.2) and asserts that check's PASS
/// condition through the public API; every write goes through
/// `CheckedIndex`, so the stored-state invariants are checked after each.
///
/// Reviewer checklist — planted mutants each of these must catch (not run by
/// `./build.sh test`; plant one, run the five SnapshotIndex suites, and
/// expect red). Every line was planted and run once; the tests named are
/// the ones that went red:
/// - no stream identity check (`target.id == active.snapID`): S2, and the
///   property test's mid-stream flaps;
/// - `snap.id` without AUTOINCREMENT: S2 (the returning row reuses the id);
/// - no poisoning on a failed chunk: X6 and X8 — the fault probe passes it;
/// - no `enqueueIfDead` in the full compare: only the stored-state check
///   (b), in X7, `deadWindowEndTakesFull` and the property test — every
///   answer stays exact;
/// - node GC ignoring staged nodes: `stagedNodeSurvivesGC`, and the plan pin
///   of `gcKeepCollectable`;
/// - node GC collecting nothing: S1, S4, S5, both N14s, X7,
///   `stagedNodeSurvivesInterleavedStream`, `quarantinedStreamNodesCollected`,
///   `housekeepingSemantics`, `deadWindowEndTakesFull` and every property
///   variant;
/// - the stage discarded without collecting its run-less nodes: S1, S4, S5,
///   both N14s, `stagedNodeSurvivesInterleavedStream`,
///   `quarantinedStreamNodesCollected` and the property test's flaps (the
///   other variants retry the same snapshot, whose stage is kept);
/// - `beginFull` discarding a retry's own stage: `retriedStreamKeepsItsStage`;
/// - `beginFull` keeping another snapshot's stage: S1, S2, S4, both N14s,
///   `stagedNodeSurvivesInterleavedStream` and the property test's flaps —
///   check (j) is what fired in S2 and the property test;
/// - `markIndexed` clearing whatever the stage holds: `deltaBetweenChunks`
///   and `deltaIgnoresAForeignStage`;
/// - `markUnreadable` leaving its target's stream open:
///   `quarantinedStreamNodesCollected`;
/// - `markUnreadable` discarding another snapshot's stage:
///   `quarantineSparesAnotherStream`;
/// - `releaseUnreadable` deleting the rows for the next reconcile to re-add:
///   `releaseKeepsIncompleteUntilReread` and N9;
/// - the node insert without `ON CONFLICT … DO NOTHING`:
///   `repeatedEntryUnderNewDirectory` and `childBeforeParent`;
/// - the batched reads deduplicating with `Set(paths)`:
///   `batchedReadsKeepByteDistinctSpellings`;
/// - `collectNodes` leaving the stream's walk in place:
///   `collectionDropsTheWalk` (a delta keeps it, by design: the yielding
///   node insert makes its stale `created` hint harmless, which
///   `deltaBetweenChunks` exercises);
/// - `gcKeepCollectable` without its root term: `rootSurvivesCollection`;
/// - a file<->dir `T` accepted as an extension: `kindChangeRefused`, S3 and
///   the property test;
/// - search ties ordered by `String <` instead of bytes: `searchTiesByBytes`;
/// - the lineage key NUL-separated: `reconcileChainAssignment` and the
///   property test;
/// - `containsKind` reading `first_seq < ?`: `containsKindInSnapshot`,
///   `applyDeltaSemantics`, S2 and the property test.
@Suite("snapshot index scripted")
struct SnapshotIndexScriptedTests {
    private let plan = IndexTestData.planA
    private let otherPlan = IndexTestData.planB

    private func snap(_ id: String, _ micros: Int64, tags: [String]? = nil) throws -> Snapshot {
        try IndexTestData.snapshot(id, micros: micros, tags: tags ?? [plan], paths: ["/r"])
    }

    // MARK: - N1: the correctness judge's S1–S5

    @Test("S1: a cancelled first build of a forgotten snapshot leaves no claim on a later snapshot of the plan")
    func s1CancelledFirstBuild() async throws {
        let checked = try CheckedIndex()
        try checked.reconcile([try snap("s1", 1_000_000)])
        #expect(try checked.index.nextStep() == .full(snapshotID: "s1"))
        try checked.beginFull("s1")
        try checked.chunk("s1", [entry("/r", true), entry("/r/old.txt"), entry("/r/k")], final: false)
        try checked.reconcile([])
        try checked.housekeeping()
        try checked.reconcile([try snap("s2", 2_000_000)])
        #expect(try checked.index.nextStep() == .full(snapshotID: "s2"))
        try checked.full("s2", [entry("/r", true), entry("/r/k", true), entry("/r/k/c"), entry("/r/new.txt")])

        let index = checked.index
        #expect(try await index.versionIDs("/r/old.txt").isEmpty)
        #expect(try await index.contains(paths: ["/r/old.txt", "/r/new.txt", "/r/k/c", "/r/k"], inSnapshot: "s2")
            == ["/r/new.txt": false, "/r/k/c": false, "/r/k": true])
    }

    @Test("S2: death and revival of the streamed snapshot between two chunks never finalises a partial listing",
          arguments: [false, true])
    func s2FlapMidStream(housekeepBetween: Bool) async throws {
        let checked = try CheckedIndex()
        let a1 = try snap("a1", 1_000_000), a2 = try snap("a2", 2_000_000)
        let full = [entry("/r", true), entry("/r/x"), entry("/r/y"), entry("/r/z")]
        try checked.reconcile([a1])
        try checked.full("a1", [entry("/r", true), entry("/r/x"), entry("/r/y")])
        try checked.reconcile([a1, a2])
        #expect(try checked.index.nextStep() == .delta(snapshotID: "a2", from: "a1"))
        // The full route, as after a failed diff.
        try checked.beginFull("a2")
        try checked.chunk("a2", [entry("/r", true), entry("/r/x")], final: false)
        try checked.reconcile([a1])                      // a stale listing: a2 dies
        if housekeepBetween { try checked.housekeeping() }
        try checked.reconcile([a1, a2])                  // a fresh one: a2 is back, as a new row
        #expect(throws: IndexError.streamIdentityChanged("a2")) {
            try checked.chunk("a2", [entry("/r/y"), entry("/r/z")], final: true)
        }
        // The coordinator re-reads it from the top.
        var steps = 0
        while try checked.index.nextStep() != .done, steps < 10 {
            steps += 1
            try checked.full("a2", full)
        }
        let index = checked.index
        #expect(try await index.contains(paths: full.map(\.path), inSnapshot: "a2").count == 4)
        #expect(Set(try await index.versionIDs("/r/x")) == ["a1", "a2"])
        #expect(try await index.isComplete())
    }

    @Test("S3: a T-only file->dir line is refused, and the snapshot stays pending")
    func s3TOnlyDeltaRefused() async throws {
        let checked = try CheckedIndex()
        let a1 = try snap("a1", 1_000_000), a2 = try snap("a2", 2_000_000)
        try checked.reconcile([a1])
        try checked.full("a1", [entry("/r", true), entry("/r/k")])
        try checked.reconcile([a1, a2])
        #expect(throws: IndexError.kindChanged(snapshot: "a2", path: "/r/k")) {
            try checked.delta("a2", from: "a1", added: ["/r/k/"], removed: [])
        }
        #expect(try await checked.index.contains(paths: ["/r/k", "/r/k/g"], inSnapshot: "a2").isEmpty)
        #expect(try checked.index.nextStep() == .delta(snapshotID: "a2", from: "a1"))
    }

    @Test("S4: after a cancelled first build and a forget, the planner reaches done")
    func s4PlannerReachesDone() async throws {
        let checked = try CheckedIndex()
        try checked.reconcile([try snap("p1", 1_000_000)])
        try checked.beginFull("p1")
        try checked.chunk("p1", [entry("/r", true)], final: false)
        try checked.reconcile([])
        try checked.housekeeping()
        try checked.reconcile([try snap("u1", 2_000_000, tags: []), try snap("p2", 3_000_000)])
        var trace: [IndexStep] = []
        for _ in 0 ..< 8 {
            let step = try checked.index.nextStep()
            trace.append(step)
            switch step {
            case .done: break
            case .full(let id), .delta(let id, _): try checked.full(id, [entry("/r", true), entry("/r/f")])
            }
            if step == .done { break }
        }
        #expect(trace == [.full(snapshotID: "p2"), .full(snapshotID: "u1"), .done])
        #expect(try await checked.index.isComplete())
    }

    @Test("S5: an unreadable build target replaced within one listing leaves no claim")
    func s5UnreadableReplaced() async throws {
        let checked = try CheckedIndex()
        try checked.reconcile([try snap("s1", 1_000_000)])
        try checked.beginFull("s1")
        try checked.chunk("s1", [entry("/r", true), entry("/r/old.txt"), entry("/r/k")], final: false)
        try checked.markUnreadable("s1")
        try checked.reconcile([try snap("s2", 2_000_000)])
        try checked.housekeeping()
        #expect(try checked.index.nextStep() == .full(snapshotID: "s2"))
        try checked.full("s2", [entry("/r", true), entry("/r/k", true), entry("/r/k/c"), entry("/r/new.txt")])
        #expect(try await checked.index.versionIDs("/r/old.txt").isEmpty)
        #expect(try await checked.index.contains(paths: ["/r/k"], inSnapshot: "s2") == ["/r/k": true])
    }

    // MARK: - N1: closed's targeted tests

    /// A file<->dir change restic spells as one `T` line — the new kind only,
    /// both subtrees omitted — must be refused atomically; a file<->symlink
    /// `T` keeps the kind and changes nothing.
    @Test("kindChangeRefused: a T-only kind change is refused atomically in both directions; a same-kind T extends")
    func kindChangeRefused() async throws {
        let checked = try CheckedIndex()
        let s1 = try snap("s1", 10), s2 = try snap("s2", 20)
        try checked.reconcile([s1])
        try checked.full("s1", [entry("/d", true), entry("/d/x"), entry("/d/y", true), entry("/d/y/f")])
        try checked.reconcile([s1, s2])
        #expect(try checked.index.nextStep() == .delta(snapshotID: "s2", from: "s1"))
        for (added, path) in [(["/d/x/", "/d/new"], "/d/x"), (["/d/y"], "/d/y")] {
            #expect(throws: IndexError.kindChanged(snapshot: "s2", path: path)) {
                try checked.delta("s2", from: "s1", added: added, removed: [])
            }
            #expect(try checked.index.nextStep() == .delta(snapshotID: "s2", from: "s1"))
            #expect(try await checked.index.versionIDs("/d/new").isEmpty)
        }
        try checked.delta("s2", from: "s1", added: ["/d/x"], removed: [])
        #expect(try await checked.index.versionIDs("/d/x") == ["s2", "s1"])
        #expect(try await checked.index.versionIDs("/d/y/f") == ["s2", "s1"])
    }

    /// A node staged by an open stream loses its only run to housekeeping.
    /// Collecting it would let the stream's next new node take its rowid,
    /// and the stale stage row would then hand that node a run.
    @Test("stagedNodeSurvivesGC: a staged node outlives housekeeping between two chunks of its stream")
    func stagedNodeSurvivesGC() async throws {
        let checked = try CheckedIndex()
        let s1 = try snap("s1", 10), s2 = try snap("s2", 20), s3 = try snap("s3", 30)
        try checked.reconcile([s1, s2])
        try checked.full("s2", [entry("/d", true), entry("/d/keep")])
        try checked.delta("s1", from: "s2", added: ["/d/x"], removed: [])
        // s1 dies and s3 arrives; s3's stream stages /d/x (whose only run,
        // s1's, is garbage now); housekeeping runs between its chunks.
        try checked.reconcile([s2, s3])
        try checked.beginFull("s3")
        try checked.chunk("s3", [entry("/d", true), entry("/d/keep"), entry("/d/x")], final: false)
        try checked.housekeeping()
        try checked.chunk("s3", [entry("/d/z")], final: true)
        #expect(try await checked.index.versionIDs("/d/x") == ["s3"])
        #expect(try await checked.index.versionIDs("/d/z") == ["s3"])
        #expect(try await checked.index.versionIDs("/d/keep") == ["s3", "s2"])
    }

    @Test("stagedNodeSurvivesGC, closed's order: another plan's stream in between, then the re-read")
    func stagedNodeSurvivesInterleavedStream() async throws {
        let checked = try CheckedIndex()
        let s1 = try snap("s1", 10), s2 = try snap("s2", 20), s3 = try snap("s3", 30)
        let b1 = try snap("b1", 40, tags: [otherPlan])
        try checked.reconcile([s1, s2])
        try checked.full("s2", [entry("/d", true), entry("/d/keep")])
        try checked.delta("s1", from: "s2", added: ["/d/x"], removed: [])
        try checked.reconcile([s2, s3, b1])
        try checked.beginFull("s3")
        try checked.chunk("s3", [entry("/d", true), entry("/d/keep"), entry("/d/x")], final: false)
        try checked.housekeeping()
        try checked.full("b1", [entry("/e", true), entry("/e/y")])
        try checked.full("s3", [entry("/d", true), entry("/d/keep"), entry("/d/x")])
        #expect(try await checked.index.versionIDs("/e") == ["b1"])
        #expect(try await checked.index.versionIDs("/e/y") == ["b1"])
        #expect(try await checked.index.versionIDs("/d/x") == ["s3"])
    }

    // MARK: - Streams: what a listing may repeat or reorder, and what may land between chunks

    /// restic's `ls --json` coerces names to valid UTF-8, so two siblings
    /// whose names differ only in invalid bytes list as one path twice. The
    /// stage keeps one row per path; the node insert must not trip over the
    /// node the stream itself created a moment (or a chunk) earlier.
    @Test("a repeated ls entry under a directory the stream created is staged once, in one chunk or across two")
    func repeatedEntryUnderNewDirectory() async throws {
        let checked = try CheckedIndex()
        let twin = "/r/a/caf\u{FFFD}"
        try checked.reconcile([try snap("s1", 1_000_000), try snap("s2", 2_000_000, tags: [otherPlan])])
        try checked.beginFull("s1")
        try checked.chunk("s1", [entry("/r", true), entry("/r/a", true), entry(twin), entry(twin)], final: true)
        try checked.beginFull("s2")
        try checked.chunk("s2", [entry("/s", true), entry("/s/a", true), entry("/s/a/x")], final: false)
        try checked.chunk("s2", [entry("/s/a/x")], final: true)
        #expect(try await checked.index.versionIDs(twin) == ["s1"])
        #expect(try await checked.index.versionIDs("/s/a/x") == ["s2"])
        #expect(try await checked.index.isComplete())
    }

    /// The walk reseeds from the root when a parent is not on its stack, so
    /// the order of a listing costs lookups, never correctness.
    @Test("a child listed before its parent directories is accepted, kinds intact")
    func childBeforeParent() async throws {
        let checked = try CheckedIndex()
        try checked.reconcile([try snap("s1", 1_000_000)])
        try checked.full("s1", [entry("/r/a/x"), entry("/r/a", true), entry("/r", true)])
        #expect(try await checked.index.versionIDs("/r/a/x") == ["s1"])
        #expect(try await checked.index.contains(paths: ["/r", "/r/a", "/r/a/x"], inSnapshot: "s1")
            == ["/r": true, "/r/a": true, "/r/a/x": false])
    }

    /// A delta may create a child under a directory an open stream created,
    /// between two of that stream's chunks, so the stream's cached walk
    /// believes that directory childless when it is not. A delta deletes no
    /// node, so the walk's ids stay good and the delta keeps it (FINAL.md
    /// 2.2 #14 dropped it there): a delta no longer drops the walk; a
    /// collection does. What keeps this exact is the skipped lookup's insert
    /// yielding to the existing child — without it, this failed with a
    /// UNIQUE error.
    @Test("a delta of another plan between two chunks adds a child under a directory the stream created; the stream continues exactly")
    func deltaBetweenChunks() async throws {
        let checked = try CheckedIndex()
        let p1 = try snap("p1", 1_000_000), q1 = try snap("q1", 1_100_000, tags: [otherPlan])
        let p2 = try snap("p2", 2_000_000), q2 = try snap("q2", 2_100_000, tags: [otherPlan])
        try checked.reconcile([p1, q1])
        try checked.full("p1", [entry("/r", true)])
        try checked.full("q1", [entry("/r", true)])
        try checked.reconcile([p1, q1, p2, q2])
        try checked.beginFull("p2")
        try checked.chunk("p2", [entry("/r", true), entry("/r/new", true)], final: false)
        try checked.delta("q2", from: "q1", added: ["/r/new/", "/r/new/x"], removed: [])
        // The walk survived the delta, so the next chunk really meets the
        // stale hint.
        #expect(checked.index.streamHoldsWalk())
        try checked.chunk("p2", [entry("/r/new/x")], final: true)
        #expect(try await checked.index.versionIDs("/r/new/x") == ["q2", "p2"])
        // The delta indexed q2, not p2: p2's stage is not its to clear.
        #expect(try await checked.index.contains(paths: ["/r", "/r/new", "/r/new/x"], inSnapshot: "p2")
            == ["/r": true, "/r/new": true, "/r/new/x": false])
        #expect(try await checked.index.isComplete())
    }

    /// Node ids go stale in one place: `collectNodes`, the only path that
    /// deletes nodes, drops the open stream's cached walk itself — here under
    /// housekeeping between two chunks — so no caller has to remember to.
    /// The stream then reseeds from the root and lands exactly.
    @Test("a node collection between two chunks drops the stream's cached walk, and the stream still lands exactly")
    func collectionDropsTheWalk() async throws {
        let checked = try CheckedIndex()
        let s1 = try snap("s1", 10), s2 = try snap("s2", 20), b1 = try snap("b1", 30, tags: [otherPlan])
        try checked.reconcile([s1, s2, b1])
        try checked.full("s2", [entry("/d", true), entry("/d/keep")])
        try checked.delta("s1", from: "s2", added: ["/d/gone"], removed: [])
        // s1 leaves: /d/gone's only run claims nothing, and its node is
        // housekeeping's to collect.
        try checked.reconcile([s2, b1])
        try checked.beginFull("b1")
        try checked.chunk("b1", [entry("/e", true), entry("/e/f", true)], final: false)
        #expect(checked.index.streamHoldsWalk())
        let nodes = try Self.nodeCount(checked.index)
        try checked.housekeeping()
        #expect(try Self.nodeCount(checked.index) == nodes - 1, "housekeeping collected nothing")
        #expect(!checked.index.streamHoldsWalk(), "a collection kept the walk")
        try checked.chunk("b1", [entry("/e/f/g")], final: true)
        #expect(try await checked.index.versionIDs("/e/f/g") == ["b1"])
        #expect(try await checked.index.versionIDs("/d/keep") == ["s2"])
        #expect(try await checked.index.versionIDs("/d/gone").isEmpty)
        #expect(try await checked.index.isComplete())
    }

    /// The root is the tree's anchor, created with the schema and never
    /// again. A listing may name "/" itself, which gives the root a run; when
    /// that chain dies, the collection climbs to the root, which
    /// `gcKeepCollectable` refuses to collect.
    @Test("a chain whose listing named the root dies, and the root survives the collection")
    func rootSurvivesCollection() async throws {
        let checked = try CheckedIndex()
        try checked.reconcile([try snap("s1", 1_000_000)])
        try checked.full("s1", [entry("/", true), entry("/r", true), entry("/r/a")])
        try checked.reconcile([])
        try checked.housekeeping()
        #expect(try Self.nodeCount(checked.index) == 1, "the root, and nothing else, remains")
        try checked.reconcile([try snap("s2", 2_000_000, tags: [otherPlan])])
        try checked.full("s2", [entry("/x", true), entry("/x/y")])
        #expect(try await checked.index.versionIDs("/x/y") == ["s2"])
    }

    /// A first build that fails partway is retried from the top. The listing
    /// is immutable, so what the failed attempt staged is part of it: the
    /// retry keeps those rows and their nodes instead of collecting the
    /// whole tree in one transaction and creating it all over again.
    @Test("a retried stream of the same snapshot keeps what its abandoned attempt staged, and lands exactly")
    func retriedStreamKeepsItsStage() async throws {
        let checked = try CheckedIndex()
        try checked.reconcile([try snap("s1", 1_000_000)])
        let listing = [entry("/r", true), entry("/r/a", true), entry("/r/a/x"), entry("/r/b")]
        try checked.beginFull("s1")
        try checked.chunk("s1", Array(listing.prefix(3)), final: false)
        // The walk failed here: no final. The next pass retries s1.
        let staged = try Self.nodeCount(checked.index)
        #expect(staged == 4)
        try checked.beginFull("s1")
        #expect(try Self.nodeCount(checked.index) == staged)
        try checked.chunk("s1", listing, final: true)
        #expect(Set(try await checked.index.contains(paths: listing.map(\.path), inSnapshot: "s1").keys)
            == listing.map(\.path).pathKeys)
        #expect(try await checked.index.isComplete())
    }

    /// An abandoned stream's stage outlives it until the next `beginFull`
    /// (or its target's quarantine), and backups of other plans keep coming
    /// meanwhile. Their deltas must cost what their own change costs: the
    /// stage clear that indexing does applies to the target's own stage
    /// only, and asking whose stage it is reads one row.
    @Test("a delta's work does not grow with a stage another snapshot's abandoned stream left behind")
    func deltaIgnoresAForeignStage() async throws {
        let checked = try CheckedIndex()
        let index = checked.index
        let chainA = try (1 ... 4).map { try snap("a\($0)", Int64($0) * 1_000_000) }
        let b1 = try snap("b1", 500_000, tags: [otherPlan])
        try checked.reconcile([chainA[0], b1])
        try checked.full("a1", [entry("/r", true), entry("/r/f")])
        try checked.reconcile(chainA + [b1])
        // Zero-change backups of plan A: the first prepares every statement,
        // the second is the baseline.
        try checked.delta("a2", from: "a1", added: [], removed: [])
        let empty = try index.writerWork { try index.ingestDiff(snapshotID: "a3", from: "a2", added: [], removed: []) }
        let staged = 2_000
        try checked.beginFull("b1")
        try checked.chunk("b1", [entry("/b", true)] + (1 ..< staged).map { entry("/b/f\($0)") }, final: false)
        // The stream fails here. The next backup of plan A:
        let foreign = try index.writerWork { try index.ingestDiff(snapshotID: "a4", from: "a3", added: [], removed: []) }
        #expect(foreign <= empty + 200, "zero-change delta: \(empty) with an empty stage, \(foreign) with \(staged) foreign rows")
        #expect(try index.violations(afterHousekeeping: false).isEmpty)
        #expect(try await index.versionIDs("/r/f") == ["a4", "a3", "a2", "a1"])

        // The measure can fail: reading those rows registers at least one
        // unit per row.
        let scan = try index.writerWork {
            _ = try index.pool.write { try Int.fetchOne($0, sql: "SELECT SUM(is_dir) FROM temp.stage") }
        }
        #expect(scan >= staged, "a scan of \(staged) stage rows counted \(scan)")
        print("SnapshotIndexScriptedTests deltaIgnoresAForeignStage: empty=\(empty) foreign=\(foreign) scan=\(scan)")
    }

    /// The stage's owner is read off its first row, which is right only
    /// while every row names one snapshot. Check (j) holds the store to that
    /// after every checked write — and here it proves it can fail.
    @Test("check (j) reports a stage holding two snapshots' rows")
    func stageOwnerPremiseCheckCanFail() throws {
        let fixture = try IndexFixture()
        try fixture.index.pool.writeWithoutTransaction { db in
            try db.execute(sql: "INSERT INTO temp.stage (node_id, snap_id, is_dir) VALUES (1, 1, 1), (1, 2, 1)")
        }
        #expect(try fixture.index.invariantViolations().contains("(j) snapshots with rows in the stage, when more than one: 2"))
    }

    /// Node rows, the root included. Counted rather than compared by id: a
    /// node collected and created again can take the same id.
    static func nodeCount(_ index: SnapshotIndex) throws -> Int {
        try index.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM node") ?? 0 }
    }

    // MARK: - N3: the complexity judge's fault probe

    @Test("N3: a chunk that rolls back after creating nodes leaves no broken node, and a re-read is exact and searchable")
    func faultedChunkLeavesTreeWhole() async throws {
        let checked = try CheckedIndex()
        try checked.reconcile([try IndexTestData.snapshot("s1", micros: 1_000_000, tags: [plan], paths: ["/a"])])
        let chunk1 = [entry("/a", true), entry("/a/b", true), entry("/a/b/f1")]
        let chunk2 = [entry("/a/b/c", true), entry("/a/b/c/boom")]
        let chunk3 = [entry("/a/b/c/g"), entry("/a/b/c/d", true), entry("/a/b/c/d/h")]
        let truth = Set((chunk1 + chunk2 + chunk3).map(\.path))

        // Pass 1, fed as BackfillBuffer feeds it: the first failed chunk
        // stops the buffer, so no later chunk and no final is sent.
        try checked.beginFull("s1")
        try checked.chunk("s1", chunk1, final: false)
        try Self.armBoomTrigger(checked.path)
        #expect(throws: (any Error).self) { try checked.chunk("s1", chunk2, final: false) }
        try Self.disarmBoomTrigger(checked.path)
        #expect(try await !checked.index.isComplete())

        // Pass 2 re-reads from the top.
        try checked.full("s1", chunk1 + chunk2 + chunk3)
        #expect(try await checked.index.isComplete())
        #expect(Set(try await checked.index.contains(paths: Array(truth), inSnapshot: "s1").keys) == truth.pathKeys)
        for query in ["g", "h", "d", "c"] {
            let hits = try await Self.searchWithin(seconds: 5, checked.index, query)
            #expect(!hits.isEmpty, "search('\(query)') found nothing")
            for hit in hits { #expect(truth.contains(hit.path), "search('\(query)') returned \(hit.path)") }
        }
    }

    /// A side connection plants a trigger that aborts any insert of a node
    /// named "boom" — a failure after the chunk already created nodes.
    static func armBoomTrigger(_ path: String) throws {
        let side = try DatabaseQueue(path: path)
        try side.write {
            try $0.execute(sql: "CREATE TRIGGER boom AFTER INSERT ON node WHEN NEW.name = 'boom' BEGIN SELECT RAISE(ABORT, 'boom'); END")
        }
        try side.close()
    }

    static func disarmBoomTrigger(_ path: String) throws {
        let side = try DatabaseQueue(path: path)
        try side.write { try $0.execute(sql: "DROP TRIGGER boom") }
        try side.close()
    }

    /// A search raced against a deadline: a broken node tree once made the
    /// path rebuild loop forever, and that must fail this test, not hang the
    /// suite. Losing the race cancels the search, which interrupts SQLite.
    static func searchWithin(seconds: Double, _ index: SnapshotIndex, _ query: String) async throws -> [SearchHit] {
        try await withThrowingTaskGroup(of: [SearchHit]?.self) { group in
            group.addTask { try await index.searchPaths(matching: query, limit: 50) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            guard let hits = first else {
                Issue.record("search('\(query)') gave no answer in \(seconds) s")
                return []
            }
            return hits
        }
    }

    // MARK: - N4: the complexity judge's fixtures

    @Test("N4 (b): a snapshot that dies and returns with no housekeeping between is pending, then exact after one step")
    func revivalWithoutHousekeeping() async throws {
        let checked = try CheckedIndex()
        let old = try snap("o", 1_000), new = try snap("n", 2_000)
        let content: IndexContent = ["/data": true, "/data/a.txt": false]
        try checked.reconcile([old, new])
        try checked.runToDone(["o": content, "n": content])
        #expect(try await checked.index.isComplete())
        try checked.reconcile([new])
        try checked.reconcile([old, new])
        #expect(try await !checked.index.isComplete())
        #expect(try await checked.index.versionIDs("/data/a.txt") == ["n"])
        let trace = try checked.runToDone(["o": content, "n": content])
        #expect(trace == ["delta(o<-n)"])
        #expect(try await checked.index.versionIDs("/data/a.txt") == ["n", "o"])
        #expect(try await checked.index.isComplete())
    }

    // MARK: - N13: closedfinal's X1–X8 (N9 is X2–X4 plus the release)

    @Test("X1: reconcile adds one pending row per listed ID, deletes a dead one's, re-adds a return as a new row, and writes nothing on a repeat")
    func x1ReconcileRows() async throws {
        let checked = try CheckedIndex()
        let a = try snap("a", 1_000_000), b = try snap("b", 2_000_000)
        let pending = SnapshotIndex.State.pending
        try checked.reconcile([a, b, a])
        #expect(try checked.index.snapStates() == ["a": pending, "b": pending])
        // Arrival is time order: b is the chain's newest, so its first build.
        #expect(try checked.index.nextStep() == .full(snapshotID: "b"))
        #expect(try checked.reconcile([b, a]).rows == 0)
        try checked.reconcile([b])
        try checked.housekeeping()
        #expect(try checked.index.snapStates() == ["b": pending])
        // The return is a new row with a fresh seq above b's: now a is the
        // newest, and the first build reads it.
        try checked.reconcile([a, b])
        #expect(try checked.index.snapStates() == ["a": pending, "b": pending])
        #expect(try checked.index.nextStep() == .full(snapshotID: "a"))
        let trace = try checked.runToDone(["a": ["/r": true, "/r/x": false], "b": ["/r": true, "/r/y": false]])
        #expect(trace == ["full(a)", "delta(b<-a)"])
        #expect(try await checked.index.versionIDs("/r/x") == ["a"])
        #expect(try await checked.index.versionIDs("/r/y") == ["b"])
        #expect(try await checked.index.isComplete())
    }

    /// N6's guard, in the store: the compare and the write share one writer
    /// turn, and the number is taken before the statements run. It writes
    /// through `fixture.index` rather than `CheckedIndex`: the wrapper has no
    /// numbered reconcile, and the write this test fails on purpose is the
    /// point, not a state to check.
    @Test("a numbered reconcile drops a listing not newer than the last one taken, keeps the number when its write fails, and a fresh object takes any")
    func numberedReconcileKeepsItsNumber() async throws {
        let fixture = try IndexFixture()
        let older = try snap("older", 1_000_000), newer = try snap("newer", 2_000_000), third = try snap("third", 3_000_000)
        func listed() async throws -> [String] {
            try await fixture.index.pool.read { try String.fetchAll($0, sql: "SELECT hash FROM snap ORDER BY hash") }
        }
        #expect(try fixture.index.reconcile(listing: [older, newer], generation: 5))
        #expect(try !fixture.index.reconcile(listing: [older], generation: 4))
        #expect(try !fixture.index.reconcile(listing: [older], generation: 5))
        #expect(try await listed() == ["newer", "older"])

        // A write that fails after the compare keeps the number: the same
        // listing again is dropped, and nothing of the failed one stayed.
        try await fixture.index.pool.writeWithoutTransaction {
            try $0.execute(sql: "CREATE TEMP TRIGGER scripted_failure BEFORE INSERT ON snap BEGIN SELECT RAISE(ABORT, 'scripted'); END")
        }
        #expect(throws: DatabaseError.self) { try fixture.index.reconcile(listing: [older, newer, third], generation: 6) }
        try await fixture.index.pool.writeWithoutTransaction { try $0.execute(sql: "DROP TRIGGER temp.scripted_failure") }
        #expect(try !fixture.index.reconcile(listing: [older, newer, third], generation: 6))
        #expect(try await listed() == ["newer", "older"])
        #expect(try fixture.index.reconcile(listing: [older, newer, third], generation: 7))
        #expect(try await listed() == ["newer", "older", "third"])

        // The unnumbered reconcile the tests drive leaves the number alone.
        try fixture.index.reconcile(listing: [older])
        #expect(try !fixture.index.reconcile(listing: [older], generation: 7))

        // A fresh object — the next launch, or the new file a reset leaves —
        // has taken nothing.
        try fixture.reopen()
        #expect(try fixture.index.reconcile(listing: [older], generation: 1))
    }

    @Test("X2: an unreadable snapshot above hi does not pin the window, is claimed by nothing, and is retried on return")
    func x2UnreadableAbove() async throws {
        let checked = try CheckedIndex()
        let s1 = try snap("s1", 1_000_000), s2 = try snap("s2", 2_000_000), s3 = try snap("s3", 3_000_000)
        let contents: [String: IndexContent] = [
            "s1": ["/r": true, "/r/a": false],
            "s2": ["/r": true, "/r/a": false, "/r/b": false],
            "s3": ["/r": true, "/r/c": false],
        ]
        let index = checked.index
        try checked.reconcile([s1])
        try checked.runToDone(contents)
        try checked.reconcile([s1, s2, s3])
        #expect(try index.nextStep() == .delta(snapshotID: "s2", from: "s1"))
        try checked.markUnreadable("s2")
        #expect(try checked.runToDone(contents) == ["delta(s3<-s1)"])
        #expect(try await !index.isComplete())
        #expect(try await index.versionIDs("/r/a") == ["s1"])
        #expect(try await index.versionIDs("/r/c") == ["s3"])
        #expect(try await index.versionIDs("/r/b").isEmpty)
        #expect(try await index.contains(paths: ["/r", "/r/a", "/r/b"], inSnapshot: "s2").isEmpty)
        #expect(try await index.searchPaths(matching: "b", limit: 10).isEmpty)

        try checked.reconcile([s1, s3])
        try checked.housekeeping()
        #expect(try await index.isComplete())
        try checked.reconcile([s1, s2, s3])
        #expect(try await !index.isComplete())
        #expect(try checked.runToDone(contents) == ["delta(s2<-s3)"])
        #expect(try await index.versionIDs("/r/b") == ["s2"])
        #expect(Set(try await index.versionIDs("/r/a")) == ["s1", "s2"])
        #expect(try await index.isComplete())
    }

    @Test("X3: reverse backfill passes an unreadable snapshot; it stays out of every answer")
    func x3UnreadableBelow() async throws {
        let checked = try CheckedIndex()
        let listing = [try snap("s1", 1_000_000), try snap("s2", 2_000_000), try snap("s3", 3_000_000)]
        let contents: [String: IndexContent] = [
            "s1": ["/r": true, "/r/old": false], "s2": ["/r": true, "/r/mid": false], "s3": ["/r": true, "/r/new": false],
        ]
        try checked.reconcile(listing)
        #expect(try checked.index.nextStep() == .full(snapshotID: "s3"))
        try checked.full("s3", IndexTestData.ls(contents["s3"] ?? [:]))
        try checked.markUnreadable("s2")
        #expect(try checked.runToDone(contents) == ["delta(s1<-s3)"])
        #expect(try await checked.index.versionIDs("/r/old") == ["s1"])
        #expect(try await checked.index.versionIDs("/r/mid").isEmpty)
        #expect(try await !checked.index.isComplete())
    }

    @Test("X4: markUnreadable leaves an indexed or unknown snapshot alone")
    func x4MarkUnreadableNoOp() async throws {
        let checked = try CheckedIndex()
        try checked.reconcile([try snap("s1", 1_000_000)])
        try checked.runToDone(["s1": ["/r": true, "/r/a": false]])
        try checked.markUnreadable("s1")
        try checked.markUnreadable("ghost")
        #expect(try await checked.index.versionIDs("/r/a") == ["s1"])
        #expect(try await checked.index.isComplete())
    }

    @Test("N9: releaseUnreadable lets a set-aside snapshot come back pending and be read exactly")
    func n9ReleaseUnreadable() async throws {
        let checked = try CheckedIndex()
        let listing = [try snap("s1", 1_000_000), try snap("s2", 2_000_000), try snap("s3", 3_000_000)]
        let contents: [String: IndexContent] = [
            "s1": ["/r": true, "/r/old": false], "s2": ["/r": true, "/r/mid": false], "s3": ["/r": true, "/r/new": false],
        ]
        try checked.reconcile(listing)
        try checked.full("s3", IndexTestData.ls(contents["s3"] ?? [:]))
        try checked.markUnreadable("s2")
        try checked.runToDone(contents)
        #expect(try await !checked.index.isComplete())

        // The next launch: released before the first reconcile — pending
        // again, in place, above hi — so the listing finds it known.
        try checked.releaseUnreadable()
        #expect(try checked.index.snapStates()["s2"] == SnapshotIndex.State.pending)
        // The listing finds it known: nothing is deleted or added.
        #expect(try checked.reconcile(listing).rows == 0)
        #expect(try await !checked.index.isComplete())
        #expect(try checked.runToDone(contents) == ["delta(s2<-s3)"])
        #expect(try await checked.index.versionIDs("/r/mid") == ["s2"])
        #expect(try await checked.index.versionIDs("/r/old") == ["s1"])
        #expect(try await checked.index.isComplete())
        try checked.housekeeping()
    }

    /// FINAL.md 3.5: the index never reads complete while a listed snapshot
    /// is unread. The release runs in its own write, before the launch's
    /// first reconcile, and a read can land between the two.
    @Test("releaseUnreadable never lets the index read complete while the released snapshot is still listed")
    func releaseKeepsIncompleteUntilReread() async throws {
        let checked = try CheckedIndex()
        let s1 = try snap("s1", 1_000_000), s2 = try snap("s2", 2_000_000)
        let contents: [String: IndexContent] = ["s1": ["/r": true, "/r/a": false], "s2": ["/r": true, "/r/b": false]]
        try checked.reconcile([s1, s2])
        try checked.markUnreadable("s2")
        try checked.full("s1", IndexTestData.ls(contents["s1"] ?? [:]))
        #expect(try await !checked.index.isComplete())
        try checked.releaseUnreadable()
        #expect(try await !checked.index.isComplete())
        #expect(try checked.index.nextStep() == .delta(snapshotID: "s2", from: "s1"))
        try checked.reconcile([s1, s2])
        #expect(try checked.runToDone(contents) == ["delta(s2<-s1)"])
        #expect(try await checked.index.versionIDs("/r/b") == ["s2"])
        #expect(try await checked.index.isComplete())
    }

    /// A stream the backfill gave up on is over: nothing in the store will
    /// begin another for it, and the planner reports done. Its staged nodes
    /// must not wait for a `beginFull` that may never come before the app
    /// quits and takes the TEMP stage with it.
    @Test("a quarantined stream's new nodes do not outlive a normal relaunch")
    func quarantinedStreamNodesCollected() async throws {
        let checked = try CheckedIndex()
        let a1 = try snap("a1", 1_000_000), bad = try snap("bad", 2_000_000, tags: [otherPlan])
        try checked.reconcile([a1, bad])
        try checked.full("a1", [entry("/a", true)])
        try checked.beginFull("bad")
        try checked.chunk("bad", [entry("/b", true), entry("/b/y")], final: false)
        try checked.markUnreadable("bad")
        #expect(try checked.index.nextStep() == .done)
        try checked.reopen()
        try checked.releaseUnreadable()
        try checked.reconcile([a1])
        try checked.housekeeping()
        #expect(try await checked.index.searchPaths(matching: "y", limit: 10).isEmpty)
    }

    /// Quarantine ends the target's own stream only. Another snapshot's
    /// open stream keeps its session and its stage, and lands whole.
    @Test("markUnreadable leaves another snapshot's open stream whole")
    func quarantineSparesAnotherStream() async throws {
        let checked = try CheckedIndex()
        let s1 = try snap("s1", 1_000_000), b1 = try snap("b1", 2_000_000, tags: [otherPlan])
        try checked.reconcile([s1, b1])
        try checked.beginFull("s1")
        try checked.chunk("s1", [entry("/r", true), entry("/r/a")], final: false)
        try checked.markUnreadable("b1")
        try checked.chunk("s1", [entry("/r/b")], final: true)
        #expect(try await checked.index.contains(paths: ["/r", "/r/a", "/r/b"], inSnapshot: "s1")
            == ["/r": true, "/r/a": false, "/r/b": false])
    }

    @Test("X5: an empty final with no stream is refused (noSession) and changes nothing")
    func x5NoSession() async throws {
        let checked = try CheckedIndex()
        let s1 = try snap("s1", 1_000_000), s2 = try snap("s2", 2_000_000)
        try checked.reconcile([s1])
        try checked.runToDone(["s1": ["/r": true, "/r/a": false]])
        try checked.reconcile([s1, s2])
        #expect(throws: IndexError.noSession("s2")) { try checked.chunk("s2", [], final: true) }
        #expect(try await checked.index.versionIDs("/r/a") == ["s1"])
        #expect(try await !checked.index.isComplete())
    }

    @Test("X6: a stream whose target dies throws, drops its next chunk, refuses its final, and harms nothing after")
    func x6DeadTargetMidStream() async throws {
        let checked = try CheckedIndex()
        let s1 = try snap("s1", 1_000_000), s2 = try snap("s2", 2_000_000), s3 = try snap("s3", 3_000_000)
        try checked.reconcile([s1])
        try checked.runToDone(["s1": ["/r": true, "/r/a": false]])
        try checked.reconcile([s1, s2])
        try checked.beginFull("s2")
        try checked.chunk("s2", [entry("/r", true), entry("/r/a")], final: false)
        try checked.reconcile([s1])
        try checked.housekeeping()
        #expect(throws: IndexError.unknownSnapshot("s2")) { try checked.chunk("s2", [entry("/r/b")], final: false) }
        try checked.chunk("s2", [entry("/r/c")], final: false)
        #expect(throws: IndexError.poisonedStream("s2")) { try checked.chunk("s2", [], final: true) }
        try checked.reconcile([s1, s3])
        let trace = try checked.runToDone(["s1": ["/r": true, "/r/a": false], "s3": ["/r": true, "/r/z": false]])
        #expect(trace == ["delta(s3<-s1)"])
        #expect(try await checked.index.versionIDs("/r/z") == ["s3"])
        #expect(try await checked.index.searchPaths(matching: "b", limit: 10).isEmpty)
        #expect(try await checked.index.isComplete())
    }

    @Test("X7: a dead window end closed by a full compare is queued, and its garbage collected at the next housekeeping")
    func x7DeadHiQueued() async throws {
        let checked = try CheckedIndex()
        let s1 = try snap("s1", 1_000_000), s2 = try snap("s2", 2_000_000), s3 = try snap("s3", 3_000_000)
        let q1 = try snap("q1", 1_500_000, tags: [otherPlan]), q2 = try snap("q2", 2_500_000, tags: [otherPlan])
        let contents: [String: IndexContent] = [
            "s1": ["/r": true], "s2": ["/r": true, "/r/newt": false], "s3": ["/r": true],
            "q1": ["/r": true, "/r/q": false], "q2": ["/r": true],
        ]
        try checked.reconcile([s1, s2, q1, q2])
        try checked.runToDone(contents)
        try checked.reconcile([s1, q1, q2])            // s2, plan A's hi, dies
        try checked.housekeeping()                     // /r/newt's TOP run describes hi: kept
        try checked.reconcile([s1, s3, q1, q2])
        let trace = try checked.runToDone(contents)
        #expect(trace == ["full(s3)"])
        let queued = try checked.index.violations(afterHousekeeping: true)
        #expect(queued.contains { $0.hasPrefix("(a) hk_pending rows: 1") }, "\(queued)")
        #expect(queued.contains { $0.hasPrefix("(b) closed runs claiming no indexed snapshot: 1") }, "\(queued)")
        try checked.reconcile([s1, s3, q1])            // an unrelated death triggers housekeeping
        try checked.housekeeping()
        #expect(try await checked.index.searchPaths(matching: "newt", limit: 10).isEmpty)
        #expect(try await checked.index.versionIDs("/r/newt").isEmpty)
    }

    @Test("X8: after a failed chunk, later chunks and the final never index a partial listing; a re-read indexes it all")
    func x8PoisonedStream() async throws {
        let checked = try CheckedIndex()
        try checked.reconcile([try snap("s1", 1_000_000)])
        let chunk1 = [entry("/r", true), entry("/r/b", true), entry("/r/b/f1")]
        let chunk2 = [entry("/r/b/c", true), entry("/r/b/c/boom")]
        let chunk3 = [entry("/r/b/c/g"), entry("/r/b/d", true), entry("/r/b/d/h")]
        let truth = Set((chunk1 + chunk2 + chunk3).map(\.path))
        try checked.beginFull("s1")
        try checked.chunk("s1", chunk1, final: false)
        try Self.armBoomTrigger(checked.path)
        #expect(throws: (any Error).self) { try checked.chunk("s1", chunk2, final: false) }
        try Self.disarmBoomTrigger(checked.path)
        // A caller that ignores the error and keeps feeding: dropped, then
        // the final is refused.
        try checked.chunk("s1", chunk3, final: false)
        #expect(throws: IndexError.poisonedStream("s1")) { try checked.chunk("s1", [], final: true) }
        #expect(try await !checked.index.isComplete())
        #expect(try await checked.index.contains(paths: Array(truth), inSnapshot: "s1").isEmpty)

        try checked.beginFull("s1")
        try checked.chunk("s1", chunk1 + chunk2 + chunk3, final: false)
        try checked.chunk("s1", [], final: true)
        #expect(Set(try await checked.index.contains(paths: Array(truth), inSnapshot: "s1").keys) == truth.pathKeys)
        #expect(try await checked.index.isComplete())
    }

    // MARK: - N14: abandoned-stage GC

    @Test("N14: the next beginFull collects a cancelled stream's run-less nodes with their FTS rows")
    func n14CancelledStreamCollected() async throws {
        let checked = try CheckedIndex()
        let s1 = try snap("s1", 1_000_000), s2 = try snap("s2", 2_000_000)
        let b1 = try snap("b1", 3_000_000, tags: [otherPlan])
        try checked.reconcile([s1])
        try checked.full("s1", [entry("/r", true), entry("/r/kept")])
        try checked.reconcile([s1, s2, b1])
        try checked.beginFull("s2")
        try checked.chunk("s2", [entry("/r", true), entry("/r/kept"), entry("/r/abandoned", true), entry("/r/abandoned/leaf")], final: false)
        // Cancelled here. The staged nodes hold stage rows, so (i) is clean
        // until the stage is cleared — which beginFull does, collecting them.
        try checked.full("b1", [entry("/b", true)])
        // The FTS check (h) runs after every write, and (i) would name any
        // node left without a run, child or stage row.
        #expect(try await checked.index.searchPaths(matching: "abandoned", limit: 10).isEmpty)
        #expect(try await checked.index.versionIDs("/r/kept") == ["s1"])
    }

    @Test("N14: a stream whose target dies midway leaves no run-less node after the next beginFull")
    func n14DeadTargetStreamCollected() async throws {
        let checked = try CheckedIndex()
        let s1 = try snap("s1", 1_000_000), s2 = try snap("s2", 2_000_000), s3 = try snap("s3", 3_000_000)
        try checked.reconcile([s1])
        try checked.full("s1", [entry("/r", true)])
        try checked.reconcile([s1, s2])
        try checked.beginFull("s2")
        try checked.chunk("s2", [entry("/r", true), entry("/r/orphan", true), entry("/r/orphan/x")], final: false)
        try checked.reconcile([s1, s3])
        try checked.housekeeping()
        // A full read on purpose: the planner would offer s3 as a delta from
        // s1, and only beginFull clears the stage. After it, (i) names any
        // staged node that was not collected.
        try checked.full("s3", [entry("/r", true), entry("/r/new")])
        #expect(try await checked.index.versionIDs("/r/new") == ["s3"])
        #expect(try await checked.index.searchPaths(matching: "orphan", limit: 10).isEmpty)
    }

    @Test("risk 8: a reopen during a stream leaves its new nodes behind, which check (i) reports")
    func reopenMidStreamLeavesOrphans() async throws {
        let checked = try CheckedIndex()
        try checked.reconcile([try snap("s1", 1_000_000), try snap("s2", 2_000_000)])
        try checked.full("s2", [entry("/r", true)])
        try checked.beginFull("s1")
        try checked.chunk("s1", [entry("/r", true), entry("/r/lost")], final: false)
        try checked.reopen()
        // The session went with the connection, and so did the stage.
        #expect(throws: IndexError.noSession("s1")) {
            try checked.index.ingestFull(snapshotID: "s1", entries: [], final: true)
        }
        let found = try checked.index.violations(afterHousekeeping: false)
        #expect(found == ["(i) nodes with no run, child or stage row: 1"])
        // Answers are unaffected: the orphan is claimed by nothing.
        #expect(try await checked.index.searchPaths(matching: "lost", limit: 10).isEmpty)
        checked.excusing = ["i"]
        try checked.runToDone(["s1": ["/r": true, "/r/lost": false], "s2": ["/r": true]])
        #expect(try await checked.index.versionIDs("/r/lost") == ["s1"])
        // The re-read adopted the node, so nothing is left to excuse.
        #expect(try checked.index.violations(afterHousekeeping: false).isEmpty)
    }

    // MARK: - N10: schema check at open

    @Test("N10: a file with another user_version is refused with the pool closed; deleted and reopened, it is empty and complete once a listing lands")
    func n10SchemaMismatch() async throws {
        let fixture = try IndexFixture()
        _ = try fixture.index.reconcile(listing: [try snap("s1", 1_000_000)])
        try fixture.index.ingestWhole("s1", [entry("/r", true)])
        try fixture.index.close()
        let side = try DatabaseQueue(path: fixture.path)
        try await side.write { try $0.execute(sql: "PRAGMA user_version = 99") }
        try side.close()

        #expect(throws: IndexError.schemaMismatch(found: 99)) { _ = try SnapshotIndex(path: fixture.path) }
        // The coordinator's recovery: delete the file with its sidecars and
        // open again.
        IndexCoordinator.removeIndexFiles(at: URL(fileURLWithPath: fixture.path))
        let rebuilt = try SnapshotIndex(path: fixture.path)
        // Empty, and not complete: it has read nothing of the repository.
        #expect(try await !rebuilt.isComplete())
        #expect(try rebuilt.nextStep() == .done)
        #expect(try await rebuilt.versionIDs("/r").isEmpty)
        _ = try rebuilt.reconcile(listing: [])
        #expect(try await rebuilt.isComplete())
        try rebuilt.close()
    }

    @Test("N10: the old store's file (user_version 0 over existing tables) is refused, not adopted")
    func n10OldFormatRefused() throws {
        let fixture = try IndexFixture()
        try fixture.index.close()
        IndexCoordinator.removeIndexFiles(at: URL(fileURLWithPath: fixture.path))
        // The earlier index's shape: GRDB's migrator kept its history in a
        // table and never set user_version.
        let old = try DatabaseQueue(path: fixture.path)
        try old.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "CREATE TABLE snapshot (id TEXT PRIMARY KEY, chain TEXT NOT NULL, seq INTEGER NOT NULL)")
        }
        try old.close()
        #expect(throws: IndexError.schemaMismatch(found: 0)) { _ = try SnapshotIndex(path: fixture.path) }
    }
}
