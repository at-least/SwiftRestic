import Foundation
import GRDB
import Testing

/// Backfill against the real restic binary: reconcile a listing of real
/// snapshots, read them through `restic ls` and `restic diff` into the
/// index, and check the answers against what restic itself lists. Skipped
/// when restic is not installed, like the other integration suites.
@Suite("index backfill", .serialized, .enabled(if: ResticAvailability.isInstalled))
struct IndexBackfillTests {
    private static let password = "integration-test-password"

    /// A local repository with one plan backing up `source`, in a fresh
    /// temporary folder that `remove()` deletes.
    private struct Scene {
        let root: URL
        let source: URL
        let repository: Repository
        let plan: BackupPlan
        let context: RepositoryContext
        let service: ResticService

        func backup() async throws -> String {
            let outcome = try await service.backup(context, plan: plan)
            #expect(outcome.exitCode == 0)
            return try #require(outcome.summary?.snapshotID)
        }

        func write(_ text: String, _ relative: String) throws {
            try text.write(to: source.appendingPathComponent(relative), atomically: true, encoding: .utf8)
        }

        func path(_ relative: String) -> String {
            source.appendingPathComponent(relative).path
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeScene(_ label: String) async throws -> Scene {
        let binary = try ResticBinary.locate(userOverride: nil)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        var repository = Repository()
        repository.name = label
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        var plan = BackupPlan()
        plan.name = "\(label) plan"
        plan.repositoryID = repository.id
        plan.sources = [source.path]

        let context = RepositoryContext(repository: repository, password: Self.password)
        let service = ResticService(runner: ResticRunner(), binary: binary.url)
        _ = try await service.initializeRepository(context)
        return Scene(root: root, source: source, repository: repository, plan: plan, context: context, service: service)
    }

    /// One snapshot's every node straight from `restic ls`: path → isDirectory.
    /// The truth the index answers are checked against — nothing of the index
    /// is involved in building it.
    private func lsContent(_ scene: Scene, _ snapshotID: String) async throws -> [String: Bool] {
        let collector = NodeCollector()
        try await scene.service.walkSnapshot(scene.context, snapshotID: snapshotID) { node in
            collector.append(node)
        }
        return collector.content
    }

    /// The two searches the app runs, each answering its second question in
    /// the same read — Find Files' hit with its summary (count and newest),
    /// the Restore pane's membership with the kind in each snapshot — over
    /// every path either snapshot holds, against `restic ls` itself; plus
    /// the path-keyed oracles the tests hold them to: `versions` across every
    /// chain (newest first), `contains` with the kind in each snapshot, and
    /// search's kind. The app's per-chain `versions` read is checked where
    /// a plan's chain is (`versions(ofPath:inChain:)`, further down).
    private func expectAnswersMatch(
        _ coordinator: IndexCoordinator,
        _ repositoryID: UUID,
        newest: (id: String, content: [String: Bool]),
        older: (id: String, content: [String: Bool]),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let paths = Set(newest.content.keys).union(older.content.keys).sorted()
        #expect(try await coordinator.isComplete(repositoryID: repositoryID), sourceLocation: sourceLocation)
        for path in paths {
            let expected = [newest, older].filter { $0.content[path] != nil }.map(\.id)
            let versions = try await coordinator.versions(ofPath: path, repositoryID: repositoryID).map(\.id)
            #expect(versions == expected, "versions of \(path)", sourceLocation: sourceLocation)

            let kind = newest.content[path] ?? older.content[path]
            let hits = try await coordinator.searchPaths(
                matching: ResticPath.basename(of: path), repositoryID: repositoryID, limit: 200
            )
            let hit = hits.first(where: { $0.path == path })
            #expect(hit?.isDirectory == kind, "search kind of \(path)", sourceLocation: sourceLocation)

            // Find Files' read: the same hit, with its summary beside it.
            let summarized = try await coordinator.searchWithSummaries(
                matching: ResticPath.basename(of: path), repositoryID: repositoryID, limit: 200
            )
            let summary = summarized.summaries[PathKey(path)]
            #expect(summarized.hits.first(where: { $0.path == path })?.isDirectory == kind,
                    "summarized search kind of \(path)", sourceLocation: sourceLocation)
            #expect(summary?.count == expected.count && summary?.newest.id == expected.first,
                    "summary of \(path)", sourceLocation: sourceLocation)
        }
        for snapshot in [newest, older] {
            let held = try await coordinator.contains(paths: paths, inSnapshot: snapshot.id, repositoryID: repositoryID)
            #expect(held == snapshot.content.byPathKey, "contains in \(snapshot.id)", sourceLocation: sourceLocation)
            // The Restore pane's read: each path's kind in this snapshot,
            // from its own search.
            for path in paths {
                let found = try await coordinator.searchWithMembership(
                    matching: ResticPath.basename(of: path), inSnapshot: snapshot.id,
                    repositoryID: repositoryID, limit: 200
                )
                #expect(found.inSnapshot[PathKey(path)] == snapshot.content[path],
                        "membership of \(path) in \(snapshot.id)", sourceLocation: sourceLocation)
            }
        }
        let violations = try await coordinator.read(repositoryID) { try $0.invariantViolations() }
        #expect(violations.isEmpty, sourceLocation: sourceLocation)
    }

    @Test("backfill reads the newest snapshot in full and builds the older from a diff; a second pass reads nothing")
    func backfillMergesRuns() async throws {
        let scene = try await makeScene("SwiftResticIndexTests")
        defer { scene.remove() }
        try scene.write("v1", "changed.txt")
        try scene.write("stable", "stable.txt")
        let firstID = try await scene.backup()
        try scene.write("v2", "changed.txt")
        let secondID = try await scene.backup()
        let listing = try await scene.service.snapshots(scene.context)
        #expect(listing.count == 2)

        let coordinator = IndexCoordinator(directory: scene.root.appendingPathComponent("config"))
        let repositoryID = scene.repository.id
        await coordinator.reconcile(repositoryID: repositoryID, snapshots: listing, generation: 1)
        await coordinator.runBackfill(repositoryID: repositoryID, service: scene.service, context: scene.context)

        // The chain's first build is its newest snapshot, read in full; the
        // older one is a reverse delta below it — one `ls` in all.
        let report = await coordinator.lastBackfillReport(repositoryID: repositoryID)
        #expect(report?.fulls == 1)
        #expect(report?.deltas == 1)
        #expect(try await coordinator.isComplete(repositoryID: repositoryID))

        // A content change leaves the path in place: both files exist in
        // both snapshots, newest first.
        let changed = scene.path("changed.txt")
        let stable = scene.path("stable.txt")
        let changedVersions = try await coordinator.versions(ofPath: changed, repositoryID: repositoryID)
        #expect(changedVersions.map(\.id) == [secondID, firstID])
        #expect(try await coordinator.versions(ofPath: stable, repositoryID: repositoryID).map(\.id) == [secondID, firstID])
        #expect(try await coordinator.versions(
            ofPath: stable, inChain: ResticService.planTag(scene.plan.id), repositoryID: repositoryID
        ).map(\.id) == [secondID, firstID])
        #expect(try await coordinator.versions(ofPath: stable, inChain: "swiftrestic-plan-other", repositoryID: repositoryID).isEmpty)

        // The summaries agree with the single path, and leave a
        // never-indexed path absent.
        let asked = [changed, stable, "/data/never.indexed"]
        let summaries = try await coordinator.versionSummaries(ofPaths: asked, repositoryID: repositoryID)
        let newestChanged = try #require(changedVersions.first)
        #expect(summaries[PathKey(changed)] == VersionSummary(count: 2, newest: newestChanged))
        #expect(summaries[PathKey(stable)]?.count == 2)
        #expect(summaries["/data/never.indexed"] == nil)

        // A second pass over the same snapshots reads nothing: reconcile is
        // idempotent and both are indexed. A newer generation, as a second
        // refresh would carry — the same number would be dropped unread.
        await coordinator.reconcile(repositoryID: repositoryID, snapshots: listing, generation: 2)
        await coordinator.runBackfill(repositoryID: repositoryID, service: scene.service, context: scene.context)
        #expect(await coordinator.lastBackfillReport(repositoryID: repositoryID) == BackfillReport())
        #expect(try await coordinator.versions(ofPath: stable, repositoryID: repositoryID).count == 2)
        let violations = try await coordinator.read(repositoryID) { try $0.invariantViolations() }
        #expect(violations.isEmpty)
    }

    @Test("diff-built indexes, forward and reverse, answer exactly what restic ls lists")
    func diffApplyEqualsFullLoad() async throws {
        let scene = try await makeScene("SwiftResticDiffEq")
        defer { scene.remove() }
        try FileManager.default.createDirectory(at: scene.source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try scene.write("one", "keep.txt")
        try scene.write("doomed", "removed.txt")
        try scene.write("v1", "edited.txt")
        try scene.write("deep", "sub/deep.txt")
        let oldID = try await scene.backup()
        // Every category the diff knows: content edit, deletion, addition —
        // of a file and of a directory with a child — plus an unchanged
        // file and an untouched directory.
        try scene.write("v2", "edited.txt")
        try FileManager.default.removeItem(at: scene.source.appendingPathComponent("removed.txt"))
        try scene.write("fresh", "added.txt")
        try FileManager.default.createDirectory(at: scene.source.appendingPathComponent("fresh"), withIntermediateDirectories: true)
        try scene.write("inner", "fresh/inner.txt")
        let newID = try await scene.backup()

        let listing = try await scene.service.snapshots(scene.context)
        #expect(listing.count == 2)
        let newest = (id: newID, content: try await lsContent(scene, newID))
        let older = (id: oldID, content: try await lsContent(scene, oldID))
        let repositoryID = scene.repository.id

        // Reverse: both listed at once — the newest read in full, the older
        // built from a diff below it, the history route.
        let reverse = IndexCoordinator(directory: scene.root.appendingPathComponent("reverse"))
        await reverse.reconcile(repositoryID: repositoryID, snapshots: listing, generation: 1)
        await reverse.runBackfill(repositoryID: repositoryID, service: scene.service, context: scene.context)
        let reverseReport = await reverse.lastBackfillReport(repositoryID: repositoryID)
        #expect(reverseReport?.fulls == 1)
        #expect(reverseReport?.deltas == 1)
        try await expectAnswersMatch(reverse, repositoryID, newest: newest, older: older)

        // Forward: the older alone first, then the newer from a diff above
        // it — the route a live backup rides once history is indexed.
        let forward = IndexCoordinator(directory: scene.root.appendingPathComponent("forward"))
        await forward.reconcile(repositoryID: repositoryID, snapshots: listing.filter { $0.id == oldID }, generation: 1)
        await forward.runBackfill(repositoryID: repositoryID, service: scene.service, context: scene.context)
        await forward.reconcile(repositoryID: repositoryID, snapshots: listing, generation: 2)
        await forward.runBackfill(repositoryID: repositoryID, service: scene.service, context: scene.context)
        let forwardReport = await forward.lastBackfillReport(repositoryID: repositoryID)
        #expect(forwardReport?.fulls == 0)
        #expect(forwardReport?.deltas == 1)
        try await expectAnswersMatch(forward, repositoryID, newest: newest, older: older)
    }

    @Test("N5: a kind change is a T line — the delta is abandoned for the full route, and the answers match restic ls")
    func typeChangeTakesFullRoute() async throws {
        let scene = try await makeScene("SwiftResticTypeChange")
        defer { scene.remove() }
        let fileManager = FileManager.default
        try scene.write("a", "x")
        try fileManager.createDirectory(at: scene.source.appendingPathComponent("d"), withIntermediateDirectories: true)
        try scene.write("inner", "d/inner")
        try fileManager.createSymbolicLink(atPath: scene.path("link"), withDestinationPath: "x")
        let firstID = try await scene.backup()
        // x: file → directory with a child; d: directory → file; link:
        // symlink → file. restic 0.19.1 writes one `T` line for each and
        // omits both subtrees — a diff that says nothing about x/g.
        try fileManager.removeItem(atPath: scene.path("x"))
        try fileManager.createDirectory(at: scene.source.appendingPathComponent("x"), withIntermediateDirectories: true)
        try scene.write("g", "x/g")
        try fileManager.removeItem(atPath: scene.path("d"))
        try scene.write("now a file", "d")
        try fileManager.removeItem(atPath: scene.path("link"))
        try scene.write("now a file too", "link")
        let secondID = try await scene.backup()

        // The collector refuses exactly that diff.
        let collector = DeltaCollector()
        try await scene.service.walkDiff(scene.context, olderID: firstID, newerID: secondID) { change in
            collector.consume(change)
        }
        let refusal = #expect(throws: IncompleteStream.self) { try collector.delta() }
        if case .typeChange = refusal {} else {
            Issue.record("expected a typeChange refusal, got \(String(describing: refusal))")
        }

        let listing = try await scene.service.snapshots(scene.context)
        let repositoryID = scene.repository.id
        let coordinator = IndexCoordinator(directory: scene.root.appendingPathComponent("config"))
        await coordinator.reconcile(repositoryID: repositoryID, snapshots: listing.filter { $0.id == firstID }, generation: 1)
        await coordinator.runBackfill(repositoryID: repositoryID, service: scene.service, context: scene.context)
        await coordinator.reconcile(repositoryID: repositoryID, snapshots: listing, generation: 2)
        await coordinator.runBackfill(repositoryID: repositoryID, service: scene.service, context: scene.context)

        // The forward delta was tried, abandoned on the `T`, and the full
        // route built the snapshot instead.
        let report = await coordinator.lastBackfillReport(repositoryID: repositoryID)
        #expect(report?.typeChange == 1)
        #expect(report?.deltas == 0)
        #expect(report?.fulls == 1)
        #expect(report?.deadWindowEnd == 0)

        let newest = (id: secondID, content: try await lsContent(scene, secondID))
        let older = (id: firstID, content: try await lsContent(scene, firstID))
        try await expectAnswersMatch(coordinator, repositoryID, newest: newest, older: older)
        let kinds = [scene.path("x"), scene.path("x/g"), scene.path("d"), scene.path("d/inner"), scene.path("link")]
        #expect(try await coordinator.contains(paths: kinds, inSnapshot: secondID, repositoryID: repositoryID) == [
            scene.path("x"): true, scene.path("x/g"): false, scene.path("d"): false, scene.path("link"): false,
        ].byPathKey)
        #expect(try await coordinator.contains(paths: kinds, inSnapshot: firstID, repositoryID: repositoryID) == [
            scene.path("x"): false, scene.path("d"): true, scene.path("d/inner"): false, scene.path("link"): false,
        ].byPathKey)
    }

    @Test("backfill throughput: ten thousand files walk and store in bounded time")
    func backfillThroughput() async throws {
        let scene = try await makeScene("SwiftResticThroughput")
        defer { scene.remove() }
        // Fifty folders of two hundred small files each — enough rows for the
        // store side to dominate the decode side, small enough that CI stays
        // quick. The assertion is the generous bound; the printed rate is the
        // evidence the million-file projection rests on.
        for folder in 0..<50 {
            let directory = scene.source.appendingPathComponent("folder\(folder)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in 0..<200 {
                try "payload \(folder)-\(file)".write(
                    to: directory.appendingPathComponent("file-\(folder)-\(file).txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
        _ = try await scene.backup()
        let listing = try await scene.service.snapshots(scene.context)
        #expect(listing.count == 1)

        let coordinator = IndexCoordinator(directory: scene.root.appendingPathComponent("config"))
        let repositoryID = scene.repository.id
        await coordinator.reconcile(repositoryID: repositoryID, snapshots: listing, generation: 1)
        let start = Date()
        await coordinator.runBackfill(repositoryID: repositoryID, service: scene.service, context: scene.context)
        let elapsed = Date().timeIntervalSince(start)

        #expect(try await coordinator.isComplete(repositoryID: repositoryID))
        #expect(await coordinator.lastBackfillReport(repositoryID: repositoryID)?.fulls == 1)
        let probedPath = scene.path("folder3/file-3-77.txt")
        #expect(try await coordinator.versions(ofPath: probedPath, repositoryID: repositoryID).count == 1)

        print("backfill throughput: 10_001 paths in \(String(format: "%.2f", elapsed))s (\(String(format: "%.0f", Double(10_001) / max(elapsed, 0.001))) paths/s)")
        #expect(elapsed < 120, "backfill of 10k paths took \(elapsed)s — the seconds-scale claim is broken")
    }

    @Test("a deleted repository's index file goes with it")
    func dropRemovesTheFile() async throws {
        let scene = try CoordinatorScene("SwiftResticIndexDrop")
        defer { scene.remove() }

        let repositoryID = scene.repositoryID
        let coordinator = scene.coordinator
        let file = coordinator.fileURL(for: repositoryID)
        await coordinator.reconcile(repositoryID: repositoryID, snapshots: [], generation: 1)
        #expect(FileManager.default.fileExists(atPath: file.path))

        await coordinator.dropRepository(repositoryID: repositoryID)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // A refresh that was in flight when the removal happened still
        // carries its reconcile into the coordinator afterwards. The store
        // must refuse to recreate the file for a repository that is gone,
        // or an orphan would live on disk forever after.
        await coordinator.reconcile(repositoryID: repositoryID, snapshots: [], generation: 2)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a reset repository reconciles again — only removal is tombstoned")
    func resetAllowsReconcile() async throws {
        let scene = try CoordinatorScene("SwiftResticIndexReset")
        defer { scene.remove() }

        let repositoryID = scene.repositoryID
        let coordinator = scene.coordinator
        let file = coordinator.fileURL(for: repositoryID)
        await coordinator.reconcile(repositoryID: repositoryID, snapshots: [], generation: 1)

        // The rebuild hatch throws the index away without tombstoning: the
        // repository still exists, so the reconcile that follows must land
        // and recreate the store. Under the SAME generation: a rebuild
        // re-sends the listing the model holds, under the number the old
        // store already took. The fresh store has taken none, so it lands.
        await coordinator.resetRepository(repositoryID: repositoryID)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        await coordinator.reconcile(repositoryID: repositoryID, snapshots: [], generation: 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}

/// A lock-guarded flag for the concurrency tests: set on one side, polled on
/// the other.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// A lock-guarded counter, for generation numbers handed out from a hook.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(start: UInt64) {
        value = start - 1
    }

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Polls `condition` every 5 ms for up to `seconds`; true once it held. Runs
/// on the caller's actor, so a main-actor test may read main-actor state.
func eventually(
    within seconds: Double,
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

extension IndexCoordinator {
    /// The indexed snapshots holding one path across every chain, newest
    /// first: the store's oracle read, through the coordinator's lease.
    /// Test-only — the app always asks within a plan's chain
    /// (`versions(ofPath:inChain:repositoryID:)`).
    nonisolated func versions(ofPath path: String, repositoryID: UUID) async throws -> [IndexVersion] {
        try await read(repositoryID) { try await $0.versions(ofPath: path) }
    }

    /// Per path: how many indexed snapshots hold it, and the newest — the
    /// store's path-keyed oracle, through the coordinator's lease.
    /// Test-only — Find Files reads each hit's summary inside its search
    /// (`searchWithSummaries(matching:repositoryID:limit:)`).
    nonisolated func versionSummaries(ofPaths paths: [String], repositoryID: UUID) async throws -> [PathKey: VersionSummary] {
        try await read(repositoryID) { try await $0.versionSummaries(ofPaths: paths) }
    }

    /// Which of `paths` one snapshot holds, each with its kind there — the
    /// store's path-keyed oracle, through the coordinator's lease.
    /// Test-only — the Restore pane reads the open backup's membership
    /// inside its search (`searchWithMembership(matching:inSnapshot:repositoryID:limit:)`).
    nonisolated func contains(paths: [String], inSnapshot snapshotID: String, repositoryID: UUID) async throws -> [PathKey: Bool] {
        try await read(repositoryID) { try await $0.contains(paths: paths, inSnapshot: snapshotID) }
    }

    /// Basename search across every indexed path, the hits alone.
    /// Test-only — both searches the app runs answer their second question
    /// in the same read (`searchWithMembership`, `searchWithSummaries`).
    nonisolated func searchPaths(matching query: String, repositoryID: UUID, limit: Int) async throws -> [SearchHit] {
        try await read(repositoryID) { try await $0.searchPaths(matching: query, limit: limit) }
    }
}

/// The coordinator's tombstone contract, without restic: once a repository
/// is dropped, its index answers by throwing — a search reading through the
/// coordinator must surface that, never read it as "no versions".
@Suite("index coordinator tombstones")
struct IndexCoordinatorTombstoneTests {
    @Test("versions for a dropped repository throw repositoryRemoved")
    func droppedRepositoryThrows() async throws {
        let scene = try CoordinatorScene("SwiftResticTombstone")
        defer { scene.remove() }
        let coordinator = scene.coordinator
        let repositoryID = scene.repositoryID
        await scene.reconcile([], 1)

        await coordinator.dropRepository(repositoryID: repositoryID)
        // The path-keyed reads the tests hold the searches to: the
        // summaries, and the membership in one backup.
        do {
            _ = try await coordinator.versionSummaries(ofPaths: ["/data/a"], repositoryID: repositoryID)
            Issue.record("expected repositoryRemoved, got a result")
        } catch IndexError.repositoryRemoved {
            // The answer a search must surface, never read as "no versions".
        }
        do {
            _ = try await coordinator.contains(paths: ["/data/a"], inSnapshot: "s1", repositoryID: repositoryID)
            Issue.record("expected repositoryRemoved, got a result")
        } catch IndexError.repositoryRemoved {}
        // The two searches the app runs, each reading that answer inside the
        // search: Find Files' with its summaries, and the Restore pane's
        // with the open backup's membership.
        do {
            _ = try await coordinator.searchWithSummaries(matching: "a", repositoryID: repositoryID, limit: 10)
            Issue.record("expected repositoryRemoved, got a result")
        } catch IndexError.repositoryRemoved {}
        do {
            _ = try await coordinator.searchWithMembership(
                matching: "a", inSnapshot: "s1", repositoryID: repositoryID, limit: 10
            )
            Issue.record("expected repositoryRemoved, got a result")
        } catch IndexError.repositoryRemoved {}
        // The caches read a removed repository as a miss, and recreate nothing.
        #expect(await coordinator.cachedListing(snapshotID: "s1", directory: "/", repositoryID: repositoryID) == nil)
        #expect(!FileManager.default.fileExists(atPath: coordinator.fileURL(for: repositoryID).path))
    }

    @Test("N10: a file with another schema is deleted and rebuilt on open: empty, not complete until a listing lands, and it indexes again")
    func schemaMismatchRebuilds() async throws {
        let scene = try CoordinatorScene("SwiftResticSchemaMismatch")
        defer { scene.remove() }
        let file = scene.coordinator.fileURL(for: scene.repositoryID)
        try FileManager.default.createDirectory(at: scene.coordinator.indexDirectory, withIntermediateDirectories: true)
        // A populated file of this schema, then stamped as another.
        let seeded = try SnapshotIndex(path: file.path)
        _ = try seeded.reconcile(listing: [try CoordinatorScene.snapshot("s1", 1)])
        try seeded.ingestWhole("s1", IndexTestData.ls(CoordinatorScene.content("s1")))
        try seeded.close()
        let stamp = try DatabaseQueue(path: file.path)
        try await stamp.write { try $0.execute(sql: "PRAGMA user_version = 99") }
        try stamp.close()

        #expect(try await !scene.coordinator.isComplete(repositoryID: scene.repositoryID))
        #expect(try await scene.versions("/data/s1.txt").isEmpty)

        let client = MockResticClient().onListings(["s1": CoordinatorScene.content("s1")])
        await scene.reconcile([try CoordinatorScene.snapshot("s1", 1)], 1)
        await scene.backfill(client)
        #expect(try await scene.versions("/data/s1.txt") == ["s1"])
        #expect(try await scene.coordinator.isComplete(repositoryID: scene.repositoryID))
        #expect(try await scene.violations.isEmpty)
    }
}

/// The listing-generation guard, through the coordinator, without restic.
/// Two refreshes of one repository hand their listings to the index through
/// separate unstructured hops, so an older listing can land after a newer
/// one; applied, it would record as dead every snapshot the newer listing
/// brought in. The model numbers each listing before it is read, and the
/// store drops, under its writer, any listing not newer than the last it
/// took.
@Suite("index coordinator listing generations")
struct IndexCoordinatorGenerationTests {
    @Test("N6: a listing older than the last one applied is dropped, and a newer one still lands")
    func staleListingDropped() async throws {
        let scene = try CoordinatorScene("SwiftResticGenerations")
        defer { scene.remove() }
        let path = "/data/common.txt"
        let older = try CoordinatorScene.snapshot("older", 1_000)
        let newer = try CoordinatorScene.snapshot("newer", 2_000)
        let client = MockResticClient().onListings([
            "older": CoordinatorScene.content("older"), "newer": CoordinatorScene.content("newer"),
        ])
        await scene.reconcile([older, newer], 5)
        await scene.backfill(client)
        #expect(try await scene.versions(path) == ["newer", "older"])
        #expect(try await scene.coordinator.isComplete(repositoryID: scene.repositoryID))

        // Read before the listing above, landing after it: it predates the
        // newer snapshot. Dropped, so the newer snapshot stays listed and
        // indexed, and the index stays complete.
        await scene.reconcile([older], 4)
        #expect(try await scene.versions(path) == ["newer", "older"])
        #expect(try await scene.coordinator.isComplete(repositoryID: scene.repositoryID))

        // The same number again is not newer either.
        await scene.reconcile([older], 5)
        #expect(try await scene.versions(path) == ["newer", "older"])

        // A genuinely newer listing that omits it is the truth: it lands.
        await scene.reconcile([older], 6)
        #expect(try await scene.versions(path) == ["older"])
    }

    /// The model hands out one counter's numbers to every repository, so a
    /// repository's listing can carry a lower number than one another
    /// repository's index already took. Numbers compare within one
    /// repository only.
    @Test("a listing numbered below another repository's last applied listing still lands, and each repository keeps its own order")
    func generationsCompareWithinOneRepository() async throws {
        let scene = try CoordinatorScene("SwiftResticGenerationsPerRepository")
        defer { scene.remove() }
        let other = UUID()
        await scene.coordinator.reconcile(repositoryID: other, snapshots: [], generation: 7)
        #expect(try await scene.coordinator.isComplete(repositoryID: other))

        // Lower than 7, and this repository's first: it lands. A file no
        // listing has reached is not complete, so dropping it would show.
        await scene.reconcile([], 3)
        #expect(try await scene.coordinator.isComplete(repositoryID: scene.repositoryID))

        // The other repository still orders its own listings: an older
        // number of its own is dropped, so the snapshot it names never
        // becomes pending.
        await scene.coordinator.reconcile(repositoryID: other, snapshots: [try CoordinatorScene.snapshot("late", 1)], generation: 5)
        #expect(try await scene.coordinator.isComplete(repositoryID: other))
    }

    @Test("N6 with no queue: reconciles in flight at once leave the newest listing, whatever order they reach the writer in")
    func concurrentListingsLeaveTheNewest() async throws {
        let scene = try CoordinatorScene("SwiftResticGenerationsConcurrent")
        defer { scene.remove() }
        var generation: UInt64 = 0
        for round in 0 ..< 20 {
            // Listing k holds one snapshot more than listing k - 1, so each
            // number names a different set, and the newest names them all.
            let listings = try (0 ..< 6).map { k in
                try (0 ... k).map { try CoordinatorScene.snapshot("r\(round)-s\($0)", Int64($0 + 1)) }
            }
            let base = generation
            await withTaskGroup(of: Void.self) { group in
                for k in listings.indices.shuffled() {
                    group.addTask { await scene.reconcile(listings[k], base + UInt64(k) + 1) }
                }
            }
            generation = base + UInt64(listings.count)
            // An older listing applied last would have dropped the newer
            // snapshots it never saw.
            let listed = try await scene.coordinator.read(scene.repositoryID) { try $0.snapStates() }
            #expect(Set(listed.keys) == Set(listings[5].map(\.id)), "round \(round)")
        }
    }
}

/// The launch sweep of orphaned index files, without restic: which files it
/// deletes, and — the half that matters more — which it must never touch.
@Suite("index orphan sweep")
struct IndexOrphanSweepTests {
    @Test("only unconfigured UUID-named files in index/ go; the configuration folder's own .sqlite files stay")
    func sweepTouchesOnlyOrphansInIndexDirectory() async throws {
        let scene = try CoordinatorScene("SwiftResticOrphanSweep")
        defer { scene.remove() }
        let root = scene.root
        let coordinator = scene.coordinator
        let fileManager = FileManager.default

        // A configured repository and an unconfigured one, both with an open
        // store — an open store is never swept, whatever the list says.
        let configured = scene.repositoryID
        let openButUnlisted = UUID()
        await coordinator.reconcile(repositoryID: configured, snapshots: [], generation: 1)
        await coordinator.reconcile(repositoryID: openButUnlisted, snapshots: [], generation: 1)

        // An orphan with both sidecars, and names that are not index files.
        let orphan = UUID()
        let index = coordinator.indexDirectory
        // SQLite's own names for a database's files, spelled here rather than
        // read from `IndexCoordinator`: the sweep must match what SQLite
        // writes, and a misspelling shared with the test would pass unseen.
        let orphanFiles = ["", "-wal", "-shm"].map { index.appendingPathComponent(orphan.uuidString + ".sqlite" + $0) }
        let strangers = ["notes.sqlite", "readme.txt", orphan.uuidString + ".sqlite.bak"].map { index.appendingPathComponent($0) }
        // The index's earlier home: `<configDir>/<uuid>.sqlite`, for the
        // orphan's UUID and the configured one alike. Never touched.
        let earlierHome = [orphan, configured].map { root.appendingPathComponent($0.uuidString + ".sqlite") }
        for file in orphanFiles + strangers + earlierHome {
            try Data("x".utf8).write(to: file)
        }

        await coordinator.sweepOrphanFiles(configured: [configured])

        for file in orphanFiles {
            #expect(!fileManager.fileExists(atPath: file.path), "orphan \(file.lastPathComponent) survived")
        }
        for file in strangers + earlierHome {
            #expect(fileManager.fileExists(atPath: file.path), "\(file.path) was deleted")
        }
        #expect(fileManager.fileExists(atPath: coordinator.fileURL(for: configured).path))
        #expect(fileManager.fileExists(atPath: coordinator.fileURL(for: openButUnlisted).path))

        // No index folder yet: nothing to sweep, and nothing created.
        let empty = root.appendingPathComponent("fresh")
        let fresh = IndexCoordinator(directory: empty)
        await fresh.sweepOrphanFiles(configured: [])
        #expect(!fileManager.fileExists(atPath: fresh.indexDirectory.path))
    }
}

/// The backfill loop's guards, driven by the scripted client: which step
/// runs, what a failure costs, and what stops a pass. Time-limited: a guard
/// that fails usually fails as a pass that never ends.
@Suite("index coordinator backfill", .timeLimit(.minutes(1)))
struct IndexCoordinatorBackfillTests {
    @Test("N7: a snapshot restic cannot read is walked once per pass, never jumped, and set aside in its second failed pass")
    func stuckSnapshotIsSkippedThenSetAside() async throws {
        let scene = try CoordinatorScene("SwiftResticStuckStep")
        defer { scene.remove() }
        let planB = IndexTestData.planB
        var listing = [
            try CoordinatorScene.snapshot("a1", 10), try CoordinatorScene.snapshot("a2", 20),
            try CoordinatorScene.snapshot("a3", 30),
            try CoordinatorScene.snapshot("b1", 15, plan: planB), try CoordinatorScene.snapshot("b2", 25, plan: planB),
        ]
        let ids = ["a1", "a2", "a3", "a4", "a5", "b1", "b2", "b3"]
        let client = MockResticClient()
            .onListings(Dictionary(uniqueKeysWithValues: ids.map { ($0, CoordinatorScene.content($0)) }))
            .onUnreadable(["a2"])

        // Pass 1: each chain's newest in full, then history. a2's diff and
        // its `ls` both fail; it sits out the pass, and a1 behind it is
        // never tried — the window cannot jump a2. Plan B is untouched by
        // plan A's trouble.
        await scene.reconcile(listing, 1)
        await scene.backfill(client)
        #expect(client.walkCounts["a2"] == 1)
        #expect(client.diffCounts["a2"] == 1)
        #expect(client.walkCounts["a1"] == nil && client.diffCounts["a1"] == nil)
        #expect(try await scene.versions("/data/common.txt") == ["a3", "b2", "b1"])
        #expect(try await !scene.coordinator.isComplete(repositoryID: scene.repositoryID))
        var report = await scene.report
        #expect(report?.fulls == 2)
        #expect(report?.deltas == 1)
        #expect(report?.diffFailed == 1)
        #expect(report?.fullFailed == 1)
        #expect(report?.markedUnreadable == 0)

        // Pass 2: a new backup a4 that restic cannot read either, and a5
        // above it. a4 is walked once, a5 never — a skipped forward
        // candidate leaves its chain no forward step. a2 fails its second
        // pass, though nothing else landed before it, and is set aside at
        // once, which lets the window reach a1 in the same pass.
        listing += [try CoordinatorScene.snapshot("a4", 40), try CoordinatorScene.snapshot("a5", 50)]
        _ = client.onUnreadable(["a2", "a4"])
        await scene.reconcile(listing, 2)
        await scene.backfill(client)
        #expect(client.walkCounts["a4"] == 1)
        #expect(client.walkCounts["a2"] == 2)
        #expect(client.walkCounts["a5"] == nil && client.diffCounts["a5"] == nil)
        report = await scene.report
        #expect(report?.fullFailed == 2)
        #expect(report?.markedUnreadable == 1)
        #expect(report?.fulls == 0 && report?.deltas == 1)
        #expect(try await scene.versions("/data/a1.txt") == ["a1"])

        // Pass 3: plan B's new backup lands, and a4 fails its second pass
        // and is set aside, so the window reaches a5 past it.
        listing.append(try CoordinatorScene.snapshot("b3", 60, plan: planB))
        await scene.reconcile(listing, 3)
        await scene.backfill(client)
        report = await scene.report
        #expect(report?.markedUnreadable == 1)
        #expect(report?.deltas == 2)
        #expect(client.walkCounts["a4"] == 2)
        #expect(try await scene.versions("/data/a5.txt") == ["a5"])
        #expect(try await scene.versions("/data/a2.txt").isEmpty)
        #expect(try await scene.versions("/data/a4.txt").isEmpty)
        #expect(try await !scene.coordinator.isComplete(repositoryID: scene.repositoryID))
        #expect(try await scene.violations.isEmpty)

        // The next launch releases the set-aside snapshots. Readable now,
        // they are read like any pending one, and the index is complete.
        let relaunched = IndexCoordinator(directory: scene.root)
        _ = client.onUnreadable([])
        await relaunched.reconcile(repositoryID: scene.repositoryID, snapshots: listing, generation: 1)
        await relaunched.runBackfill(repositoryID: scene.repositoryID, service: client, context: scene.context)
        #expect(try await relaunched.versions(ofPath: "/data/a2.txt", repositoryID: scene.repositoryID).map(\.id) == ["a2"])
        #expect(try await relaunched.versions(ofPath: "/data/a4.txt", repositoryID: scene.repositoryID).map(\.id) == ["a4"])
        #expect(try await relaunched.isComplete(repositoryID: scene.repositoryID))
    }

    @Test("an unreadable new backup in a repository's only chain does not block every later backup")
    func loneChainBlockerIsSetAside() async throws {
        let scene = try CoordinatorScene("SwiftResticLoneBlocker")
        defer { scene.remove() }
        let ids = (1 ... 6).map { "a\($0)" }
        let client = MockResticClient()
            .onListings(Dictionary(uniqueKeysWithValues: ids.map { ($0, CoordinatorScene.content($0)) }))
            .onUnreadable(["a2"])
        // One plan, one backup per refresh. a2 is the chain's forward
        // candidate from the moment it is listed, and nothing else is left
        // to read beside it, so no pass that tries it can land anything.
        var listing: [Snapshot] = []
        for (k, id) in ids.enumerated() {
            listing.append(try CoordinatorScene.snapshot(id, Int64(k + 1) * 10))
            await scene.reconcile(listing, UInt64(k + 1))
            await scene.backfill(client)
        }
        // FINAL 8.1: without the quarantine, one bad snapshot blocks its
        // side of the window forever.
        let newest = try await scene.versions("/data/a6.txt")
        let common = try await scene.versions("/data/common.txt")
        #expect(newest == ["a6"])
        #expect(common == ["a6", "a5", "a4", "a3", "a1"])
        #expect(client.walkCounts["a2"] == 2)
        #expect(try await !scene.coordinator.isComplete(repositoryID: scene.repositoryID))
        #expect(try await scene.violations.isEmpty)
    }

    @Test("a snapshot set aside in one launch and still unreadable in the next is set aside again at its first failure")
    func releasedSnapshotDoesNotBlockNewBackups() async throws {
        let scene = try CoordinatorScene("SwiftResticReleasedBlocker")
        defer { scene.remove() }
        let ids = (1 ... 8).map { "a\($0)" }
        let client = MockResticClient()
            .onListings(Dictionary(uniqueKeysWithValues: ids.map { ($0, CoordinatorScene.content($0)) }))
            .onUnreadable(["a3"])
        // Launch 1: the history a1…a5 in one listing, a3 damaged, then a
        // backup a6. a3 is set aside and the window moves past it.
        var listing = try (1 ... 5).map { try CoordinatorScene.snapshot("a\($0)", Int64($0) * 10) }
        await scene.reconcile(listing, 1)
        await scene.backfill(client)
        listing.append(try CoordinatorScene.snapshot("a6", 60))
        await scene.reconcile(listing, 2)
        await scene.backfill(client)
        #expect(await scene.report?.markedUnreadable == 1)
        #expect(try await scene.versions("/data/a6.txt") == ["a6"])
        #expect(try await scene.versions("/data/a1.txt") == ["a1"])

        // Launch 2 releases a3 above the window, where it is the chain's
        // forward candidate ahead of every new backup. Still unreadable, it
        // goes back aside at its first failure, and the backup of the same
        // refresh lands in the same pass.
        let relaunched = IndexCoordinator(directory: scene.root)
        listing.append(try CoordinatorScene.snapshot("a7", 70))
        await relaunched.reconcile(repositoryID: scene.repositoryID, snapshots: listing, generation: 1)
        await relaunched.runBackfill(repositoryID: scene.repositoryID, service: client, context: scene.context)
        let report = await relaunched.lastBackfillReport(repositoryID: scene.repositoryID)
        #expect(report?.markedUnreadable == 1)
        #expect(report?.deltas == 1)
        let a7 = try await relaunched.versions(ofPath: "/data/a7.txt", repositoryID: scene.repositoryID).map(\.id)
        #expect(a7 == ["a7"])
        listing.append(try CoordinatorScene.snapshot("a8", 80))
        await relaunched.reconcile(repositoryID: scene.repositoryID, snapshots: listing, generation: 2)
        await relaunched.runBackfill(repositoryID: scene.repositoryID, service: client, context: scene.context)
        let a8 = try await relaunched.versions(ofPath: "/data/a8.txt", repositoryID: scene.repositoryID).map(\.id)
        #expect(a8 == ["a8"])
        #expect(client.walkCounts["a3"] == 3)
    }

    @Test("a release that fails takes no number and leaves the launch's release to the next reconcile, which makes it")
    func failedReleaseIsRetried() async throws {
        let scene = try CoordinatorScene("SwiftResticFailedRelease")
        defer { scene.remove() }
        let client = MockResticClient()
            .onListings(["a1": CoordinatorScene.content("a1"), "a2": CoordinatorScene.content("a2")])
            .onUnreadable(["a2"])
        // Launch 1: a2 fails `unreadableAfter` passes and is set aside.
        let listing = [try CoordinatorScene.snapshot("a1", 10), try CoordinatorScene.snapshot("a2", 20)]
        await scene.reconcile(listing, 1)
        for _ in 0 ..< IndexCoordinator.unreadableAfter { await scene.backfill(client) }
        #expect(try await scene.coordinator.read(scene.repositoryID) { try $0.snapStates() } == ["a1": 1, "a2": 2])

        // Launch 2's first reconcile: its release fails on the writer.
        let relaunched = IndexCoordinator(directory: scene.root)
        let store = try await relaunched.read(scene.repositoryID) { $0 }
        try await store.pool.writeWithoutTransaction {
            try $0.execute(sql: "CREATE TEMP TRIGGER scripted_failure BEFORE UPDATE ON snap BEGIN SELECT RAISE(ABORT, 'scripted'); END")
        }
        await relaunched.reconcile(repositoryID: scene.repositoryID, snapshots: listing, generation: 1)
        #expect(try store.snapStates() == ["a1": 1, "a2": 2])
        try await store.pool.writeWithoutTransaction { try $0.execute(sql: "DROP TRIGGER temp.scripted_failure") }

        // The next reconcile releases a2, and its listing — numbered like the
        // failed one, which took no number — lands with a new backup in it.
        let withBackup = listing + [try CoordinatorScene.snapshot("a3", 30)]
        await relaunched.reconcile(repositoryID: scene.repositoryID, snapshots: withBackup, generation: 1)
        #expect(try store.snapStates() == ["a1": 1, "a2": 0, "a3": 0])
    }

    @Test("a pass cancelled while its planner read waits for a reader starts no restic step")
    func cancelDuringPlanningStartsNoStep() async throws {
        let scene = try CoordinatorScene("SwiftResticCancelPlanning")
        defer { scene.remove() }
        let client = MockResticClient().onListings(["a1": CoordinatorScene.content("a1")])
        await scene.reconcile([try CoordinatorScene.snapshot("a1", 10)], 1)
        // Every reader taken, so the pass's planner read waits for one.
        let hold = ReaderHold(try await scene.coordinator.read(scene.repositoryID) { $0 })
        #expect(await eventually(within: 10) { hold.isHeld })
        let pass = Task { await scene.backfill(client) }
        // Long enough for the pass to reach its planner read and park there.
        try await Task.sleep(for: .milliseconds(300))
        pass.cancel()
        hold.release()
        await pass.value
        // The read answered `.full(a1)` after the cancel; nothing ran it.
        #expect(client.walkCounts.isEmpty)
        #expect(client.diffCounts.isEmpty)
    }

    @Test("a dead window end is counted: the next backup is read in full, and the answers stay exact")
    func deadWindowEndCounted() async throws {
        let scene = try CoordinatorScene("SwiftResticDeadEnd")
        defer { scene.remove() }
        let client = MockResticClient().onListings([
            "s1": CoordinatorScene.content("s1"), "s2": CoordinatorScene.content("s2"), "s3": CoordinatorScene.content("s3"),
        ])
        let s1 = try CoordinatorScene.snapshot("s1", 1)
        await scene.reconcile([s1, try CoordinatorScene.snapshot("s2", 2)], 1)
        await scene.backfill(client)
        // The newest snapshot is forgotten outside the app, and a backup
        // follows: there is no alive base for a delta.
        await scene.reconcile([s1, try CoordinatorScene.snapshot("s3", 3)], 2)
        await scene.backfill(client)
        let report = await scene.report
        #expect(report?.deadWindowEnd == 1)
        #expect(report?.fulls == 1)
        #expect(report?.deltas == 0)
        #expect(try await scene.versions("/data/common.txt") == ["s3", "s1"])
        #expect(try await scene.versions("/data/s2.txt").isEmpty)
        // The full compare closed s2's run at s2's dead seq: garbage that
        // the next reconcile's housekeeping collects, and that (a)–(c) hold
        // only after — so the check comes after one.
        await scene.reconcile([s1, try CoordinatorScene.snapshot("s3", 3)], 3)
        #expect(try await scene.violations == [])
    }

    @Test("a listing with no node is refused: the snapshot stays pending instead of reading as empty")
    func emptyListingRefused() async throws {
        let scene = try CoordinatorScene("SwiftResticEmptyListing")
        defer { scene.remove() }
        let client = MockResticClient().onListings(["s1": [:]])
        await scene.reconcile([try CoordinatorScene.snapshot("s1", 1)], 1)
        await scene.backfill(client)
        let report = await scene.report
        #expect(report?.fullFailed == 1)
        #expect(report?.fulls == 0)
        #expect(try await !scene.coordinator.isComplete(repositoryID: scene.repositoryID))
    }

    @Test("a diff or listing with lines that did not decode is not taken whole: the diff falls back, the listing fails")
    func malformedStreamsRefused() async throws {
        let scene = try CoordinatorScene("SwiftResticMalformed")
        defer { scene.remove() }
        let client = MockResticClient()
            .onListings(["s1": CoordinatorScene.content("s1"), "s2": CoordinatorScene.content("s2")])
            .onMalformed(["s2": 1])
        await scene.reconcile([try CoordinatorScene.snapshot("s1", 1)], 1)
        await scene.backfill(client)
        await scene.reconcile([try CoordinatorScene.snapshot("s1", 1), try CoordinatorScene.snapshot("s2", 2)], 2)
        await scene.backfill(client)
        // s2's diff dropped a line, so the full route was tried — and its
        // listing dropped one too, so s2 stays pending rather than indexed
        // from a stream known to be short.
        let report = await scene.report
        #expect(report?.diffFailed == 1)
        #expect(report?.fullFailed == 1)
        #expect(report?.deltas == 0 && report?.fulls == 0)
        #expect(try await scene.versions("/data/common.txt") == ["s1"])

        // The same snapshot, read cleanly on a later pass, lands by its diff.
        _ = client.onMalformed([:])
        await scene.reconcile([try CoordinatorScene.snapshot("s1", 1), try CoordinatorScene.snapshot("s2", 2)], 3)
        await scene.backfill(client)
        #expect(await scene.report?.deltas == 1)
        #expect(try await scene.versions("/data/common.txt") == ["s2", "s1"])
    }

    @Test("a kind change a diff spells as a bare add is refused by the index, counted, and read in full")
    func kindChangeSpelledAsAddFallsBack() async throws {
        let scene = try CoordinatorScene("SwiftResticKindChanged")
        defer { scene.remove() }
        // k is a file in s1 and a folder in s2. The scripted diff says only
        // "+ k/" and "+ k/f" — no `T`, no removal of the file — which the
        // collector cannot catch and the index refuses (`kindChanged`).
        let client = MockResticClient()
            .onListings([
                "s1": ["/data": true, "/data/k": false],
                "s2": ["/data": true, "/data/k": true, "/data/k/f": false],
            ])
            .onDiffLines(["s2": [
                ResticDiffChange(path: "/data/k/", modifier: "+"),
                ResticDiffChange(path: "/data/k/f", modifier: "+"),
            ]])
        let s1 = try CoordinatorScene.snapshot("s1", 1)
        await scene.reconcile([s1], 1)
        await scene.backfill(client)
        await scene.reconcile([s1, try CoordinatorScene.snapshot("s2", 2)], 2)
        await scene.backfill(client)

        let report = await scene.report
        #expect(report?.kindChanged == 1)
        #expect(report?.typeChange == 0 && report?.diffFailed == 0)
        #expect(report?.deltas == 0 && report?.fulls == 1)
        #expect(client.diffCounts["s2"] == 1 && client.walkCounts["s2"] == 1)
        let held = try await scene.coordinator.contains(
            paths: ["/data/k", "/data/k/f"], inSnapshot: "s2", repositoryID: scene.repositoryID
        )
        #expect(held == ["/data/k": true, "/data/k/f": false].byPathKey)
        #expect(try await scene.violations.isEmpty)
    }

    @Test("a snapshot that dies and returns mid-stream is refused as stale, planned again, and read from the top")
    func midStreamReturnIsRefusedAndReread() async throws {
        let scene = try CoordinatorScene("SwiftResticMidStream")
        defer { scene.remove() }
        let coordinator = scene.coordinator
        let repositoryID = scene.repositoryID
        let listing = [try CoordinatorScene.snapshot("s1", 1)]
        let fired = Flag()
        let client = MockResticClient()
            .onListings(["s1": CoordinatorScene.content("s1")])
            .onWalkStart { _ in
                guard !fired.isSet else { return }
                fired.set()
                // Two refreshes land while the stream is open: one without
                // s1, then one with it again — a new row the stream did not
                // begin on.
                await coordinator.reconcile(repositoryID: repositoryID, snapshots: [], generation: 2)
                await coordinator.reconcile(repositoryID: repositoryID, snapshots: listing, generation: 3)
            }
        await scene.reconcile(listing, 1)
        await scene.backfill(client)
        let report = await scene.report
        #expect(report?.refused == 1)
        #expect(report?.fulls == 1)
        #expect(report?.fullFailed == 0)
        #expect(client.walkCounts["s1"] == 2)
        #expect(try await scene.versions("/data/s1.txt") == ["s1"])
        #expect(try await coordinator.isComplete(repositoryID: repositoryID))
        #expect(try await scene.violations.isEmpty)
    }

    @Test("a snapshot refused on every read is planned again once, then given up for the pass")
    func persistentRefusalEndsThePass() async throws {
        let scene = try CoordinatorScene("SwiftResticRefusedTwice")
        defer { scene.remove() }
        let coordinator = scene.coordinator
        let repositoryID = scene.repositoryID
        let listing = [try CoordinatorScene.snapshot("s1", 1)]
        let generations = Counter(start: 1)
        // Every read of s1 sees it leave the listing and come back as a new
        // row before the stream's final.
        let client = MockResticClient()
            .onListings(["s1": CoordinatorScene.content("s1")])
            .onWalkStart { _ in
                await coordinator.reconcile(repositoryID: repositoryID, snapshots: [], generation: generations.next())
                await coordinator.reconcile(repositoryID: repositoryID, snapshots: listing, generation: generations.next())
            }
        await scene.reconcile(listing, generations.next())
        await scene.backfill(client)
        #expect(client.walkCounts["s1"] == 2)
        let report = await scene.report
        #expect(report?.refused == 2)
        #expect(report?.fullFailed == 0)
        #expect(try await !coordinator.isComplete(repositoryID: repositoryID))
    }

    @Test("a failure counts even as the pass's first step, before anything lands")
    func failureBeforeProgressCounts() async throws {
        let scene = try CoordinatorScene("SwiftResticLateStrike")
        defer { scene.remove() }
        let planB = IndexTestData.planB
        let ids = ["a1", "a2", "b1", "b2", "b3"]
        let client = MockResticClient()
            .onListings(Dictionary(uniqueKeysWithValues: ids.map { ($0, CoordinatorScene.content($0)) }))
            .onUnreadable(["a2"])
        var listing = [try CoordinatorScene.snapshot("a1", 1), try CoordinatorScene.snapshot("b1", 2, plan: planB)]
        await scene.reconcile(listing, 1)
        await scene.backfill(client)
        // a2 is the newest new backup, so each pass tries it first — before
        // plan B's older new backup lands. Counting only failures that come
        // after a landing would never count it, and plan A's window would
        // stay stuck below it for good.
        listing += [try CoordinatorScene.snapshot("a2", 20), try CoordinatorScene.snapshot("b2", 15, plan: planB)]
        await scene.reconcile(listing, 2)
        await scene.backfill(client)
        #expect(await scene.report?.markedUnreadable == 0)
        listing.append(try CoordinatorScene.snapshot("b3", 16, plan: planB))
        await scene.reconcile(listing, 3)
        await scene.backfill(client)
        let report = await scene.report
        #expect(report?.deltas == 1)
        #expect(report?.markedUnreadable == 1)
        #expect(client.walkCounts["a2"] == 2)
    }

    @Test("a reset cancels and awaits a running backfill before it deletes the file; the rebuild then reads cleanly")
    func resetStopsTheBackfill() async throws {
        let scene = try CoordinatorScene("SwiftResticResetBackfill")
        defer { scene.remove() }
        let client = MockResticClient()
            .onListings(["s1": CoordinatorScene.content("s1")])
            .onHangingWalks(["s1"])
        let listing = [try CoordinatorScene.snapshot("s1", 1)]
        await scene.reconcile(listing, 1)
        await scene.coordinator.startBackfill(repositoryID: scene.repositoryID, service: client, context: scene.context)
        #expect(await eventually(within: 10) { client.walkCounts["s1"] == 1 })

        await scene.coordinator.resetRepository(repositoryID: scene.repositoryID)
        #expect(!FileManager.default.fileExists(atPath: scene.coordinator.fileURL(for: scene.repositoryID).path))
        #expect(await scene.report == nil)

        _ = client.onHangingWalks([])
        await scene.reconcile(listing, 1)
        await scene.backfill(client)
        #expect(try await scene.versions("/data/s1.txt") == ["s1"])
        #expect(try await scene.violations.isEmpty)
    }

    @Test("shutdown cancels a running walk, which stops the pass without counting against the snapshot, and refuses later backfills")
    func shutdownStopsTheBackfill() async throws {
        let scene = try CoordinatorScene("SwiftResticIndexShutdown")
        defer { scene.remove() }
        let client = MockResticClient()
            .onListings(["s1": CoordinatorScene.content("s1"), "s2": CoordinatorScene.content("s2")])
            .onHangingWalks(["s2"])
        await scene.reconcile([try CoordinatorScene.snapshot("s1", 1), try CoordinatorScene.snapshot("s2", 2)], 1)
        await scene.coordinator.startBackfill(repositoryID: scene.repositoryID, service: client, context: scene.context)
        #expect(await eventually(within: 10) { client.walkCounts["s2"] == 1 })

        await scene.coordinator.shutdown()
        let report = await scene.report
        #expect(report?.fullFailed == 0)
        #expect(report?.fulls == 0)
        // Nothing ran after the cancelled walk: no fallback, no next snapshot.
        #expect(client.walkCounts == ["s2": 1])

        // Readable now, and still nothing is walked: the coordinator is
        // shut down.
        _ = client.onHangingWalks([])
        await scene.coordinator.runBackfill(repositoryID: scene.repositoryID, service: client, context: scene.context)
        await scene.coordinator.startBackfill(repositoryID: scene.repositoryID, service: client, context: scene.context)
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.walkCounts == ["s2": 1])
    }

    @Test("the scripted ls streams restic's order: depth-first, siblings by their bytes")
    func scriptedListingIsResticOrder() async throws {
        let client = MockResticClient().onListings(["s1": ["/data": true, "/data/x": false, "/data.bak": false]])
        let collector = NodeCollector()
        try await client.walkSnapshot(RepositoryContext(repository: Repository(), password: "x"), snapshotID: "s1") { node in
            collector.append(node)
        }
        // Components ["data"] < ["data", "x"] < ["data.bak"]; String order,
        // the mock's old `keys.sorted()`, puts "/data.bak" second.
        #expect(collector.paths == ["/data", "/data/x", "/data.bak"])
    }
}

/// What a reset and the reads do to each other, and that the reads never
/// need the actor.
@Suite("index coordinator concurrency")
struct IndexCoordinatorConcurrencyTests {
    @Test("N11: a reset waits for a running read, holds new reads at its gate, and leaves a healthy file")
    func resetUnderRead() async throws {
        let scene = try CoordinatorScene("SwiftResticResetUnderRead")
        defer { scene.remove() }
        let repositoryID = scene.repositoryID
        let coordinator = scene.coordinator
        let client = MockResticClient().onListings(["s1": CoordinatorScene.content("s1")])
        let listing = [try CoordinatorScene.snapshot("s1", 1)]
        await scene.reconcile(listing, 1)
        await scene.backfill(client)
        coordinator.cacheListing(snapshotID: "s1", directory: "/data", nodes: [], repositoryID: repositoryID)
        await coordinator.cacheWritesSettled()
        #expect(await coordinator.cachedListing(snapshotID: "s1", directory: "/data", repositoryID: repositoryID) == [])

        // A read that is running when the reset starts, held open.
        let entered = Flag()
        let release = Flag()
        let running = Task {
            try await coordinator.read(repositoryID) { store in
                entered.set()
                while !release.isSet { try await Task.sleep(for: .milliseconds(5)) }
                return try await store.versions(ofPath: "/data/s1.txt").map(\.id)
            }
        }
        #expect(await eventually(within: 10) { entered.isSet })

        let resetDone = Flag()
        let reset = Task {
            await coordinator.resetRepository(repositoryID: repositoryID)
            resetDone.set()
        }
        // The gate is closed once the caches read as a miss.
        #expect(await eventually(within: 10) {
            await coordinator.cachedListing(snapshotID: "s1", directory: "/data", repositoryID: repositoryID) == nil
        })
        let lateDone = Flag()
        let late = Task {
            defer { lateDone.set() }
            return try await coordinator.versions(ofPath: "/data/s1.txt", repositoryID: repositoryID)
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!resetDone.isSet, "the reset finished under a running read")
        #expect(!lateDone.isSet, "a read passed the reset's gate")
        #expect(FileManager.default.fileExists(atPath: coordinator.fileURL(for: repositoryID).path))

        // Released, the running read answers from the old pool — still open.
        release.set()
        #expect(try await running.value == ["s1"])
        await reset.value
        // The read held at the gate opened the fresh, empty file.
        #expect(try await late.value.isEmpty)

        // The rebuild lands on the new file under the same generation.
        await scene.reconcile(listing, 1)
        await scene.backfill(client)
        #expect(try await scene.versions("/data/s1.txt") == ["s1"])
        #expect(try await scene.violations.isEmpty)
    }

    @Test("completeness needs a listing: none before the first reconcile, none between a rebuild's reset and its reconcile, kept across a relaunch")
    func completenessNeedsAListing() async throws {
        let scene = try CoordinatorScene("SwiftResticCompletenessNeedsAListing")
        defer { scene.remove() }
        let coordinator = scene.coordinator
        let repositoryID = scene.repositoryID
        // No listing has landed: a new repository, a missing password, an
        // offline remote. The index knows nothing, so it cannot answer
        // exactly — Find Files must ask restic, which can say why.
        let beforeAnyListing = try await coordinator.isComplete(repositoryID: repositoryID)
        #expect(beforeAnyListing == false)

        let client = MockResticClient().onListings(["s1": CoordinatorScene.content("s1")])
        let listing = [try CoordinatorScene.snapshot("s1", 1)]
        await scene.reconcile(listing, 1)
        await scene.backfill(client)
        #expect(try await coordinator.isComplete(repositoryID: repositoryID))
        #expect(try await scene.versions("/data/s1.txt") == ["s1"])

        // A relaunch keeps a built file complete before its first
        // reconcile: what the file has applied is on disk, not in memory.
        let relaunched = IndexCoordinator(directory: scene.root)
        #expect(try await relaunched.isComplete(repositoryID: repositoryID))

        // Rebuild Search Index…: the reset has returned, the rebuild's
        // reconcile has not landed yet.
        await coordinator.resetRepository(repositoryID: repositoryID)
        let afterReset = try await coordinator.isComplete(repositoryID: repositoryID)
        #expect(afterReset == false)
        await scene.reconcile(listing, 1)
        #expect(try await coordinator.isComplete(repositoryID: repositoryID) == false)
        await scene.backfill(client)
        #expect(try await coordinator.isComplete(repositoryID: repositoryID))

        // A repository with no snapshots whose empty listing was applied is
        // complete: there is nothing left to read.
        let empty = UUID()
        await coordinator.reconcile(repositoryID: empty, snapshots: [], generation: 1)
        #expect(try await coordinator.isComplete(repositoryID: empty))
    }

    @Test("N12: reads answer, and the actor stays free, while a reconcile waits for a held writer")
    func readsBesideAHeldWriter() async throws {
        let scene = try CoordinatorScene("SwiftResticReadsOffActor")
        defer { scene.remove() }
        let repositoryID = scene.repositoryID
        let coordinator = scene.coordinator
        var content: [String: Bool] = ["/data": true]
        for index in 0..<2_000 { content["/data/f\(index).txt"] = false }
        let client = MockResticClient().onListings(["s1": content, "s2": content])
        await scene.reconcile([try CoordinatorScene.snapshot("s1", 1)], 1)
        await scene.backfill(client)

        // Hold the index's one writer from outside, as a long full compare
        // would.
        let hold = WriterHold(try await coordinator.read(repositoryID) { $0 })
        #expect(await eventually(within: 10) { hold.isHeld })

        // A reconcile now waits on the writer, off the actor.
        let reconciled = Flag()
        let bothListed = [try CoordinatorScene.snapshot("s1", 1), try CoordinatorScene.snapshot("s2", 2)]
        let reconcile = Task {
            await coordinator.reconcile(repositoryID: repositoryID, snapshots: bothListed, generation: 2)
            reconciled.set()
        }
        try await Task.sleep(for: .milliseconds(50))

        let answered = Flag()
        let reads = Task {
            _ = await coordinator.lastBackfillReport(repositoryID: repositoryID)
            let versions = try await coordinator.versions(ofPath: "/data/f7.txt", repositoryID: repositoryID).map(\.id)
            let hits = try await coordinator.searchPaths(matching: "f1", repositoryID: repositoryID, limit: 5)
            let summaries = try await coordinator.versionSummaries(ofPaths: ["/data/f7.txt"], repositoryID: repositoryID)
            let held = try await coordinator.contains(paths: ["/data/f7.txt"], inSnapshot: "s1", repositoryID: repositoryID)
            // The two searches the app runs: the Restore pane's and Find Files'.
            let membership = try await coordinator.searchWithMembership(
                matching: "f1", inSnapshot: "s1", repositoryID: repositoryID, limit: 5
            )
            let summarized = try await coordinator.searchWithSummaries(matching: "f7", repositoryID: repositoryID, limit: 1)
            let complete = try await coordinator.isComplete(repositoryID: repositoryID)
            answered.set()
            return (versions, hits.count, summaries["/data/f7.txt"]?.count, held, membership, summarized, complete)
        }
        let answeredWhileHeld = await eventually(within: 10) { answered.isSet }
        let reconcileWaited = !reconciled.isSet
        hold.release()
        #expect(answeredWhileHeld, "reads waited for the writer or the actor")
        #expect(reconcileWaited, "the writer was not actually held")

        let (versions, hitCount, summaryCount, held, membership, summarized, complete) = try await reads.value
        #expect(versions == ["s1"])
        #expect(hitCount == 5)
        #expect(summaryCount == 1)
        #expect(held == ["/data/f7.txt": false])
        #expect(membership.hits.count == 5)
        #expect(membership.inSnapshot.count == 5)
        #expect(membership.inSnapshot.values.allSatisfy { $0 == false })
        #expect(summarized.hits.map(\.path) == ["/data/f7.txt"])
        #expect(summarized.summaries["/data/f7.txt"]?.count == 1)
        #expect(complete)
        await reconcile.value
        #expect(await eventually(within: 10) { hold.isFreed })
        // The reconcile landed once the writer was free: s2 is pending now.
        #expect(try await !coordinator.isComplete(repositoryID: repositoryID))
    }

    @Test("N12: a search cancelled while it runs throws CancellationError promptly")
    func cancelledSearchStops() async throws {
        let scene = try CoordinatorScene("SwiftResticSearchCancel")
        defer { scene.remove() }
        let repositoryID = scene.repositoryID
        let coordinator = scene.coordinator
        var content: [String: Bool] = ["/data": true]
        for index in 0..<30_000 { content["/data/f\(index).txt"] = false }
        let client = MockResticClient().onListings(["s1": content])
        await scene.reconcile([try CoordinatorScene.snapshot("s1", 1)], 1)
        await scene.backfill(client)

        // Every one of the 30k names matches, and the limit lets the walk
        // visit them all: long enough to be cancelled mid-run. The Restore
        // pane's read — the one each keystroke cancels.
        let start = Date()
        let all = try await coordinator.searchWithMembership(
            matching: "f", inSnapshot: "s1", repositoryID: repositoryID, limit: 100_000
        )
        let whole = Date().timeIntervalSince(start)
        #expect(all.hits.count == 30_000)
        #expect(all.inSnapshot.count == 30_000)

        let search = Task {
            try await coordinator.searchWithMembership(
                matching: "f", inSnapshot: "s1", repositoryID: repositoryID, limit: 100_000
            )
        }
        try await Task.sleep(for: .seconds(whole / 4))
        let cancelledAt = Date()
        search.cancel()
        do {
            _ = try await search.value
            Issue.record("the cancelled search ran to the end (a whole search takes \(whole)s)")
        } catch is CancellationError {
            let latency = Date().timeIntervalSince(cancelledAt)
            print("cancelled search: whole run \(String(format: "%.3f", whole))s, stopped \(String(format: "%.3f", latency))s after cancel")
            #expect(latency < max(whole / 2, 0.05))
        }
    }

    @Test(
        "a read that meets a reset's gate parks until it reopens: cancelled, it throws CancellationError at once while the reset still runs; uncancelled, it answers from the fresh file",
        .timeLimit(.minutes(1))
    )
    func readsParkAtTheGate() async throws {
        let scene = try CoordinatorScene("SwiftResticGateWaiters")
        defer { scene.remove() }
        let repositoryID = scene.repositoryID
        let coordinator = scene.coordinator
        let client = MockResticClient().onListings(["s1": CoordinatorScene.content("s1")])
        await scene.reconcile([try CoordinatorScene.snapshot("s1", 1)], 1)
        await scene.backfill(client)
        coordinator.cacheListing(snapshotID: "s1", directory: "/data", nodes: [], repositoryID: repositoryID)
        await coordinator.cacheWritesSettled()

        // A read held open keeps the reset at its drain, the gate closed.
        let entered = Flag()
        let release = Flag()
        let holding = Task {
            try await coordinator.read(repositoryID) { _ in
                entered.set()
                while !release.isSet { try await Task.sleep(for: .milliseconds(5)) }
            }
        }
        #expect(await eventually(within: 10) { entered.isSet })
        let resetDone = Flag()
        let reset = Task {
            await coordinator.resetRepository(repositoryID: repositoryID)
            resetDone.set()
        }
        // The gate is closed once the caches read as a miss.
        #expect(await eventually(within: 10) {
            await coordinator.cachedListing(snapshotID: "s1", directory: "/data", repositoryID: repositoryID) == nil
        })

        let cancelledDone = Flag()
        let cancelled = Task {
            defer { cancelledDone.set() }
            return try await coordinator.isComplete(repositoryID: repositoryID)
        }
        let waitingDone = Flag()
        let waiting = Task {
            defer { waitingDone.set() }
            return try await coordinator.versions(ofPath: "/data/s1.txt", repositoryID: repositoryID)
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!cancelledDone.isSet && !waitingDone.isSet, "a read passed the reset's gate")

        // Cancelled before it can park, a read stops at once too: it asks
        // only once it is cancelled, so its cancellation lands before its
        // waiter could be queued, whatever the scheduler does.
        let earlyDone = Flag()
        let early = Task {
            defer { earlyDone.set() }
            while !Task.isCancelled { await Task.yield() }
            return try await coordinator.isComplete(repositoryID: repositoryID)
        }
        early.cancel()
        let earlyStopped = await eventually(within: 2) { earlyDone.isSet }

        cancelled.cancel()
        let stoppedPromptly = await eventually(within: 2) { cancelledDone.isSet }
        let resetStillHeld = !resetDone.isSet
        let otherStillWaiting = !waitingDone.isSet
        release.set()
        #expect(earlyStopped, "a read cancelled before it parked waited for the reset")
        #expect(stoppedPromptly, "a read cancelled at the gate waited for the reset")
        #expect(resetStillHeld, "the reset was not actually held")
        #expect(otherStillWaiting, "the uncancelled read passed the gate early")
        // Awaited only once they ended: a lost wake-up fails the checks
        // above rather than hanging here.
        if earlyStopped { await #expect(throws: CancellationError.self) { try await early.value } }
        if stoppedPromptly { await #expect(throws: CancellationError.self) { try await cancelled.value } }

        try await holding.value
        await reset.value
        let answered = await eventually(within: 10) { waitingDone.isSet }
        #expect(answered, "the read parked at the gate was not woken when the reset ended")
        // It answered from the fresh, empty file.
        if answered { #expect(try await waiting.value.isEmpty) }
    }

    @Test(
        "a browse-cache capture is handed over, not awaited: settled waits for the writer; shutdown waits for captures handed over before it and drops later ones",
        .timeLimit(.minutes(1))
    )
    func cacheCapturesAreHandedOver() async throws {
        let scene = try CoordinatorScene("SwiftResticCacheHandOver")
        defer { scene.remove() }
        let repositoryID = scene.repositoryID
        let coordinator = scene.coordinator
        await scene.reconcile([], 1)
        let node = SnapshotNode(name: "a.txt", type: .file, path: "/src/a.txt", size: 1, mtime: nil)

        // The writer held, as a backfill's chunk holds it: the captures
        // return at once (they are synchronous), and only settling waits.
        let hold = WriterHold(try await coordinator.read(repositoryID) { $0 })
        #expect(await eventually(within: 10) { hold.isHeld })
        coordinator.cacheListing(snapshotID: "s1", directory: "/src", nodes: [node], repositoryID: repositoryID)
        coordinator.cacheDiff(
            olderID: "s0", newerID: "s1",
            changes: [ResticDiffChange(path: "/src/a.txt", modifier: "+")], repositoryID: repositoryID
        )
        let settled = Flag()
        let settling = Task {
            await coordinator.cacheWritesSettled()
            settled.set()
        }
        try await Task.sleep(for: .milliseconds(150))
        let settleWaited = !settled.isSet
        hold.release()
        #expect(settleWaited, "settling did not wait for the queued writes")
        await settling.value
        #expect(await coordinator.cachedListing(snapshotID: "s1", directory: "/src", repositoryID: repositoryID)?.map(\.path) == ["/src/a.txt"])
        #expect(await coordinator.cachedDiff(olderID: "s0", newerID: "s1", repositoryID: repositoryID)?.count == 1)

        // Quit: a capture handed over before shutdown lands before it
        // returns; one offered after is dropped, never started.
        let hold2 = WriterHold(try await coordinator.read(repositoryID) { $0 })
        #expect(await eventually(within: 10) { hold2.isHeld })
        coordinator.cacheListing(snapshotID: "s2", directory: "/src", nodes: [node], repositoryID: repositoryID)
        let shutDown = Flag()
        let shutdown = Task {
            await coordinator.shutdown()
            shutDown.set()
        }
        try await Task.sleep(for: .milliseconds(150))
        let shutdownWaited = !shutDown.isSet
        coordinator.cacheListing(snapshotID: "s3", directory: "/src", nodes: [node], repositoryID: repositoryID)
        hold2.release()
        await shutdown.value
        #expect(shutdownWaited, "shutdown returned with a capture still queued")
        #expect(await coordinator.cachedListing(snapshotID: "s2", directory: "/src", repositoryID: repositoryID) != nil)
        await coordinator.cacheWritesSettled()
        #expect(await coordinator.cachedListing(snapshotID: "s3", directory: "/src", repositoryID: repositoryID) == nil)
    }
}
