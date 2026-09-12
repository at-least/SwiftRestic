import Foundation
import Testing

/// The run semantics of the snapshot index, against an in-memory store.
/// These tests are the contract `IndexSchema.swift` documents in prose: seq
/// is arrival order and stable, runs merge only across exact adjacency, a
/// gap never reads as coverage, and dead snapshots keep their runs.
@Suite("index store")
struct IndexStoreTests {
    private func makeStore() throws -> SQLiteIndexStore {
        try SQLiteIndexStore(path: nil)
    }

    private func snapshot(_ id: String, time: Date, tags: [String] = []) -> Snapshot {
        // Snapshot decodes from restic JSON; the tests build it through a
        // throwaway JSON document so the model's own defaults apply.
        let document: [String: Any] = [
            "id": id,
            "short_id": String(id.prefix(8)),
            "time": time.timeIntervalSince1970,
            "paths": ["/data"],
            "tags": tags,
        ]
        let data = try! JSONSerialization.data(withJSONObject: document)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try! decoder.decode(Snapshot.self, from: data)
    }

    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)
    private let t2 = Date(timeIntervalSince1970: 3_000)

    private let planTag = "swiftrestic-plan-aaaa1111aaaa1111aaaa1111aaaa1111"
    private let otherPlanTag = "swiftrestic-plan-bbbb2222bbbb2222bbbb2222bbbb2222"

    @Test("reconcile groups plan-tagged snapshots into chains, the rest into singletons")
    func reconcileChainAssignment() throws {
        let store = try makeStore()
        let outcome = try store.reconcile(aliveSnapshots: [
            snapshot("old", time: t0, tags: [planTag]),
            snapshot("new", time: t1, tags: [planTag]),
            snapshot("ext", time: t1, tags: ["user-tag"]),
            snapshot("other", time: t2, tags: [otherPlanTag]),
        ])

        #expect(outcome.added.sorted() == ["ext", "new", "old", "other"].sorted())
        // Plan chain: two members, seq follows time. Singleton chains: seq 1.
        #expect(try store.pendingBackfill(limit: 100).count == 4)
        let pending = try store.pendingBackfill(limit: 100)
        let byID = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0) })
        #expect(byID["old"]?.chain == planTag)
        #expect(byID["old"]?.seq == 1)
        #expect(byID["new"]?.chain == planTag)
        #expect(byID["new"]?.seq == 2)
        #expect(byID["ext"]?.chain == "snap:ext")
        #expect(byID["ext"]?.seq == 1)
        #expect(byID["other"]?.seq == 1)
        #expect(pending.allSatisfy { $0.coverage == .none && $0.alive })
    }

    @Test("reconcile is idempotent: a second pass over the same listing changes nothing")
    func reconcileIdempotent() throws {
        let store = try makeStore()
        let listing = [
            snapshot("old", time: t0, tags: [planTag]),
            snapshot("new", time: t1, tags: [planTag]),
        ]
        _ = try store.reconcile(aliveSnapshots: listing)
        let second = try store.reconcile(aliveSnapshots: listing)
        #expect(second == ReconcileOutcome())
        #expect(try store.pendingBackfill(limit: 100).count == 2)
    }

    @Test("a vanished snapshot dies, and coming back revives it with its seq intact")
    func dieAndRevive() throws {
        let store = try makeStore()
        _ = try store.reconcile(aliveSnapshots: [snapshot("old", time: t0, tags: [planTag])])
        _ = try store.reconcile(aliveSnapshots: [
            snapshot("old", time: t0, tags: [planTag]),
            snapshot("new", time: t1, tags: [planTag]),
        ])

        // prune removed the older one
        let died = try store.reconcile(aliveSnapshots: [snapshot("new", time: t1, tags: [planTag])])
        #expect(died.died == ["old"])
        #expect(try store.pendingBackfill(limit: 100).map(\.id) == ["new"])

        // the repository came back and restic lists it again
        let revived = try store.reconcile(aliveSnapshots: [
            snapshot("old", time: t0, tags: [planTag]),
            snapshot("new", time: t1, tags: [planTag]),
        ])
        #expect(revived.revived == ["old"])
        let pending = try store.pendingBackfill(limit: 100)
        #expect(pending.first { $0.id == "old" }?.seq == 1)
    }

    @Test("a back-dated snapshot appends a later seq: seq is arrival order, not time")
    func backDatedAppends() throws {
        let store = try makeStore()
        _ = try store.reconcile(aliveSnapshots: [
            snapshot("a", time: t1, tags: [planTag]),
            snapshot("b", time: t2, tags: [planTag]),
        ])
        _ = try store.reconcile(aliveSnapshots: [
            snapshot("a", time: t1, tags: [planTag]),
            snapshot("b", time: t2, tags: [planTag]),
            // arrived late, timestamped before both — still seq 3
            snapshot("late", time: t0, tags: [planTag]),
        ])
        let pending = try store.pendingBackfill(limit: 100)
        #expect(pending.first { $0.id == "late" }?.seq == 3)
    }

    @Test("recording content merges runs across both adjacent neighbors")
    func runMergeAcrossNeighbors() throws {
        let store = try makeStore()
        _ = try store.reconcile(aliveSnapshots: [
            snapshot("s1", time: t0, tags: [planTag]),
            snapshot("s2", time: t1, tags: [planTag]),
            snapshot("s3", time: t2, tags: [planTag]),
        ])
        try store.recordContent(snapshotID: "s1", paths: ["/data/a.txt"], final: true)
        try store.recordContent(snapshotID: "s3", paths: ["/data/a.txt"], final: true)

        // s2 filled in late: both neighbors merge into one run [1, 3]
        try store.recordContent(snapshotID: "s2", paths: ["/data/a.txt"], final: true)
        #expect(try store.versions(ofPath: "/data/a.txt").map(\.id) == ["s3", "s2", "s1"])

        // and the runs really merged: exactly one entry row covers the path
        let rows = try store.readEntryCount(ofPath: "/data/a.txt", chain: planTag)
        #expect(rows == 1)
    }

    @Test("a gap between runs never reads as coverage")
    func gapStaysAGap() throws {
        let store = try makeStore()
        _ = try store.reconcile(aliveSnapshots: [
            snapshot("s1", time: t0, tags: [planTag]),
            snapshot("s2", time: t1, tags: [planTag]),
            snapshot("s3", time: t2, tags: [planTag]),
        ])
        try store.recordContent(snapshotID: "s1", paths: ["/data/a.txt"], final: true)
        try store.recordContent(snapshotID: "s3", paths: ["/data/a.txt"], final: true)

        // s2 deleted the file: no run may cover seq 2
        #expect(try store.versions(ofPath: "/data/a.txt").map(\.id) == ["s3", "s1"])
        let rows = try store.readEntryCount(ofPath: "/data/a.txt", chain: planTag)
        #expect(rows == 2)
    }

    @Test("recording content twice changes nothing, and only the final chunk marks coverage")
    func chunkedIdempotent() throws {
        let store = try makeStore()
        _ = try store.reconcile(aliveSnapshots: [snapshot("s1", time: t0, tags: [planTag])])
        try store.recordContent(snapshotID: "s1", paths: ["/data/a"], final: false)
        try store.recordContent(snapshotID: "s1", paths: ["/data/b"], final: true)
        #expect(try store.pendingBackfill(limit: 100).isEmpty)

        // re-recording the same snapshot is a no-op
        try store.recordContent(snapshotID: "s1", paths: ["/data/a", "/data/b"], final: true)
        #expect(try store.versions(ofPath: "/data/a").count == 1)
        #expect(try store.versions(ofPath: "/data/b").count == 1)
    }

    @Test("content for an unknown snapshot is refused, not silently dropped")
    func unknownSnapshotThrows() throws {
        let store = try makeStore()
        #expect(throws: IndexError.unknownSnapshot("ghost")) {
            try store.recordContent(snapshotID: "ghost", paths: ["/data/a"], final: true)
        }
    }

    @Test("versions answers only alive snapshots, newest first, across chains")
    func versionsAcrossChains() throws {
        let store = try makeStore()
        _ = try store.reconcile(aliveSnapshots: [
            snapshot("plan-new", time: t2, tags: [planTag]),
            snapshot("plan-old", time: t0, tags: [planTag]),
            snapshot("ext", time: t1, tags: []),
        ])
        for id in ["plan-new", "plan-old", "ext"] {
            try store.recordContent(snapshotID: id, paths: ["/data/shared.bin"], final: true)
        }
        // prune took the external snapshot away
        _ = try store.reconcile(aliveSnapshots: [
            snapshot("plan-new", time: t2, tags: [planTag]),
            snapshot("plan-old", time: t0, tags: [planTag]),
        ])
        #expect(try store.versions(ofPath: "/data/shared.bin").map(\.id) == ["plan-new", "plan-old"])
    }

    // MARK: - Diff apply

    @Test("applyDelta extends the unchanged, opens the added, leaves the removed closed")
    func applyDeltaSemantics() throws {
        let store = try makeStore()
        _ = try store.reconcile(aliveSnapshots: [
            snapshot("s1", time: t0, tags: [planTag]),
            snapshot("s2", time: t1, tags: [planTag]),
        ])
        try store.recordContent(
            snapshotID: "s1",
            paths: ["/data/kept.txt", "/data/modified.txt", "/data/gone.txt", "/data"],
            final: true
        )

        // diff s1 -> s2: modified.txt's content changed (existence unchanged),
        // gone.txt disappeared, new.txt appeared, a directory arrived —
        // spelled the way restic spells directories in diffs, trailing slash.
        try store.applyDelta(
            snapshotID: "s2",
            previousSeq: 1,
            added: ["/data/new.txt", "/data/newdir/"],
            removed: ["/data/gone.txt"]
        )

        #expect(try store.versions(ofPath: "/data/kept.txt").map(\.id) == ["s2", "s1"])
        #expect(try store.versions(ofPath: "/data/modified.txt").map(\.id) == ["s2", "s1"])
        #expect(try store.versions(ofPath: "/data/gone.txt").map(\.id) == ["s1"])
        #expect(try store.versions(ofPath: "/data/new.txt").map(\.id) == ["s2"])
        #expect(try store.versions(ofPath: "/data/newdir").map(\.id) == ["s2"])

        // The extended ones merged; only the added pair and the dead run remain.
        let planChain = planTag
        #expect(try store.readEntryCount(ofPath: "/data/kept.txt", chain: planChain) == 1)
        #expect(try store.readEntryCount(ofPath: "/data/gone.txt", chain: planChain) == 1)
        #expect(try store.readEntryCount(ofPath: "/data/newdir", chain: planChain) == 1)

        // A delta-applied snapshot reads as delta coverage, not pending.
        #expect(try store.pendingBackfill(limit: 100).isEmpty)
    }

    @Test("predecessor lookup answers only pending, alive snapshots with an indexed neighbor")
    func predecessorForDelta() throws {
        let store = try makeStore()
        _ = try store.reconcile(aliveSnapshots: [
            snapshot("s1", time: t0, tags: [planTag]),
            snapshot("s2", time: t1, tags: [planTag]),
            snapshot("s3", time: t2, tags: [planTag]),
            snapshot("lone", time: t2, tags: [otherPlanTag]),
        ])
        try store.recordContent(snapshotID: "s1", paths: ["/data"], final: true)

        // s2: pending, and s1 is indexed — the diff can build it.
        let predecessor = try store.predecessorForDelta(of: "s2")
        #expect(predecessor?.id == "s1")

        // Once s2 is read, it is no longer a candidate itself.
        try store.recordContent(snapshotID: "s2", paths: ["/data"], final: true)
        // s3's best predecessor is now s2 (highest indexed seq below).
        #expect(try store.predecessorForDelta(of: "s3")?.id == "s2")

        // First of its chain, never indexed: no diff route exists.
        #expect(try store.predecessorForDelta(of: "lone") == nil)
        // Unknown snapshot: nil, not a throw.
        #expect(try store.predecessorForDelta(of: "ghost") == nil)
    }
}
