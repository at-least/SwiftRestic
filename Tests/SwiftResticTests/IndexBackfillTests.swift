import Foundation
import Testing

/// Backfill against the real restic binary: reconcile a listing of real
/// snapshots, stream every snapshot through `restic ls` into the index, and
/// check the run semantics the folder-first restore will stand on. Skipped
/// when restic is not installed, like the other integration suites.
@Suite("index backfill", .serialized, .enabled(if: ResticAvailability.isInstalled))
struct IndexBackfillTests {
    private static let password = "integration-test-password"

    @Test("backfill indexes every snapshot and merges unchanged files into one run")
    func backfillMergesRuns() async throws {
        let binary = try ResticBinary.locate(userOverride: nil)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticIndexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }

        let repositoryDirectory = root.appendingPathComponent("repo")
        let sourceDirectory = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "v1".write(to: sourceDirectory.appendingPathComponent("changed.txt"), atomically: true, encoding: .utf8)
        try "stable".write(to: sourceDirectory.appendingPathComponent("stable.txt"), atomically: true, encoding: .utf8)

        var repository = Repository()
        repository.name = "Index"
        repository.kind = .local
        repository.localPath = repositoryDirectory.path
        var plan = BackupPlan()
        plan.name = "Index plan"
        plan.repositoryID = repository.id
        plan.sources = [sourceDirectory.path]

        let context = RepositoryContext(repository: repository, password: Self.password)
        let service = ResticService(runner: ResticRunner(), binary: binary.url)
        _ = try await service.initializeRepository(context)

        // Two snapshots: one file changes, one does not.
        let first = try await service.backup(context, plan: plan)
        #expect(first.exitCode == 0)
        try "v2".write(to: sourceDirectory.appendingPathComponent("changed.txt"), atomically: true, encoding: .utf8)
        let second = try await service.backup(context, plan: plan)
        #expect(second.exitCode == 0)

        let listing = try await service.snapshots(context)
        #expect(listing.count == 2)

        let indexDirectory = root.appendingPathComponent("indexes")
        let coordinator = IndexCoordinator(directory: indexDirectory)
        await coordinator.reconcile(repositoryID: repository.id, snapshots: listing)

        // Backfill walks newest first and ends with nothing pending.
        await coordinator.runBackfill(repositoryID: repository.id, service: service, context: context)
        let store = try SQLiteIndexStore(path: indexDirectory.appendingPathComponent(repository.id.uuidString + ".sqlite").path)
        #expect(try store.pendingBackfill(limit: 100).isEmpty)

        // The changed file exists in both snapshots, newest first; the
        // unchanged one exists in both through a single merged run.
        // Existence-only semantics: a content modification extends the run
        // (the file still exists), so both files end as ONE entry row — the
        // row count tracks existence episodes, not file versions.
        let changedPath = sourceDirectory.appendingPathComponent("changed.txt").path
        let stablePath = sourceDirectory.appendingPathComponent("stable.txt").path
        #expect(try store.versions(ofPath: changedPath).count == 2)
        #expect(try store.versions(ofPath: stablePath).count == 2)
        #expect(try store.versions(ofPath: changedPath).first?.id == listing.first?.id)
        let planTag = ResticService.planTag(plan.id)
        #expect(try store.readEntryCount(ofPath: stablePath, chain: planTag) == 1)
        #expect(try store.readEntryCount(ofPath: changedPath, chain: planTag) == 1)

        // A second pass over everything changes nothing: reconcile is
        // idempotent and both snapshots are already fully read.
        await coordinator.reconcile(repositoryID: repository.id, snapshots: listing)
        await coordinator.runBackfill(repositoryID: repository.id, service: service, context: context)
        #expect(try store.versions(ofPath: stablePath).count == 2)
        #expect(try store.readEntryCount(ofPath: stablePath, chain: planTag) == 1)
    }

    @Test("diff-built index equals a from-scratch ls load")
    func diffApplyEqualsFullLoad() async throws {
        let binary = try ResticBinary.locate(userOverride: nil)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticDiffEq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }

        let repositoryDirectory = root.appendingPathComponent("repo")
        let sourceDirectory = root.appendingPathComponent("source")
        let subDirectory = sourceDirectory.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDirectory, withIntermediateDirectories: true)
        try "one".write(to: sourceDirectory.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try "doomed".write(to: sourceDirectory.appendingPathComponent("removed.txt"), atomically: true, encoding: .utf8)
        try "v1".write(to: sourceDirectory.appendingPathComponent("edited.txt"), atomically: true, encoding: .utf8)
        try "deep".write(to: subDirectory.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)

        var repository = Repository()
        repository.name = "DiffEq"
        repository.kind = .local
        repository.localPath = repositoryDirectory.path
        var plan = BackupPlan()
        plan.name = "DiffEq plan"
        plan.repositoryID = repository.id
        plan.sources = [sourceDirectory.path]

        let context = RepositoryContext(repository: repository, password: Self.password)
        let service = ResticService(runner: ResticRunner(), binary: binary.url)
        _ = try await service.initializeRepository(context)

        let first = try await service.backup(context, plan: plan)
        #expect(first.exitCode == 0)
        // Change every category the diff knows: content edit, deletion,
        // addition, plus an unchanged file and an untouched directory.
        try "v2".write(to: sourceDirectory.appendingPathComponent("edited.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: sourceDirectory.appendingPathComponent("removed.txt"))
        try "fresh".write(to: sourceDirectory.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
        let second = try await service.backup(context, plan: plan)
        #expect(second.exitCode == 0)
        guard let newSnapshotID = second.summary?.snapshotID else {
            Issue.record("backup produced no snapshot ID")
            return
        }

        let listing = try await service.snapshots(context)
        #expect(listing.count == 2)

        // Path one: the predecessor gets its full read, and the backfill
        // loop must then take the diff route for the new snapshot — the
        // route a live backup rides once history is indexed.
        let diffDirectory = root.appendingPathComponent("index-diff")
        let diffCoordinator = IndexCoordinator(directory: diffDirectory)
        await diffCoordinator.reconcile(repositoryID: repository.id, snapshots: listing)
        let diffStore = try SQLiteIndexStore(path: diffDirectory.appendingPathComponent(repository.id.uuidString + ".sqlite").path)
        let oldestID = try diffStore.pendingBackfill(limit: 2).last!.id
        let fullLoadPaths = try await fullLoad(service, context, snapshotID: oldestID)
        try diffStore.recordContent(
            snapshotID: oldestID,
            entries: fullLoadPaths.map { IndexedEntry(path: $0, isDirectory: false) },
            final: true
        )
        await diffCoordinator.runBackfill(repositoryID: repository.id, service: service, context: context)

        // Path two: from-scratch — every snapshot loaded from its full ls.
        let scratchDirectory = root.appendingPathComponent("index-scratch")
        let scratchCoordinator = IndexCoordinator(directory: scratchDirectory)
        await scratchCoordinator.reconcile(repositoryID: repository.id, snapshots: listing)
        await scratchCoordinator.runBackfill(repositoryID: repository.id, service: service, context: context)
        let scratchStore = try SQLiteIndexStore(path: scratchDirectory.appendingPathComponent(repository.id.uuidString + ".sqlite").path)

        // The two routes must land on the same run set — the advisor's
        // equality bar for the whole diff-apply mechanism.
        let diffEntries = try diffStore.readAllEntries()
        let scratchEntries = try scratchStore.readAllEntries()
        #expect(diffEntries == scratchEntries)
    }

    /// Streams one snapshot's every path from restic — the stand-in for the
    /// full read the equality test builds its baseline from.
    private func fullLoad(
        _ service: ResticService,
        _ context: RepositoryContext,
        snapshotID: String
    ) async throws -> [String] {
        let collector = PathCollector()
        try await service.walkSnapshot(context, snapshotID: snapshotID) { node in
            collector.append(node.path)
        }
        return collector.paths
    }

    private final class PathCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ path: String) {
            lock.lock()
            storage.append(path)
            lock.unlock()
        }

        var paths: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    @Test("a deleted repository's index file goes with it")
    func dropRemovesTheFile() async throws {
        let indexDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticIndexDrop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: indexDirectory) }

        let repositoryID = UUID()
        let file = indexDirectory.appendingPathComponent(repositoryID.uuidString + ".sqlite")
        let coordinator = IndexCoordinator(directory: indexDirectory)
        await coordinator.reconcile(repositoryID: repositoryID, snapshots: [])
        #expect(FileManager.default.fileExists(atPath: file.path))

        await coordinator.dropRepository(repositoryID: repositoryID)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
