import Foundation
import GRDB
import Testing

/// The snapshot index's contract, through its public API on a file-backed
/// store: chains, the one-step window, revival as a re-read, the planner's
/// order, the delta and full routes' refusals, housekeeping, and the reads.
/// No test names a seq: seqs are internal.
@Suite("snapshot index")
struct SnapshotIndexTests {
    private let t0: Int64 = 1_000_000_000
    private let t1: Int64 = 2_000_000_000
    private let t2: Int64 = 3_000_000_000
    private let t3: Int64 = 4_000_000_000
    private let planA = IndexTestData.planA
    private let planB = IndexTestData.planB

    private func snap(
        _ id: String,
        _ micros: Int64,
        tags: [String]? = nil,
        host: String? = "mac",
        paths: [String] = ["/data"]
    ) throws -> Snapshot {
        try IndexTestData.snapshot(id, micros: micros, tags: tags ?? [planA], hostname: host, paths: paths)
    }

    // MARK: - Reconcile

    @Test("plan-tagged snapshots share a chain; untagged ones chain by host and sorted paths")
    func reconcileChainAssignment() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let listing = [
            try snap("old", t0),
            try snap("new", t1),
            try snap("ext1", t0, tags: [], paths: ["/data", "/more"]),
            // The same lineage: restic groups by host and the set of paths.
            try snap("ext2", t1, tags: ["user-tag"], paths: ["/more", "/data"]),
            try snap("otherHost", t1, tags: [], host: "pc", paths: ["/data", "/more"]),
            try snap("otherPaths", t2, tags: [], paths: ["/data"]),
            try snap("other", t2, tags: [planB]),
        ]
        try index.reconcile(listing: listing)
        // One pending row per listed snapshot.
        #expect(try index.snapStates() == Dictionary(uniqueKeysWithValues: listing.map { ($0.id, SnapshotIndex.State.pending) }))

        let lineage = SnapshotIndex.chainKey(for: listing[2])
        #expect(SnapshotIndex.chainKey(for: listing[0]) == planA)
        #expect(SnapshotIndex.chainKey(for: listing[3]) == lineage)
        #expect(SnapshotIndex.chainKey(for: listing[4]) != lineage)
        #expect(SnapshotIndex.chainKey(for: listing[5]) != lineage)
        // The key carries its host and paths whole: a NUL separator would
        // have cut every untagged key to "lineage" at the binding.
        #expect(lineage.contains("mac") && lineage.contains("/more"))
        #expect(!lineage.contains("\u{0}"))

        // The grouping is visible in what indexing costs: one full read per
        // chain, a delta for each later member of one.
        let contents = Dictionary(uniqueKeysWithValues: listing.map { ($0.id, ["/data": true, "/data/f": false]) })
        let trace = try index.runToDone(contents)
        #expect(trace.filter { $0.hasPrefix("full(") }.count == 5, "trace: \(trace)")
        #expect(trace.filter { $0.hasPrefix("delta(") }.count == 2, "trace: \(trace)")

        #expect(try await index.versions(ofPath: "/data/f", inChain: planA).map(\.id) == ["new", "old"])
        #expect(try await index.versions(ofPath: "/data/f", inChain: lineage).map(\.id) == ["ext2", "ext1"])
        let hostKey = SnapshotIndex.chainKey(for: listing[4])
        #expect(try await index.versions(ofPath: "/data/f", inChain: hostKey).map(\.id) == ["otherHost"])
        #expect(try await index.versions(ofPath: "/data/f", inChain: planB).map(\.id) == ["other"])
        #expect(try await index.versions(ofPath: "/data/f", inChain: "swiftrestic-plan-unknown").isEmpty)
    }

    @Test("reconcile is idempotent: a second pass over the same listing changes nothing")
    func reconcileIdempotent() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let listing = [try snap("old", t0), try snap("new", t1)]
        try index.reconcile(listing: listing)
        let states = try index.snapStates()
        let second = try index.cost { try index.reconcile(listing: listing) }
        #expect(second.rows == 0, "the repeat wrote \(second)")
        #expect(try index.snapStates() == states)
        #expect(try await !index.isComplete())
        #expect(try index.nextStep() == .full(snapshotID: "new"))
    }

    @Test("a vanished snapshot loses its row; its return is a new pending row, read again, and exact after one step")
    func dieAndRevive() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let listing = [try snap("old", t0), try snap("new", t1)]
        _ = try index.reconcile(listing: listing)
        let content: IndexContent = ["/data": true, "/data/a": false]
        try index.runToDone(["old": content, "new": content])
        #expect(try await index.versionIDs("/data/a") == ["new", "old"])

        try index.reconcile(listing: [listing[1]])
        #expect(try index.snapStates()["old"] == nil)
        #expect(try await index.versionIDs("/data/a") == ["new"])

        try index.reconcile(listing: listing)
        // A return is a new row: pending, claimed by nothing, read again —
        // forward from `new`, because its fresh seq lies above the window.
        #expect(try index.snapStates()["old"] == SnapshotIndex.State.pending)
        #expect(try await !index.isComplete())
        #expect(try await index.versionIDs("/data/a") == ["new"])
        #expect(try index.nextStep() == .delta(snapshotID: "old", from: "new"))

        try index.runToDone(["old": content, "new": content])
        #expect(try await index.versionIDs("/data/a") == ["new", "old"])
        #expect(try await index.isComplete())
    }

    @Test("a back-dated snapshot arrives above the window and is read forward; versions stay in time order")
    func backDatedAppends() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let content: IndexContent = ["/data": true, "/data/x": false]
        _ = try index.reconcile(listing: [try snap("a", t1), try snap("b", t2)])
        try index.runToDone(["a": content, "b": content])

        _ = try index.reconcile(listing: [try snap("a", t1), try snap("b", t2), try snap("late", t0)])
        #expect(try index.nextStep() == .delta(snapshotID: "late", from: "b"))
        try index.runToDone(["a": content, "b": content, "late": content])
        #expect(try await index.versionIDs("/data/x") == ["b", "a", "late"])
    }

    // MARK: - Window discipline

    @Test("an ingest that would skip a pending snapshot is refused; in order, all land")
    func outOfOrderIngestRefused() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        _ = try index.reconcile(listing: [try snap("s1", t0), try snap("s2", t1), try snap("s3", t2)])
        let listing = IndexTestData.ls(["/data": true, "/data/a.txt": false])

        try index.ingestWhole("s1", listing)
        #expect(throws: IndexError.notAdjacent("s3")) { try index.ingestWhole("s3", listing) }
        try index.ingestWhole("s2", listing)
        #expect(try await index.versionIDs("/data/a.txt") == ["s2", "s1"])
        try index.ingestWhole("s3", listing)
        #expect(try await index.versionIDs("/data/a.txt") == ["s3", "s2", "s1"])
        #expect(try await index.isComplete())
    }

    @Test("a full read extends the window one step on either side; across a pending snapshot, on either side, it is notAdjacent")
    func fullAdjacencyBothSides() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let t4: Int64 = 5_000_000_000
        let ids = ["s1", "s2", "s3", "s4", "s5"]
        _ = try index.reconcile(listing: try zip(ids, [t0, t1, t2, t3, t4]).map { try snap($0, $1) })
        // A file every snapshot holds, and one only this snapshot holds: a
        // full read that closed or opened runs at the wrong window end would
        // hand one snapshot's own file to another, or lose it.
        func entries(of id: String) -> [IndexedEntry] {
            IndexTestData.ls(["/data": true, "/data/a.txt": false, "/data/only-\(id)": false])
        }
        try index.ingestWhole("s3", entries(of: "s3"))
        // Two steps up and two down cross the pending s4 and s2.
        #expect(throws: IndexError.notAdjacent("s5")) { try index.ingestWhole("s5", entries(of: "s5")) }
        #expect(throws: IndexError.notAdjacent("s1")) { try index.ingestWhole("s1", entries(of: "s1")) }
        // One step each way lands, and then the outer ones do.
        for id in ["s2", "s4", "s1", "s5"] { try index.ingestWhole(id, entries(of: id)) }
        #expect(try await index.versionIDs("/data/a.txt") == ["s5", "s4", "s3", "s2", "s1"])
        for id in ids { #expect(try await index.versionIDs("/data/only-\(id)") == [id]) }
        #expect(try await index.isComplete())
    }

    @Test("a gap never reads as coverage, and a dead middle snapshot is skipped before and after housekeeping")
    func gapStaysAGap() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let listing = [try snap("s1", t0), try snap("s2", t1), try snap("s3", t2)]
        _ = try index.reconcile(listing: listing)
        try index.runToDone([
            "s1": ["/data": true, "/data/a": false, "/data/b": false],
            "s2": ["/data": true, "/data/b": false],
            "s3": ["/data": true, "/data/a": false, "/data/b": false],
        ])
        #expect(try await index.versionIDs("/data/a") == ["s3", "s1"])
        #expect(try await index.versionIDs("/data/b") == ["s3", "s2", "s1"])

        _ = try index.reconcile(listing: [listing[0], listing[2]])
        #expect(try await index.versionIDs("/data/a") == ["s3", "s1"])
        #expect(try await index.versionIDs("/data/b") == ["s3", "s1"])
        try index.housekeeping()
        #expect(try await index.versionIDs("/data/a") == ["s3", "s1"])
        #expect(try await index.versionIDs("/data/b") == ["s3", "s1"])
        #expect(try index.violations(afterHousekeeping: true).isEmpty)
    }

    @Test("a stream stays pending until its final; a repeated read is a no-op; a final without a stream is refused")
    func chunkedIdempotent() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        _ = try index.reconcile(listing: [try snap("s1", t0)])
        try index.beginFull(snapshotID: "s1")
        try index.ingestFull(
            snapshotID: "s1",
            entries: [IndexedEntry(path: "/data", isDirectory: true), IndexedEntry(path: "/data/a", isDirectory: false)],
            final: false
        )
        #expect(try await !index.isComplete())
        #expect(try index.nextStep() == .full(snapshotID: "s1"))
        #expect(try await index.versionIDs("/data/a").isEmpty)
        try index.ingestFull(snapshotID: "s1", entries: [IndexedEntry(path: "/data/b", isDirectory: false)], final: true)
        #expect(try await index.isComplete())
        #expect(try await index.versionIDs("/data/a") == ["s1"])
        #expect(try await index.versionIDs("/data/b") == ["s1"])

        // Reading an indexed snapshot again teaches nothing: its chunks and
        // final are no-ops, even when they name a path it never held.
        try index.beginFull(snapshotID: "s1")
        try index.ingestFull(snapshotID: "s1", entries: [IndexedEntry(path: "/data/c", isDirectory: false)], final: false)
        try index.ingestFull(snapshotID: "s1", entries: [], final: true)
        #expect(try await index.versionIDs("/data/c").isEmpty)
        #expect(try await index.versionIDs("/data/a") == ["s1"])

        // With no stream begun, an empty final would read as an empty
        // snapshot and close every run: refused.
        #expect(throws: IndexError.noSession("s1")) {
            try index.ingestFull(snapshotID: "s1", entries: [], final: true)
        }
    }

    @Test("writes naming an unknown snapshot are refused, not silently dropped")
    func unknownSnapshotThrows() throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        _ = try index.reconcile(listing: [try snap("s1", t0)])
        #expect(throws: IndexError.unknownSnapshot("ghost")) { try index.beginFull(snapshotID: "ghost") }
        #expect(throws: IndexError.noSession("ghost")) {
            try index.ingestFull(snapshotID: "ghost", entries: [], final: true)
        }
        #expect(throws: IndexError.unknownSnapshot("ghost")) {
            try index.ingestDiff(snapshotID: "ghost", from: "s1", added: [], removed: [])
        }
        try index.ingestWhole("s1", IndexTestData.ls(["/data": true]))
        _ = try index.reconcile(listing: [try snap("s1", t0), try snap("s2", t1)])
        #expect(throws: IndexError.unknownSnapshot("ghost")) {
            try index.ingestDiff(snapshotID: "s2", from: "ghost", added: [], removed: [])
        }
    }

    // MARK: - Reads

    @Test("versions answers listed indexed snapshots only, newest first across chains; equal times put the later arrival first")
    func versionsAcrossChains() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let listing = [try snap("plan-new", t2), try snap("plan-old", t0), try snap("ext", t1, tags: [])]
        _ = try index.reconcile(listing: listing)
        let content: IndexContent = ["/data": true, "/data/shared.bin": false]
        try index.runToDone(Dictionary(uniqueKeysWithValues: listing.map { ($0.id, content) }))
        #expect(try await index.versionIDs("/data/shared.bin") == ["plan-new", "ext", "plan-old"])

        _ = try index.reconcile(listing: [listing[0], listing[1]])
        #expect(try await index.versionIDs("/data/shared.bin") == ["plan-new", "plan-old"])

        // Equal times across chains: the later arrival first — "a-second"
        // arrived in a later listing, although its ID sorts first.
        let later = try IndexFixture()
        _ = try later.index.reconcile(listing: [try snap("b-first", t0)])
        _ = try later.index.reconcile(listing: [try snap("b-first", t0), try snap("a-second", t0, tags: [planB])])
        try later.index.runToDone(["b-first": content, "a-second": content])
        #expect(try await later.index.versionIDs("/data/shared.bin") == ["a-second", "b-first"])

        // Within one listing, arrivals are taken in (time, ID bytes) order.
        let same = try IndexFixture()
        _ = try same.index.reconcile(listing: [try snap("y", t0), try snap("x", t0, tags: [planB])])
        try same.index.runToDone(["x": content, "y": content])
        #expect(try await same.index.versionIDs("/data/shared.bin") == ["y", "x"])
    }

    /// Equal times are real: `restic rewrite` without `--forget` keeps the
    /// original beside a rewritten snapshot of the same time, and `restic
    /// copy` keeps times. The summary's newest must be the version the
    /// browser opens — `versions(ofPath:).first` — or a Find Files row names,
    /// and restores from, another snapshot than the one the browser shows.
    @Test("versionSummaries' newest breaks a time tie as versions does: the later arrival")
    func summariesTieMatchesVersions() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let content: IndexContent = ["/data": true, "/data/f": false]
        _ = try index.reconcile(listing: [try snap("b-first", t0)])
        _ = try index.reconcile(listing: [try snap("b-first", t0), try snap("a-second", t0, tags: [planB])])
        try index.runToDone(["b-first": content, "a-second": content])
        let versions = try await index.versions(ofPath: "/data/f")
        #expect(versions.map(\.id) == ["a-second", "b-first"])
        let summary = try #require(try await index.versionSummaries(ofPaths: ["/data/f"])["/data/f"])
        #expect(summary.newest == versions.first)
    }

    @Test("search's kind breaks a time tie as versions does: the later arrival's kind")
    func searchKindTieMatchesVersions() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        _ = try index.reconcile(listing: [try snap("b-first", t0)])
        _ = try index.reconcile(listing: [try snap("b-first", t0), try snap("a-second", t0, tags: [planB])])
        try index.runToDone([
            "b-first": ["/data": true, "/data/k": false],
            "a-second": ["/data": true, "/data/k": true],
        ])
        #expect(try await index.versionIDs("/data/k") == ["a-second", "b-first"])
        let hit = try await index.searchPaths(matching: "k", limit: 10).first { $0.path == "/data/k" }
        #expect(hit?.isDirectory == true)
    }

    @Test("versionSummaries agrees with versions per path, and omits unknown, misspelt and unheld paths")
    func summariesMatchSinglePath() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let listing = [try snap("s1", t0), try snap("s2", t1), try snap("s3", t2)]
        _ = try index.reconcile(listing: listing)
        try index.runToDone([
            "s1": ["/data": true, "/data/a.txt": false, "/data/b.txt": false],
            "s2": ["/data": true, "/data/a.txt": false],
            "s3": ["/data": true, "/data/a.txt": false, "/data/c.txt": false],
        ])
        let asked = [
            "/data/a.txt", "/data/b.txt", "/data/c.txt", "/data/never.indexed", "/data/a.txt/", "/data//a.txt", "/",
        ]
        let summaries = try await index.versionSummaries(ofPaths: asked)
        for path in ["/data/a.txt", "/data/b.txt", "/data/c.txt"] {
            let single = try await index.versions(ofPath: path)
            #expect(summaries[PathKey(path)] == single.first.map { VersionSummary(count: single.count, newest: $0) }, "\(path)")
        }
        #expect(summaries["/data/a.txt"]?.count == 3)
        #expect(Set(summaries.keys) == ["/data/a.txt", "/data/b.txt", "/data/c.txt"])

        // A path whose only snapshot left the listing has no summary.
        _ = try index.reconcile(listing: [listing[1], listing[2]])
        #expect(try await index.versionSummaries(ofPaths: ["/data/b.txt"]).isEmpty)
    }

    @Test("versionSummaries crosses the lookup chunk without losing paths")
    func summariesCrossChunkBoundary() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        _ = try index.reconcile(listing: [try snap("s1", t0)])
        let all = (0 ..< SnapshotIndex.lookupChunk + 50).map { "/many/entry-\($0)" }
        try index.ingestWhole("s1", [IndexedEntry(path: "/many", isDirectory: true)] + all.map {
            IndexedEntry(path: $0, isDirectory: false)
        })

        // Fifty paths past a full lookup chunk, whatever its size: the second
        // chunk must land every path the first did not.
        let summaries = try await index.versionSummaries(ofPaths: all)
        #expect(Set(summaries.keys) == all.pathKeys)
        #expect(summaries.values.allSatisfy { $0.count == 1 && $0.newest.id == "s1" })
    }

    /// The Restore pane asks `contains` for every hit of a search, up to the
    /// search's ceiling — far past one chunk.
    @Test("contains crosses the lookup chunk without losing paths")
    func containsCrossesChunkBoundary() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        _ = try index.reconcile(listing: [try snap("s1", t0)])
        let all = (0 ..< SnapshotIndex.lookupChunk + 50).map { "/many/entry-\($0)" }
        try index.ingestWhole("s1", [IndexedEntry(path: "/many", isDirectory: true)] + all.map {
            IndexedEntry(path: $0, isDirectory: false)
        })
        let held = try await index.contains(paths: all, inSnapshot: "s1")
        #expect(Set(held.keys) == all.pathKeys)
        #expect(held.values.allSatisfy { $0 == false })
    }

    @Test("contains answers each path's kind in that snapshot, and nothing for a pending or unknown one")
    func containsKindInSnapshot() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        _ = try index.reconcile(listing: [try snap("s1", t0), try snap("s2", t1)])
        try index.runToDone([
            "s1": ["/data": true, "/data/k": false],
            "s2": ["/data": true, "/data/k": true, "/data/k/c": false],
        ])
        #expect(try await index.contains(paths: ["/data/k", "/data/k/c", "/data/none"], inSnapshot: "s1") == ["/data/k": false])
        #expect(try await index.contains(paths: ["/data/k", "/data/k/c"], inSnapshot: "s2") == ["/data/k": true, "/data/k/c": false])
        #expect(try await index.contains(paths: ["/data/k"], inSnapshot: "ghost").isEmpty)
        _ = try index.reconcile(listing: [try snap("s1", t0), try snap("s2", t1), try snap("s3", t2)])
        #expect(try await index.contains(paths: ["/data/k"], inSnapshot: "s3").isEmpty)
    }

    /// Node lookup is byte-exact, while Swift's `==` on String is canonical
    /// equivalence: the NFC and NFD spellings of one name are equal Strings
    /// and two different paths to restic. A batched read asked for both must
    /// still look up the one the index holds, in whichever order they come.
    @Test("a batched read that also names a canonically equal twin still answers the spelling the index holds")
    func batchedReadsKeepByteDistinctSpellings() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        _ = try index.reconcile(listing: [try snap("s1", t0)])
        let nfd = "/d/e\u{301}"   // the only spelling the index holds: 65 CC 81
        let nfc = "/d/\u{e9}"     // Swift calls it equal; its bytes, C3 A9, name no node
        try index.ingestWhole("s1", [IndexedEntry(path: "/d", isDirectory: true), IndexedEntry(path: nfd, isDirectory: false)])
        #expect(try await index.versionIDs(nfd) == ["s1"])
        #expect(try await index.versionIDs(nfc).isEmpty)
        for asked in [[nfc, nfd], [nfd, nfc]] {
            #expect(try await index.versionSummaries(ofPaths: asked).count == 1, "\(asked.map { Array($0.utf8) })")
            #expect(try await index.contains(paths: asked, inSnapshot: "s1").count == 1, "\(asked.map { Array($0.utf8) })")
        }
    }

    /// Two byte-distinct, canonically equivalent paths are two nodes with
    /// their own answers. Keyed by `String`, whose keys compare canonically,
    /// one entry would stand for both, so a Restore pane reading
    /// `inRecord[hit.path]` would miss one hit and invent the other; the
    /// keyed reads therefore return `PathKey`s, which compare bytes. This
    /// pins that they keep the two apart.
    @Test("canonically equivalent, byte-distinct paths keep their own answers in the keyed reads")
    func keyedReadsKeepByteDistinctSpellings() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let nfc = "/data/caf\u{e9}"      // … 66 C3 A9
        let nfd = "/data/cafe\u{301}"    // … 66 65 CC 81
        _ = try index.reconcile(listing: [try snap("s1", t0, tags: [planA]), try snap("s2", t1, tags: [planB])])
        // Two chains, full builds only: IndexTestData.diff is String-keyed and would merge the spellings.
        try index.ingestWhole("s1", [IndexedEntry(path: "/data", isDirectory: true), IndexedEntry(path: nfc, isDirectory: false)])
        try index.ingestWhole("s2", [IndexedEntry(path: "/data", isDirectory: true), IndexedEntry(path: nfd, isDirectory: true)])
        #expect(try await index.versionIDs(nfc) == ["s1"])
        #expect(try await index.versionIDs(nfd) == ["s2"])
        let hits = try await index.searchPaths(matching: "caf", limit: 10)
        #expect(hits.count == 2)
        let paths = hits.map(\.path)
        let inS1 = try await index.contains(paths: paths, inSnapshot: "s1")
        let inS2 = try await index.contains(paths: paths, inSnapshot: "s2")
        let summaries = try await index.versionSummaries(ofPaths: paths)
        // The Restore pane's reading: a hit is in the open backup iff
        // inRecord[hit.path] != nil.
        #expect(hits.filter { inS1[PathKey($0.path)] != nil }.map { Array($0.path.utf8) } == [Array(nfc.utf8)])
        #expect(hits.filter { inS2[PathKey($0.path)] != nil }.map { Array($0.path.utf8) } == [Array(nfd.utf8)])
        #expect(summaries[PathKey(nfc)]?.newest.id == "s1")
        #expect(summaries[PathKey(nfd)]?.newest.id == "s2")
        // The searches' own reads keep them apart the same way.
        let viaSearch = try await index.searchWithMembership(matching: "caf", limit: 10, inSnapshot: "s1")
        #expect(viaSearch.inSnapshot == inS1)
        #expect(viaSearch.inSnapshot.count == 1)
        let summarized = try await index.searchWithSummaries(matching: "caf", limit: 10)
        #expect(summarized.summaries == summaries)
        #expect(summarized.summaries.count == 2)
    }

    // MARK: - Version picking (the Files view's selection rule)

    private func version(_ id: String) -> IndexVersion {
        IndexVersion(id: id, time: Date(timeIntervalSince1970: 0))
    }

    @Test("preferredVersion lands on the newest and keeps the user's era when it still covers")
    func preferredVersionPicks() {
        let versions = [version("new"), version("mid"), version("old")]
        #expect(versions.preferredVersion(previousID: nil)?.id == "new")
        #expect([IndexVersion]().preferredVersion(previousID: nil) == nil)
        #expect(versions.preferredVersion(previousID: "mid")?.id == "mid")
        #expect(versions.preferredVersion(previousID: "ghost")?.id == "new")
    }

    @Test("a pane opens at the era one level up when it holds the item, else where the item was last left, else the newest")
    func preferredVersionRemembers() {
        let versions = [version("new"), version("mid"), version("old")]
        #expect(versions.preferredVersion(previousID: nil, rememberedID: "old")?.id == "old")
        #expect(versions.preferredVersion(previousID: "mid", rememberedID: "old")?.id == "mid")
        // An era the item was absent from, or a forgotten backup, gives way.
        #expect(versions.preferredVersion(previousID: "ghost", rememberedID: "old")?.id == "old")
        #expect(versions.preferredVersion(previousID: "ghost", rememberedID: "gone")?.id == "new")

        // A file's versions, by the same rule: one level up names a backup
        // inside a version, the memory names a version.
        let contents = [
            ContentVersion(snapshots: [version("b4"), version("b3")], since: .changed),
            ContentVersion(snapshots: [version("b2")], since: .uncertain),
            ContentVersion(snapshots: [version("b1")], since: nil),
        ]
        #expect(contents.preferredVersion(previousID: nil, rememberedID: nil)?.id == "b4")
        #expect(contents.preferredVersion(previousID: "b3", rememberedID: "b1")?.id == "b4")
        #expect(contents.preferredVersion(previousID: "ghost", rememberedID: "b1")?.id == "b1")
        #expect(contents.preferredVersion(previousID: nil, rememberedID: "gone")?.id == "b4")
        #expect([ContentVersion]().preferredVersion(previousID: nil, rememberedID: "b1") == nil)
    }

    // MARK: - Search

    @Test("search finds paths by basename, case-insensitively, prefix-wise")
    func searchFindsByBasename() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        _ = try index.reconcile(listing: [try snap("s1", t0)])
        try index.ingestWhole("s1", IndexTestData.ls([
            "/Users": true, "/Users/x": true, "/Users/x/Documents": true, "/Users/x/Music": true,
            "/Users/x/Documents/Invoice-2026.pdf": false, "/Users/x/Music/track 01.flac": false,
        ]))

        #expect(try await index.searchPaths(matching: "invoice", limit: 10).map(\.path) == ["/Users/x/Documents/Invoice-2026.pdf"])
        #expect(try await index.searchPaths(matching: "inv", limit: 10).count == 1)
        #expect(try await index.searchPaths(matching: "INVOICE", limit: 10).count == 1)
        // The start of a word, never its middle: Find Files' caption says so.
        #expect(try await index.searchPaths(matching: "voice", limit: 10).isEmpty)
        let documents = try await index.searchPaths(matching: "documents", limit: 10)
        #expect(documents.map(\.path) == ["/Users/x/Documents"])
        #expect(documents.first?.isDirectory == true)
        #expect(try await index.searchPaths(matching: "invoice 2026", limit: 10).count == 1)
        #expect(try await index.searchPaths(matching: "   ", limit: 10).isEmpty)
        #expect(try await index.searchPaths(matching: "invoice*\" OR", limit: 10).isEmpty)
        #expect(try await index.searchPaths(matching: "\"", limit: 10).isEmpty)
        // A query with no term reads nothing, in the searches' reads too.
        #expect(try await index.searchWithSummaries(matching: "   ", limit: 10) == SearchWithSummaries(hits: [], summaries: [:]))
        #expect(try await index.searchWithMembership(matching: "\"", limit: 10, inSnapshot: "s1")
            == SearchWithMembership(hits: [], inSnapshot: [:]))
    }

    @Test("search orders by name then path, stops at exactly the limit, and never spends it on unheld paths")
    func searchOrderAndLimit() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let listing = [try snap("s1", t0), try snap("s2", t1)]
        _ = try index.reconcile(listing: listing)
        let full: IndexContent = [
            "/a": true, "/b": true, "/c": true,
            "/a/report": false, "/b/report": false, "/c/report": false, "/a/report-2": false,
        ]
        var later = full
        later["/a/report"] = nil
        try index.runToDone(["s1": full, "s2": later])

        #expect(try await index.searchPaths(matching: "report", limit: 10).map(\.path)
            == ["/a/report", "/b/report", "/c/report", "/a/report-2"])
        #expect(try await index.searchPaths(matching: "report", limit: 2).map(\.path) == ["/a/report", "/b/report"])

        // s1 leaves: /a/report is held by no listed snapshot, so it must not
        // take a slot — before housekeeping reclaims anything.
        _ = try index.reconcile(listing: [listing[1]])
        #expect(try await index.searchPaths(matching: "report", limit: 2).map(\.path) == ["/b/report", "/c/report"])
    }

    @Test("ties on a name are ordered by path bytes, NFD and NFC names staying distinct")
    func searchTiesByBytes() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        _ = try index.reconcile(listing: [try snap("s1", t0)])
        // "e\u{301}z" (65 CC 81 7A) sorts before "\u{e9}a" (C3 A9 61) by
        // bytes, and after it by Swift's String order.
        let nfd = "/d/e\u{301}z"
        let nfc = "/d/\u{e9}a"
        try index.ingestWhole("s1", [
            IndexedEntry(path: "/d", isDirectory: true),
            IndexedEntry(path: nfd, isDirectory: true),
            IndexedEntry(path: nfd + "/report", isDirectory: false),
            IndexedEntry(path: nfc, isDirectory: true),
            IndexedEntry(path: nfc + "/report", isDirectory: false),
        ])
        let hits = try await index.searchPaths(matching: "report", limit: 10)
        #expect(hits.map { Array($0.path.utf8) } == [Array((nfd + "/report").utf8), Array((nfc + "/report").utf8)])
    }

    @Test("diff-added paths become searchable, directories keep their kind")
    func deltaPopulatesSearch() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        _ = try index.reconcile(listing: [try snap("s1", t0), try snap("s2", t1)])
        try index.ingestWhole("s1", IndexTestData.ls(["/data": true, "/data/old.txt": false]))
        try index.ingestDiff(snapshotID: "s2", from: "s1", added: ["/data/report.pdf", "/data/reports/"], removed: [])

        let hits = try await index.searchPaths(matching: "report", limit: 10)
        #expect(Set(hits.map(\.path)) == ["/data/report.pdf", "/data/reports"])
        #expect(hits.first { $0.path == "/data/reports" }?.isDirectory == true)
        #expect(hits.first { $0.path == "/data/report.pdf" }?.isDirectory == false)
    }

    @Test("search over an empty index answers nothing")
    func searchEmptyIndex() async throws {
        let fixture = try IndexFixture()
        #expect(try await fixture.index.searchPaths(matching: "anything", limit: 10).isEmpty)
    }

    /// The Restore pane counts every hit the open backup lacks as held by
    /// another backup, without a second read: a hit has an indexed version
    /// by construction. Deaths before housekeeping leave exactly the rows
    /// that could break that — nodes only dead snapshots held, runs that
    /// claim nothing, a whole dead chain — so the pin runs there.
    @Test("every search hit has a version summary, even before housekeeping reclaims the dead")
    func searchHitsAreHeldSomewhere() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let listing = [
            try snap("s1", t0), try snap("s2", t1), try snap("s3", t2),
            try snap("u1", t1, tags: [], host: "other"),
        ]
        _ = try index.reconcile(listing: listing)
        try index.runToDone([
            "s1": ["/data": true, "/data/inv-1": false, "/data/inv-old": false],
            "s2": ["/data": true, "/data/inv-1": false, "/data/inv-2": true],
            "s3": ["/data": true, "/data/inv-2": true, "/data/inv-3": false],
            "u1": ["/data": true, "/data/inv-u": false],
        ])
        // s1 and the untagged chain's only snapshot leave; no housekeeping.
        _ = try index.reconcile(listing: [listing[1], listing[2]])
        let hits = try await index.searchPaths(matching: "inv", limit: 50)
        #expect(Set(hits.map(\.path)) == ["/data/inv-1", "/data/inv-2", "/data/inv-3"])
        let summaries = try await index.versionSummaries(ofPaths: hits.map(\.path))
        #expect(Set(summaries.keys) == hits.map(\.path).pathKeys)
        // Find Files' own read gives every one of those hits its summary.
        let found = try await index.searchWithSummaries(matching: "inv", limit: 50)
        #expect(found.hits == hits)
        #expect(Set(found.summaries.keys) == hits.map(\.path).pathKeys)
    }

    // MARK: - The searches' one read

    /// The Restore pane's read: the search and the open backup's membership
    /// in one transaction, keyed by node ids. It must answer exactly what the
    /// two path-keyed reads answer apart.
    @Test("searchWithMembership answers what searchPaths and contains answer apart; a pending, unknown or unlisted snapshot holds nothing")
    func searchWithMembershipMatchesTwoReads() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let listing = [try snap("s1", t0), try snap("s2", t1)]
        try index.reconcile(listing: listing)
        try index.runToDone([
            "s1": ["/data": true, "/data/k": false, "/data/k-old": false],
            "s2": ["/data": true, "/data/k": true, "/data/k/k-inner": false],
        ])
        let hits = try await index.searchPaths(matching: "k", limit: 10)
        #expect(hits.map(\.path) == ["/data/k", "/data/k/k-inner", "/data/k-old"])
        for snapshotID in ["s1", "s2", "ghost"] {
            let found = try await index.searchWithMembership(matching: "k", limit: 10, inSnapshot: snapshotID)
            let separate = try await index.contains(paths: hits.map(\.path), inSnapshot: snapshotID)
            #expect(found.hits == hits && found.hits.map(\.path) == hits.map(\.path), "\(snapshotID)")
            #expect(found.inSnapshot == separate, "\(snapshotID)")
        }
        // Each hit's kind in the open backup, not the search's: /data/k is a
        // folder in s2, the newest, and a file in s1.
        #expect(try await index.searchWithMembership(matching: "k", limit: 10, inSnapshot: "s1").inSnapshot
            == ["/data/k": false, "/data/k-old": false])
        #expect(try await index.searchWithMembership(matching: "k", limit: 10, inSnapshot: "s2").inSnapshot
            == ["/data/k": true, "/data/k/k-inner": false])

        // Listed but not read yet: the hits, and no membership.
        try index.reconcile(listing: listing + [try snap("s3", t2)])
        let pending = try await index.searchWithMembership(matching: "k", limit: 10, inSnapshot: "s3")
        #expect(pending.hits.map(\.path) == hits.map(\.path))
        #expect(pending.inSnapshot.isEmpty)
        // No longer listed: nothing either.
        try index.reconcile(listing: [listing[1]])
        #expect(try await index.searchWithMembership(matching: "k", limit: 10, inSnapshot: "s1").inSnapshot.isEmpty)
    }

    /// Find Files' read: the search and each hit's summary in one
    /// transaction. The hits keep `searchPaths`' order, limit and tie rule,
    /// and every hit has its summary — before housekeeping too.
    @Test("searchWithSummaries answers what searchPaths and versionSummaries answer apart, every hit summarized")
    func searchWithSummariesMatchesTwoReads() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let listing = [try snap("s1", t0), try snap("s2", t1)]
        try index.reconcile(listing: listing)
        let full: IndexContent = [
            "/a": true, "/b": true, "/c": true,
            "/a/report": false, "/b/report": false, "/c/report": false, "/a/report-2": false,
        ]
        var later = full
        later["/a/report"] = nil
        try index.runToDone(["s1": full, "s2": later])

        func expectAgrees(
            _ limit: Int, _ label: String, sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            let hits = try await index.searchPaths(matching: "report", limit: limit)
            let found = try await index.searchWithSummaries(matching: "report", limit: limit)
            let separate = try await index.versionSummaries(ofPaths: hits.map(\.path))
            #expect(found.hits == hits && found.hits.map(\.path) == hits.map(\.path), "\(label)", sourceLocation: sourceLocation)
            #expect(found.summaries == separate, "\(label)", sourceLocation: sourceLocation)
            #expect(Set(found.summaries.keys) == hits.map(\.path).pathKeys, "\(label): a hit without its summary",
                    sourceLocation: sourceLocation)
        }
        try await expectAgrees(10, "whole")
        try await expectAgrees(2, "cut at the limit")
        #expect(try await index.searchWithSummaries(matching: "report", limit: 2).hits.map(\.path) == ["/a/report", "/b/report"])
        #expect(try await index.searchWithSummaries(matching: "report", limit: 10).summaries["/a/report"]?.count == 1)
        let b = try await index.versions(ofPath: "/b/report")
        let newestB = try #require(b.first)
        #expect(b.count == 2)
        #expect(try await index.searchWithSummaries(matching: "report", limit: 10).summaries["/b/report"]
            == VersionSummary(count: 2, newest: newestB))

        // s1 leaves, no housekeeping: /a/report is held by no listed
        // snapshot, so it is neither a hit nor a summary.
        try index.reconcile(listing: [listing[1]])
        try await expectAgrees(2, "after a death")
        #expect(try await index.searchWithSummaries(matching: "report", limit: 10).hits.map(\.path)
            == ["/b/report", "/c/report", "/a/report-2"])
    }

    /// Find Files lists a hit under its summary's newest snapshot and
    /// restores it with the hit's kind; read together, the two describe that
    /// same snapshot — even when equal times make "newest" a tiebreak.
    @Test("searchWithSummaries' kind is the kind in its summary's newest snapshot, through a time tie")
    func searchWithSummariesKindMatchesNewest() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        try index.reconcile(listing: [try snap("b-first", t0)])
        try index.reconcile(listing: [try snap("b-first", t0), try snap("a-second", t0, tags: [planB])])
        try index.runToDone([
            "b-first": ["/data": true, "/data/k": false],
            "a-second": ["/data": true, "/data/k": true],
        ])
        let found = try await index.searchWithSummaries(matching: "k", limit: 10)
        let hit = try #require(found.hits.first { $0.path == "/data/k" })
        let summary = try #require(found.summaries["/data/k"])
        #expect(summary.newest.id == "a-second")
        #expect(summary.count == 2)
        let inNewest = try await index.contains(paths: ["/data/k"], inSnapshot: summary.newest.id)
        #expect(inNewest["/data/k"] == hit.isDirectory)
        #expect(hit.isDirectory)
    }

    /// The Restore pane asks for membership of every hit, up to the search's
    /// ceiling, and Find Files for every summary — far past one chunk.
    @Test("the searches' second question crosses the lookup chunk without losing hits")
    func searchesCrossChunkBoundary() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        try index.reconcile(listing: [try snap("s1", t0)])
        let all = (0 ..< SnapshotIndex.lookupChunk + 50).map { "/many/entry-\($0)" }
        try index.ingestWhole("s1", [IndexedEntry(path: "/many", isDirectory: true)] + all.map {
            IndexedEntry(path: $0, isDirectory: false)
        })
        let held = try await index.searchWithMembership(matching: "entry", limit: all.count + 10, inSnapshot: "s1")
        #expect(held.hits.map(\.path).pathKeys == all.pathKeys)
        #expect(Set(held.inSnapshot.keys) == all.pathKeys)
        #expect(held.inSnapshot.values.allSatisfy { $0 == false })
        let summarized = try await index.searchWithSummaries(matching: "entry", limit: all.count + 10)
        #expect(Set(summarized.summaries.keys) == all.pathKeys)
        #expect(summarized.summaries.values.allSatisfy { $0.count == 1 && $0.newest.id == "s1" })
    }

    // MARK: - Housekeeping

    @Test("housekeeping deletes the gap, bottom and top garbage and a snapshot-less chain, answers unchanged, idempotent")
    func housekeepingSemantics() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let a = try (1 ... 5).map { try snap("a\($0)", Int64($0) * t0) }
        let q = try snap("q1", t0, tags: [planB])
        _ = try index.reconcile(listing: a + [q])
        let base: IndexContent = ["/d": true, "/d/keep": false]
        var contents: [String: IndexContent] = [:]
        for s in a { contents[s.id] = base }
        contents["a1"]?["/d/bottom"] = false     // only in the oldest: a BOTTOM run
        contents["a3"]?["/d/gap"] = false        // only in the middle: a closed run in a gap
        contents["a4"]?["/d/top"] = false        // only below the newest: closed, above what survives
        contents["q1"] = ["/q": true, "/q/lonely": false]
        try index.runToDone(contents)
        #expect(try index.violations(afterHousekeeping: true).isEmpty)

        // a1, a3, a4, a5 and the whole of chain B leave.
        _ = try index.reconcile(listing: [a[1]])
        let paths = ["/d/keep", "/d/bottom", "/d/gap", "/d/top", "/q/lonely", "/d"]
        var before: [String: [String]] = [:]
        for path in paths { before[path] = try await index.versionIDs(path) }
        let garbage = try index.violations(afterHousekeeping: true)
        #expect(garbage.contains { $0.hasPrefix("(a)") }, "\(garbage)")
        #expect(garbage.contains { $0.hasPrefix("(b)") }, "\(garbage)")
        #expect(garbage.contains { $0.hasPrefix("(c)") }, "\(garbage)")

        try index.housekeeping()
        #expect(try index.violations(afterHousekeeping: true).isEmpty)
        for path in paths { #expect(try await index.versionIDs(path) == before[path], "\(path)") }
        #expect(before["/d/keep"] == ["a2"])
        #expect(try await index.searchPaths(matching: "lonely", limit: 10).isEmpty)

        try index.housekeeping()
        #expect(try index.violations(afterHousekeeping: true).isEmpty)
        #expect(try await index.isComplete())
    }

    @Test("a dead window end sends the next snapshot down the full route; exact, and its garbage is queued")
    func deadWindowEndTakesFull() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let s1 = try snap("s1", t0), s2 = try snap("s2", t1), s3 = try snap("s3", t2)
        let contents: [String: IndexContent] = [
            "s1": ["/d": true, "/d/a": false],
            "s2": ["/d": true, "/d/a": false, "/d/newt": false],
            "s3": ["/d": true, "/d/a": false, "/d/z": false],
        ]
        _ = try index.reconcile(listing: [s1, s2])
        try index.runToDone(contents)
        _ = try index.reconcile(listing: [s1])            // hi dies
        try index.housekeeping()
        _ = try index.reconcile(listing: [s1, s3])
        #expect(try index.nextStep() == .full(snapshotID: "s3"))
        try index.runToDone(contents)

        #expect(try await index.versionIDs("/d/a") == ["s3", "s1"])
        #expect(try await index.versionIDs("/d/z") == ["s3"])
        #expect(try await index.versionIDs("/d/newt").isEmpty)
        // Closing /d/newt at the dead hi left a run that claims nothing, and
        // the dead hi was queued so the next housekeeping finds it.
        let queued = try index.violations(afterHousekeeping: true)
        #expect(queued.contains { $0.hasPrefix("(a)") }, "\(queued)")
        #expect(queued.contains { $0.hasPrefix("(b)") }, "\(queued)")
        try index.housekeeping()
        #expect(try index.violations(afterHousekeeping: true).isEmpty)
    }

    @Test("the planner names the full reads that extend a window past a dead end, on either side, and only those")
    func plannerNamesDeadWindowEnds() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let s1 = try snap("s1", t0), s2 = try snap("s2", t1), s3 = try snap("s3", t2)
        let content: IndexContent = ["/d": true, "/d/a": false]
        try index.reconcile(listing: [s1, s2])
        // A chain's first build: there is no window to extend.
        #expect(try index.plannedStep() == PlannedStep(step: .full(snapshotID: "s2")))
        try index.ingestWhole("s2", IndexTestData.ls(content))
        // Below the window, its end alive: a delta, with no reason to give.
        #expect(try index.plannedStep() == PlannedStep(step: .delta(snapshotID: "s1", from: "s2")))
        try index.ingestWhole("s1", IndexTestData.ls(content))
        #expect(try index.plannedStep() == PlannedStep(step: .done))
        // hi dies and a backup follows: the forward full compare past a
        // dead end.
        try index.reconcile(listing: [s1])
        try index.housekeeping()
        try index.reconcile(listing: [s1, s3])
        #expect(try index.plannedStep() == PlannedStep(step: .full(snapshotID: "s3"), deadWindowEnd: true))
        #expect(try index.nextStep() == .full(snapshotID: "s3"))

        // lo dies with history still pending below it: the reverse full
        // compare past a dead end.
        let reverse = try IndexFixture()
        try reverse.index.reconcile(listing: [s1, s2, s3])
        #expect(try reverse.index.plannedStep() == PlannedStep(step: .full(snapshotID: "s3")))
        try reverse.index.ingestWhole("s3", IndexTestData.ls(content))
        #expect(try reverse.index.plannedStep() == PlannedStep(step: .delta(snapshotID: "s2", from: "s3")))
        try reverse.index.ingestDiff(snapshotID: "s2", from: "s3", added: [], removed: [])
        try reverse.index.reconcile(listing: [s1, s3])
        try reverse.index.housekeeping()
        #expect(try reverse.index.plannedStep() == PlannedStep(step: .full(snapshotID: "s1"), deadWindowEnd: true))
    }

    // MARK: - Deltas

    @Test("a delta closes the removed, opens the added, and a kind change spelled both ways splits the run")
    func applyDeltaSemantics() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        _ = try index.reconcile(listing: [try snap("s1", t0), try snap("s2", t1)])
        try index.ingestWhole("s1", IndexTestData.ls([
            "/data": true, "/data/kept.txt": false, "/data/modified.txt": false, "/data/gone.txt": false, "/data/x": false,
        ]))
        try index.ingestDiff(
            snapshotID: "s2", from: "s1",
            added: ["/data/new.txt", "/data/newdir/", "/data/x/"],
            removed: ["/data/gone.txt", "/data/x"]
        )

        #expect(try await index.versionIDs("/data/kept.txt") == ["s2", "s1"])
        #expect(try await index.versionIDs("/data/modified.txt") == ["s2", "s1"])
        #expect(try await index.versionIDs("/data/gone.txt") == ["s1"])
        #expect(try await index.versionIDs("/data/new.txt") == ["s2"])
        #expect(try await index.versionIDs("/data/newdir") == ["s2"])
        #expect(try await index.versionIDs("/data/x") == ["s2", "s1"])
        #expect(try await index.contains(paths: ["/data/x", "/data/gone.txt"], inSnapshot: "s1")
            == ["/data/x": false, "/data/gone.txt": false])
        #expect(try await index.contains(paths: ["/data/x", "/data/newdir", "/data/new.txt", "/data/gone.txt"], inSnapshot: "s2")
            == ["/data/x": true, "/data/newdir": true, "/data/new.txt": false])
        #expect(try await index.isComplete())
    }

    /// The store reads a diff path's kind bytewise; a Character test would
    /// read this directory as a file, its slash hidden inside the last
    /// cluster.
    @Test("a directory whose name ends in a Prepend character keeps its kind through a delta")
    func deltaKeepsPrependDirectoryKind() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        _ = try index.reconcile(listing: [try snap("s1", t0), try snap("s2", t1)])
        try index.ingestWhole("s1", IndexTestData.ls(["/data": true]))
        try index.ingestDiff(
            snapshotID: "s2", from: "s1",
            added: ["/data/new\u{0600}/", "/data/new\u{0600}/h.txt"], removed: []
        )
        #expect(try await index.contains(paths: ["/data/new\u{0600}", "/data/new\u{0600}/h.txt"], inSnapshot: "s2")
            == ["/data/new\u{0600}": true, "/data/new\u{0600}/h.txt": false])
        #expect(try await index.versionIDs("/data/new\u{0600}") == ["s2"])
    }

    @Test("a delta across a pending snapshot is notAdjacent; one from a base that is not the window end is wrongBase")
    func deltaRefusedAcrossGap() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let s1 = try snap("s1", t0), s2 = try snap("s2", t1), s3 = try snap("s3", t2), s4 = try snap("s4", t3)
        _ = try index.reconcile(listing: [s1, s2, s3])
        try index.ingestWhole("s1", IndexTestData.ls(["/data": true, "/data/a.txt": false]))

        // s2 is unread: a diff s1 -> s3 would assert every unchanged path in
        // it, which a deletion there would contradict.
        #expect(throws: IndexError.notAdjacent("s3")) {
            try index.ingestDiff(snapshotID: "s3", from: "s1", added: [], removed: [])
        }
        // Once s2 has left the listing its seq holds nothing, and the same
        // diff is the adjacent step.
        _ = try index.reconcile(listing: [s1, s3])
        try index.ingestDiff(snapshotID: "s3", from: "s1", added: [], removed: [])
        #expect(try await index.versionIDs("/data/a.txt") == ["s3", "s1"])

        _ = try index.reconcile(listing: [s1, s3, s4])
        #expect(throws: IndexError.wrongBase(snapshot: "s4", from: "s1")) {
            try index.ingestDiff(snapshotID: "s4", from: "s1", added: [], removed: [])
        }
    }

    // MARK: - Planner

    @Test("the planner builds each chain from its newest, then new backups, then history newest to oldest")
    func plannerOrder() throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let content: IndexContent = ["/data": true]
        let a = [try snap("a1", t0), try snap("a2", t1), try snap("a3", t2)]
        let b = try snap("b1", t1, tags: [planB])
        _ = try index.reconcile(listing: a + [b])
        let contents: [String: IndexContent] = ["a1": content, "a2": content, "a3": content, "a4": content, "b1": content]

        // Class 0, a chain's first read, before anything else; newest first.
        #expect(try index.nextStep() == .full(snapshotID: "a3"))
        try index.ingestWhole("a3", IndexTestData.ls(content))
        #expect(try index.nextStep() == .full(snapshotID: "b1"))
        try index.ingestWhole("b1", IndexTestData.ls(content))
        // Class 2, history, newest to oldest, from the window bottom.
        #expect(try index.nextStep() == .delta(snapshotID: "a2", from: "a3"))
        try index.ingestDiff(snapshotID: "a2", from: "a3", added: [], removed: [])
        // Class 1, a new backup, before the rest of the history.
        _ = try index.reconcile(listing: a + [b, try snap("a4", t3)])
        #expect(try index.nextStep() == .delta(snapshotID: "a4", from: "a3"))
        #expect(try index.runToDone(contents) == ["delta(a4<-a3)", "delta(a1<-a2)"])
        #expect(try index.nextStep() == .done)
    }

    @Test("a skipped candidate is passed over without letting the window jump it")
    func plannerSkipping() throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let content = IndexTestData.ls(["/data": true])
        _ = try index.reconcile(listing: [try snap("a1", t0), try snap("a2", t1)])
        try index.ingestWhole("a2", content)
        _ = try index.reconcile(listing: [try snap("a1", t0), try snap("a2", t1), try snap("a3", t2), try snap("a4", t3)])

        #expect(try index.nextStep() == .delta(snapshotID: "a3", from: "a2"))
        // a4 is not offered in a3's place: that would skip a3's seq.
        #expect(try index.nextStep(skipping: ["a3"]) == .delta(snapshotID: "a1", from: "a2"))
        #expect(try index.nextStep(skipping: ["a3", "a1"]) == .done)

        // A chain's first read falls back to its next-newest snapshot.
        let first = try IndexFixture()
        _ = try first.index.reconcile(listing: [try snap("b1", t0, tags: [planB]), try snap("b2", t1, tags: [planB])])
        #expect(try first.index.nextStep(skipping: ["b2"]) == .full(snapshotID: "b1"))
    }
}

/// The browse caches in the index — one directory's `restic ls` answer and
/// one `restic diff`, stored verbatim per immutable content key, file-backed.
/// `BrowseCacheTests` covers the coordinator's pass-through.
@Suite("snapshot index browse caches")
struct SnapshotIndexBrowseCacheTests {
    private func snapshot(_ id: String, _ micros: Int64) throws -> Snapshot {
        try IndexTestData.snapshot(id, micros: micros)
    }

    @Test("a captured listing round-trips with kind, size and mtime intact")
    func listingRoundTrip() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let mtime = Date(timeIntervalSince1970: 5_000)
        let captured: [CachedListingNode] = [
            IndexTestData.cachedNode("/src/notes.txt", size: 42, mtime: mtime),
            IndexTestData.cachedNode("/src/loop", kind: .symlink, size: nil),
            IndexTestData.cachedNode("/src/sub", kind: .dir, size: nil),
        ]
        try await index.recordListing(snapshotID: "s1", directory: "/src", nodes: captured)
        let read = try await index.listing(snapshotID: "s1", directory: "/src")
        #expect(read == captured)
        let restored = read?.map(\.snapshotNode) ?? []
        #expect(restored.first?.name == "notes.txt")
        #expect(restored.first?.mtime == mtime)
        #expect(restored.map(\.type) == [.file, .symlink, .dir])
    }

    @Test("an empty directory is a hit, not a miss, and the key is canonical")
    func emptyListingAndCanonicalKey() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        try await index.recordListing(snapshotID: "s1", directory: "/src/empty/", nodes: [])
        #expect(try await index.listing(snapshotID: "s1", directory: "/src/empty") == [])
        #expect(try await index.listing(snapshotID: "s1", directory: "/src/empty/") == [])
        try await index.recordListing(snapshotID: "s1", directory: "/", nodes: [IndexTestData.cachedNode("/bin")])
        #expect(try await index.listing(snapshotID: "s1", directory: "/")?.count == 1)
        #expect(try await index.listing(snapshotID: "s1", directory: "/src") == nil)
        #expect(try await index.listing(snapshotID: "other", directory: "/src/empty") == nil)
    }

    @Test("the directory key strips a slash that a Prepend character hides from Character tests")
    func prependDirectoryKey() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        try await index.recordListing(snapshotID: "s1", directory: "/src/new\u{0600}/", nodes: [IndexTestData.cachedNode("/src/new\u{0600}/h.txt")])
        #expect(try await index.listing(snapshotID: "s1", directory: "/src/new\u{0600}")?.count == 1)
        #expect(try await index.listing(snapshotID: "s1", directory: "/src/new\u{0600}/")?.count == 1)
    }

    @Test("a repeated capture never overwrites: the first verbatim answer stands")
    func firstCaptureWins() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        try await index.recordListing(snapshotID: "s1", directory: "/src", nodes: [IndexTestData.cachedNode("/src/a.txt")])
        try await index.recordListing(snapshotID: "s1", directory: "/src", nodes: [IndexTestData.cachedNode("/src/b.txt")])
        #expect(try await index.listing(snapshotID: "s1", directory: "/src") == [IndexTestData.cachedNode("/src/a.txt")])
    }

    @Test("a captured diff round-trips; unknown pairs miss")
    func diffRoundTrip() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let changes = [
            CachedDiffChange(ResticDiffChange(path: "/src/new.txt", modifier: "+")),
            CachedDiffChange(ResticDiffChange(path: "/src/gone.txt", modifier: "-")),
            CachedDiffChange(ResticDiffChange(path: "/src/moved/", modifier: "TU")),
        ]
        try await index.recordDiff(olderID: "s1", newerID: "s2", changes: changes)
        let read = try await index.diff(olderID: "s1", newerID: "s2")
        #expect(read?.map(\.resticDiffChange) == changes.map(\.resticDiffChange))
        #expect(read?.last?.resticDiffChange.category == .modified)
        #expect(try await index.diff(olderID: "s2", newerID: "s1") == nil)
        #expect(try await index.diff(olderID: "s1", newerID: "s3") == nil)
    }

    @Test("a snapshot's death sweeps its listings, its file nodes and every diff that names it")
    func deathSweepsCacheRows() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        _ = try index.reconcile(listing: [try snapshot("s1", 1_000_000), try snapshot("s2", 2_000_000)])
        try await index.recordListing(snapshotID: "s1", directory: "/src", nodes: [IndexTestData.cachedNode("/src/a.txt")])
        try await index.recordListing(snapshotID: "s2", directory: "/src", nodes: [IndexTestData.cachedNode("/src/b.txt")])
        try await index.recordDiff(olderID: "s1", newerID: "s2", changes: [])
        let file = IndexTestData.cachedNode("/src/a.txt")
        try await index.recordFileNodes(["/src/a.txt": ["s1": file, "s2": file]])

        try index.reconcile(listing: [try snapshot("s2", 2_000_000)])
        #expect(try index.snapStates()["s1"] == nil)
        #expect(try await index.listing(snapshotID: "s1", directory: "/src") == nil)
        #expect(try await index.diff(olderID: "s1", newerID: "s2") == nil)
        #expect(try await index.listing(snapshotID: "s2", directory: "/src") != nil)
        #expect(try await index.fileNodes(path: "/src/a.txt", snapshotIDs: ["s1", "s2"]) == ["s2": file])

        // The return starts from an empty cache: the rows were reclaimed.
        try index.reconcile(listing: [try snapshot("s1", 1_000_000), try snapshot("s2", 2_000_000)])
        #expect(try index.snapStates()["s1"] == SnapshotIndex.State.pending)
        #expect(try await index.listing(snapshotID: "s1", directory: "/src") == nil)
        #expect(try await index.fileNodes(path: "/src/a.txt", snapshotIDs: ["s1"]).isEmpty)
    }

    @Test("cache rows naming an ID the index never listed are swept too")
    func unknownIDSweep() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        _ = try index.reconcile(listing: [try snapshot("s2", 2_000_000)])
        try await index.recordListing(snapshotID: "s2", directory: "/src", nodes: [IndexTestData.cachedNode("/src/b.txt")])
        try await index.recordListing(snapshotID: "ghost", directory: "/src", nodes: [IndexTestData.cachedNode("/src/a.txt")])
        try await index.recordDiff(olderID: "ghost", newerID: "s2", changes: [])
        try await index.recordFileNodes(["/src/a.txt": ["ghost": IndexTestData.cachedNode("/src/a.txt")]])

        _ = try index.reconcile(listing: [try snapshot("s2", 2_000_000)])
        #expect(try await index.listing(snapshotID: "ghost", directory: "/src") == nil)
        #expect(try await index.diff(olderID: "ghost", newerID: "s2") == nil)
        #expect(try await index.listing(snapshotID: "s2", directory: "/src") != nil)
        #expect(try await index.fileNodes(path: "/src/a.txt", snapshotIDs: ["ghost"]).isEmpty)
    }

    @Test("a file's node round-trips per snapshot and exact path; the first capture stands")
    func fileNodeRoundTrip() async throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        let mtime = Date(timeIntervalSince1970: 5_000)
        let older = IndexTestData.cachedNode("/src/notes.txt", size: 42, mtime: mtime)
        let newer = IndexTestData.cachedNode("/src/notes.txt", size: 50, mtime: mtime.addingTimeInterval(60))
        try await index.recordFileNodes(["/src/notes.txt": ["s1": older, "s2": newer]])

        let read = try await index.fileNodes(path: "/src/notes.txt", snapshotIDs: ["s2", "s1", "s3"])
        // A snapshot with no capture is absent, not an error.
        #expect(read == ["s1": older, "s2": newer])
        #expect(read["s1"]?.snapshotNode.mtime == mtime)
        #expect(read["s1"]?.snapshotNode.size == 42)
        // Paths are exact, by bytes: another case or a trailing slash misses.
        #expect(try await index.fileNodes(path: "/src/Notes.txt", snapshotIDs: ["s1"]).isEmpty)
        #expect(try await index.fileNodes(path: "/src/notes.txt/", snapshotIDs: ["s1"]).isEmpty)

        try await index.recordFileNodes(["/src/notes.txt": ["s1": newer]])
        #expect(try await index.fileNodes(path: "/src/notes.txt", snapshotIDs: ["s1"]) == ["s1": older])
    }

    @Test("a store that has its caches opens while another connection holds its writer")
    func openWhileAnotherWriterHoldsTheLock() async throws {
        let fixture = try IndexFixture()
        _ = try fixture.index.reconcile(listing: [try snapshot("s1", 1_000_000)])
        // Another app instance on this configuration folder, mid-write: a
        // store that cannot open is deleted and rebuilt by its coordinator.
        var holding = Configuration()
        holding.allowsUnsafeTransactions = true
        let other = try DatabaseQueue(path: fixture.path, configuration: holding)
        try await other.writeWithoutTransaction { try $0.execute(sql: "BEGIN IMMEDIATE") }
        defer { try? other.inDatabase { try $0.execute(sql: "ROLLBACK") } }

        try fixture.reopen()
        #expect(try fixture.index.snapStates()["s1"] != nil)
    }

    @Test("a store from before the file-node cache gains it at its next open and keeps what it held")
    func fileNodeCacheAddedToAnOlderStore() async throws {
        let fixture = try IndexFixture()
        _ = try fixture.index.reconcile(listing: [try snapshot("s1", 1_000_000)])
        try await fixture.index.recordListing(snapshotID: "s1", directory: "/src", nodes: [IndexTestData.cachedNode("/src/a.txt")])
        try fixture.index.close()
        // What a schema-3 file written before the table existed looks like.
        let queue = try DatabaseQueue(path: fixture.path)
        try await queue.write { try $0.execute(sql: "DROP TABLE file_node") }
        try queue.close()

        try fixture.reopen()
        // Opened, not rebuilt: the listing and the snapshot are still there.
        #expect(try fixture.index.snapStates()["s1"] != nil)
        #expect(try await fixture.index.listing(snapshotID: "s1", directory: "/src") != nil)
        let file = IndexTestData.cachedNode("/src/a.txt")
        try await fixture.index.recordFileNodes(["/src/a.txt": ["s1": file]])
        #expect(try await fixture.index.fileNodes(path: "/src/a.txt", snapshotIDs: ["s1"]) == ["s1": file])
    }
}
