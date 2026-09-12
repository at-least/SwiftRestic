import Foundation
import GRDB
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

    private func entry(_ path: String, dir: Bool = false) -> IndexedEntry {
        IndexedEntry(path: path, isDirectory: dir)
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
        try store.recordContent(snapshotID: "s1", entries: [entry("/data/a.txt")], final: true)
        try store.recordContent(snapshotID: "s3", entries: [entry("/data/a.txt")], final: true)

        // s2 filled in late: both neighbors merge into one run [1, 3]
        try store.recordContent(snapshotID: "s2", entries: [entry("/data/a.txt")], final: true)
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
        try store.recordContent(snapshotID: "s1", entries: [entry("/data/a.txt")], final: true)
        try store.recordContent(snapshotID: "s3", entries: [entry("/data/a.txt")], final: true)

        // s2 deleted the file: no run may cover seq 2
        #expect(try store.versions(ofPath: "/data/a.txt").map(\.id) == ["s3", "s1"])
        let rows = try store.readEntryCount(ofPath: "/data/a.txt", chain: planTag)
        #expect(rows == 2)
    }

    @Test("recording content twice changes nothing, and only the final chunk marks coverage")
    func chunkedIdempotent() throws {
        let store = try makeStore()
        _ = try store.reconcile(aliveSnapshots: [snapshot("s1", time: t0, tags: [planTag])])
        try store.recordContent(snapshotID: "s1", entries: [entry("/data/a")], final: false)
        try store.recordContent(snapshotID: "s1", entries: [entry("/data/b")], final: true)
        #expect(try store.pendingBackfill(limit: 100).isEmpty)

        // re-recording the same snapshot is a no-op
        try store.recordContent(snapshotID: "s1", entries: [entry("/data/a"), entry("/data/b")], final: true)
        #expect(try store.versions(ofPath: "/data/a").count == 1)
        #expect(try store.versions(ofPath: "/data/b").count == 1)
    }

    @Test("content for an unknown snapshot is refused, not silently dropped")
    func unknownSnapshotThrows() throws {
        let store = try makeStore()
        #expect(throws: IndexError.unknownSnapshot("ghost")) {
            try store.recordContent(snapshotID: "ghost", entries: [entry("/data/a")], final: true)
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
            try store.recordContent(snapshotID: id, entries: [entry("/data/shared.bin")], final: true)
        }
        // prune took the external snapshot away
        _ = try store.reconcile(aliveSnapshots: [
            snapshot("plan-new", time: t2, tags: [planTag]),
            snapshot("plan-old", time: t0, tags: [planTag]),
        ])
        #expect(try store.versions(ofPath: "/data/shared.bin").map(\.id) == ["plan-new", "plan-old"])
    }

    // MARK: - Version picking (the folder browser's selection rule)

    private func version(_ id: String) -> IndexedSnapshot {
        IndexedSnapshot(
            id: id, chain: planTag, seq: 0,
            time: Date(timeIntervalSince1970: 0), alive: true, coverage: .full
        )
    }

    @Test("preferredVersion lands on the newest and keeps the user's era when it still covers")
    func preferredVersionPicks() {
        let versions = [version("new"), version("mid"), version("old")]

        // Nothing chosen yet: the newest.
        #expect(versions.preferredVersion(previousID: nil)?.id == "new")
        #expect([IndexedSnapshot]().preferredVersion(previousID: nil) == nil)

        // Walking down into a folder keeps the era the user is reading…
        #expect(versions.preferredVersion(previousID: "mid")?.id == "mid")
        // …unless that snapshot does not cover the deeper path at all.
        #expect(versions.preferredVersion(previousID: "ghost")?.id == "new")
    }


    // MARK: - Search (FTS)

    @Test("search finds paths by basename, case-insensitively, prefix-wise")
    func searchFindsByBasename() throws {
        let store = try makeStore()
        _ = try store.reconcile(aliveSnapshots: [snapshot("s1", time: t0, tags: [planTag])])
        try store.recordContent(snapshotID: "s1", entries: [
            entry("/Users/x/Documents/Invoice-2026.pdf"),
            entry("/Users/x/Music/track 01.flac"),
            entry("/Users/x/Documents", dir: true),
        ], final: true)

        #expect(try store.searchPaths(matching: "invoice", limit: 10).map(\.path) == ["/Users/x/Documents/Invoice-2026.pdf"])
        // prefix on a partial token
        #expect(try store.searchPaths(matching: "inv", limit: 10).count == 1)
        // case-insensitive
        #expect(try store.searchPaths(matching: "INVOICE", limit: 10).count == 1)
        // directory basenames are searchable too
        #expect(try store.searchPaths(matching: "documents", limit: 10).map(\.path) == ["/Users/x/Documents"])
        // multiple tokens: both must match
        #expect(try store.searchPaths(matching: "invoice 2026", limit: 10).count == 1)
        // empty input matches nothing, not everything
        #expect(try store.searchPaths(matching: "   ", limit: 10).isEmpty)
        // metacharacters travel inside quotes, never as syntax
        #expect(try store.searchPaths(matching: "invoice*\" OR", limit: 10).isEmpty)
        // input that tokenizes to nothing matches nothing
        #expect(try store.searchPaths(matching: "\"", limit: 10).isEmpty)
    }

    @Test("diff-added paths become searchable, directories keep their kind")
    func deltaPopulatesSearch() throws {
        let store = try makeStore()
        _ = try store.reconcile(aliveSnapshots: [
            snapshot("s1", time: t0, tags: [planTag]),
            snapshot("s2", time: t1, tags: [planTag]),
        ])
        try store.recordContent(snapshotID: "s1", entries: [entry("/data/old.txt")], final: true)
        try store.applyDelta(
            snapshotID: "s2",
            previousSeq: 1,
            added: ["/data/report.pdf", "/data/reports/"],
            removed: []
        )

        let hits = try store.searchPaths(matching: "report", limit: 10)
        #expect(Set(hits.map(\.path)) == ["/data/report.pdf", "/data/reports"])
        #expect(hits.first { $0.path == "/data/reports" }?.isDirectory == true)
        #expect(hits.first { $0.path == "/data/report.pdf" }?.isDirectory == false)
    }

    @Test("a v1 database upgraded in place rebuilds its search table from entries")
    func migrationRebuildsSearch() throws {
        // Build a v1-era database by hand: schema v1 only, entries but no
        // search table — what an index from before this feature looks like.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dbPath = base.appendingPathComponent("repo.sqlite").path

        let legacy = try DatabaseQueue(path: dbPath)
        // The shipped v1 code created its tables through the migrator, which
        // records the migration in grdb_migrations — the upgrade path below
        // depends on that row existing.
        var legacyMigrator = DatabaseMigrator()
        legacyMigrator.registerMigration("index-v1") { db in
            try db.execute(sql: IndexSchema.v1)
        }
        try legacyMigrator.migrate(legacy)
        try legacy.write { db in
            try db.execute(
                sql: "INSERT INTO snapshot (id, chain, seq, time, alive, indexed) VALUES (?, ?, 1, ?, 1, 1)",
                arguments: ["aaa", "swiftrestic-plan-x", "2026-01-01T00:00:00.000"]
            )
            try db.execute(
                sql: "INSERT INTO entry (path, chain, first_seq, last_seq) VALUES (?, ?, 1, 1)",
                arguments: ["/old/path/report.docx", "swiftrestic-plan-x"]
            )
        }

        // Opening it migrates to v2 and backfills the search table.
        let store = try SQLiteIndexStore(path: dbPath)
        let hits = try store.searchPaths(matching: "report", limit: 10)
        #expect(hits.map(\.path) == ["/old/path/report.docx"])
        // Kind is unknown for rebuilt rows — the restore path resolves it.
        #expect(hits.first?.isDirectory == nil)
    }

    @Test("search over an empty index answers nothing")
    func searchEmptyIndex() throws {
        let store = try makeStore()
        #expect(try store.searchPaths(matching: "anything", limit: 10).isEmpty)
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
            entries: [entry("/data/kept.txt"), entry("/data/modified.txt"), entry("/data/gone.txt"), entry("/data", dir: true)],
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
        try store.recordContent(snapshotID: "s1", entries: [entry("/data")], final: true)

        // s2: pending, and s1 is indexed — the diff can build it.
        let predecessor = try store.predecessorForDelta(of: "s2")
        #expect(predecessor?.id == "s1")

        // Once s2 is read, it is no longer a candidate itself.
        try store.recordContent(snapshotID: "s2", entries: [entry("/data")], final: true)
        // s3's best predecessor is now s2 (highest indexed seq below).
        #expect(try store.predecessorForDelta(of: "s3")?.id == "s2")

        // First of its chain, never indexed: no diff route exists.
        #expect(try store.predecessorForDelta(of: "lone") == nil)
        // Unknown snapshot: nil, not a throw.
        #expect(try store.predecessorForDelta(of: "ghost") == nil)
    }

    @Test("a diff is refused when an unread alive snapshot sits in the span")
    func deltaRefusedAcrossGap() throws {
        let store = try makeStore()
        _ = try store.reconcile(aliveSnapshots: [
            snapshot("s1", time: t0, tags: [planTag]),
            snapshot("s2", time: t1, tags: [planTag]),
            snapshot("s3", time: t2, tags: [planTag]),
        ])
        try store.recordContent(snapshotID: "s1", entries: [entry("/data/a.txt")], final: true)

        // s2's read failed (a network blip, say). A diff s1 -> s3 would span
        // the unread s2 and assert existence there for every unchanged path —
        // exactly what a deletion in s2 would contradict.
        #expect(try store.predecessorForDelta(of: "s3") == nil)

        // A dead snapshot in the span is different: nothing queries the dead,
        // so the diff route stays open. s2 dies (pruned), s3 may now diff.
        _ = try store.reconcile(aliveSnapshots: [
            snapshot("s1", time: t0, tags: [planTag]),
            snapshot("s3", time: t2, tags: [planTag]),
        ])
        #expect(try store.predecessorForDelta(of: "s3")?.id == "s1")
    }
}
