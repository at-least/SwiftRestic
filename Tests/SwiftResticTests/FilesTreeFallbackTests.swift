import Foundation
import Testing

/// The Files tree's way past an index still reading: a folder it holds
/// nothing under is listed from the chain's newest backup with `restic ls`
/// (`FilesTree.folder`), and from the index again once it has read it.
@Suite("restic Files tree fallback", .serialized, .enabled(if: ResticAvailability.isInstalled))
struct ResticFilesFallbackTests {
    @MainActor
    @Test("a folder the index has not read yet is listed from the chain's newest backup through restic, then from the index once it has")
    func folderFallsBackToNewestBackup() async throws {
        let binary = try ResticBinary.locate(userOverride: nil)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticFallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }

        let data = root.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: data.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try "a".write(to: data.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        var repository = Repository()
        repository.name = "Fallback"
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        let password = "fallback-test"
        let service = ResticService(runner: ResticRunner(), binary: binary.url)
        let context = RepositoryContext(repository: repository, password: password)
        _ = try await service.initializeRepository(context)

        var configuration = AppConfiguration()
        configuration.repositories = [repository]
        configuration.settings.resticPathOverride = binary.url.path
        let store = ConfigStore(directory: root.appendingPathComponent("config"))
        try await store.save(configuration)
        let model = AppModel(store: store, secrets: .inMemory([repository.id: (password: password, providerSecret: nil)]))
        // The launch's listing is empty, and the index takes it whole.
        await model.bootstrap()
        await model.tasks.drain()
        #expect(await model.indexIsComplete(repositoryID: repository.id))

        // A first backup lands in the listing; the index has not taken it —
        // the moment between a refresh's listing and its reconcile.
        var plan = BackupPlan()
        plan.name = "Fallback plan"
        plan.repositoryID = repository.id
        plan.sources = [data.path]
        plan.excludePatterns = []
        _ = try await service.backup(context, plan: plan)
        let listing = try await service.snapshots(context, planID: nil, timeout: 60)
        let generation = model.nextListingGeneration()
        model.snapshots[repository.id] = listing
        model.snapshotsGeneration[repository.id] = generation
        #expect(!(await model.indexIsComplete(repositoryID: repository.id)))

        let snapshot = try #require(listing.first)
        let roots = FileNode.roots(repositoryID: repository.id, chainKey: SnapshotIndex.chainKey(for: snapshot))
        let top = try await FilesTree.level(of: roots, model: model)
        #expect(top.entries.map(\.node.path) == [data.path])
        let folder = try #require(top.entries.first?.node)
        let listed = try await FilesTree.level(of: folder, model: model)
        #expect(listed.isFallback)
        #expect(!listed.isComplete)
        #expect(listed.entries.map(\.node.name) == ["Sub", "a.txt"])
        #expect(listed.entries.map(\.node.isDirectory) == [true, false])
        #expect(listed.entries.allSatisfy { $0.isInNewest && $0.newest.id == snapshot.id })

        // Once the index has taken the listing and read the backup, the
        // same folder comes from it.
        model.indexReconcile(repositoryID: repository.id, listing: listing, generation: generation)
        let deadline = Date.now.addingTimeInterval(60)
        while !(await model.indexIsComplete(repositoryID: repository.id)), Date.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await model.indexIsComplete(repositoryID: repository.id), "the index never read the backup")
        let indexed = try await FilesTree.level(of: folder, model: model)
        #expect(!indexed.isFallback)
        #expect(indexed.isComplete)
        #expect(indexed.entries.map(\.node.name) == ["Sub", "a.txt"])

        await model.shutdown()
    }
}
