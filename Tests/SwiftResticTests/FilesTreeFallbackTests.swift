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

    @MainActor
    @Test("an open folder's files are read ahead in one find: every version row is answered, and a click on any file runs no restic")
    func folderReadAheadAnswersEveryFile() async throws {
        let binary = try ResticBinary.locate(userOverride: nil)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticReadAhead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }

        // The model runs restic through a wrapper that logs every command,
        // so the test counts the finds.
        let calls = root.appendingPathComponent("restic-calls.log")
        let wrapper = root.appendingPathComponent("restic")
        try "#!/bin/sh\necho \"$*\" >> '\(calls.path)'\nexec '\(binary.url.path)' \"$@\"\n"
            .write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        func finds() throws -> [String] {
            let log = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
            return log.split(separator: "\n").map(String.init).filter { $0.hasPrefix("find ") }
        }

        // Three backups: a.txt never changes, b.txt in each, c.txt in the last.
        let data = root.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        var repository = Repository()
        repository.name = "Read-ahead"
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        let password = "read-ahead-test"
        let service = ResticService(runner: ResticRunner(), binary: binary.url)
        let context = RepositoryContext(repository: repository, password: password)
        _ = try await service.initializeRepository(context)
        var plan = BackupPlan()
        plan.name = "Read-ahead plan"
        plan.repositoryID = repository.id
        plan.sources = [data.path]
        plan.excludePatterns = []
        plan.schedule.frequency = .manual
        for round in 0 ..< 3 {
            try "a".write(to: data.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try String(repeating: "b", count: round + 1).write(to: data.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
            try (round == 2 ? "cc" : "c").write(to: data.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
            _ = try await service.backup(context, plan: plan)
        }

        var configuration = AppConfiguration()
        configuration.repositories = [repository]
        configuration.plans = [plan]
        configuration.settings.resticPathOverride = wrapper.path
        let store = ConfigStore(directory: root.appendingPathComponent("config"))
        try await store.save(configuration)
        let model = AppModel(store: store, secrets: .inMemory([repository.id: (password: password, providerSecret: nil)]))
        await model.bootstrap()
        let deadline = Date.now.addingTimeInterval(60)
        while !(await model.indexIsComplete(repositoryID: repository.id)), Date.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await model.indexIsComplete(repositoryID: repository.id), "the index never read the backups")

        let chain = try #require(model.snapshots(for: repository.id).first.map(SnapshotIndex.chainKey(for:)))
        let files = ["a.txt", "b.txt", "c.txt"].map {
            FileNode(repositoryID: repository.id, chainKey: chain, path: data.appendingPathComponent($0).path, isDirectory: false)
        }
        var newest: [FileNode: [String]] = [:]
        for file in files {
            newest[file] = try await model.indexedContentVersions(
                ofPath: file.path, inChain: chain, repositoryID: repository.id
            ).compactMap { $0.snapshots.first?.id }
        }
        #expect(newest.mapValues(\.count) == [files[0]: 1, files[1]: 3, files[2]: 2])
        #expect(try finds().isEmpty)

        await model.warmFileHistory(files).value
        let warmFinds = try finds()
        #expect(warmFinds.count == 1, "\(warmFinds)")
        #expect(files.allSatisfy { file in warmFinds.first?.contains(file.path) == true })

        // Each file's click: every row answered, sizes as backed up, no find.
        for file in files {
            let ids = try #require(newest[file])
            let answers = try await model.fileHistory(repositoryID: repository.id, path: file.path, backupIDs: ids)
            #expect(Set(answers.keys) == Set(ids), "\(file.name)")
            #expect(answers.values.allSatisfy { $0.size != nil && $0.mtime != nil }, "\(file.name)")
        }
        let bSizes = try #require(newest[files[1]]).compactMap { model.fileHistoryAnswers[FileHistoryKey(
            repositoryID: repository.id, backupID: $0, path: files[1].pathKey
        )]?.size }
        #expect(bSizes == [3, 2, 1])
        #expect(try finds().count == 1)

        await model.shutdown()
    }
}
