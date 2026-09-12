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
