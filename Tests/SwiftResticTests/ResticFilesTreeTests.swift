import Foundation
import Testing

/// The Files tree over real restic: a plan's folder listed from the disk
/// beside what its backups hold (`FilesTree.level`), and an open folder's
/// files read ahead.
@Suite("restic Files tree", .serialized, .enabled(if: ResticAvailability.isInstalled))
struct ResticFilesTreeTests {
    @MainActor
    @Test("a plan's tree is its folder as the disk holds it: unmarked while the index reads, then a newer file not backed up, a deleted one and a deleted folder's items the backups' alone, an excluded hidden one not at all; a folder gone says so")
    func treeListsTheDisk() async throws {
        let binary = try ResticBinary.locate(userOverride: nil)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticDiskTree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }

        let data = root.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: data.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data.appendingPathComponent("Old"), withIntermediateDirectories: true)
        for name in ["a.txt", "gone.txt", ".keep", ".DS_Store", "Old/x.txt"] {
            try name.write(to: data.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        var repository = Repository()
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        let password = "disk-tree-test"
        let service = ResticService(runner: ResticRunner(), binary: binary.url)
        let context = RepositoryContext(repository: repository, password: password)
        _ = try await service.initializeRepository(context)
        var plan = BackupPlan()
        plan.repositoryID = repository.id
        plan.path = data.path
        plan.excludePatterns = [".DS_Store"]
        plan.schedule.frequency = .manual

        var configuration = AppConfiguration()
        configuration.repositories = [repository]
        configuration.plans = [plan]
        configuration.settings.resticPathOverride = binary.url.path
        let store = ConfigStore(directory: root.appendingPathComponent("config"))
        try await store.save(configuration)
        let model = AppModel(store: store, secrets: .inMemory([repository.id: (password: password, providerSecret: nil)]))
        // The launch's listing is empty, and the index takes it whole.
        await model.bootstrap()
        await model.tasks.drain()
        #expect(await model.indexIsComplete(repositoryID: repository.id))

        // A backup, then the folder moves on: gone.txt and Old deleted,
        // new.txt written. The listing holds the backup; the index has not
        // taken it — the moment between a refresh's listing and its
        // reconcile.
        _ = try await service.backup(context, plan: plan)
        try FileManager.default.removeItem(at: data.appendingPathComponent("gone.txt"))
        try FileManager.default.removeItem(at: data.appendingPathComponent("Old"))
        try "new".write(to: data.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let listing = try await service.snapshots(context, planID: nil, timeout: 60)
        let generation = model.nextListingGeneration()
        model.snapshots[repository.id] = listing
        model.snapshotsGeneration[repository.id] = generation
        #expect(!(await model.indexIsComplete(repositoryID: repository.id)))

        func summary(_ level: FilesTree.Level) -> [String] {
            level.entries.map { entry in
                let mark = switch entry.standing {
                case .onDisk: "disk"
                case .notBackedUp: "not backed up"
                case .deleted: "deleted"
                }
                return "\(entry.node.name)\(entry.node.isDirectory ? "/" : "") \(mark)"
            }
        }
        let roots = FileNode.roots(repositoryID: repository.id, chainKey: ResticService.planTag(plan.id))
        let top = try await FilesTree.level(of: roots, model: model)
        #expect(top.entries.map(\.node.path) == [data.path])
        #expect(summary(top) == ["Data/ disk"])
        let folder = try #require(top.entries.first?.node)
        // While the index reads: the disk's items, none marked, hidden ones
        // left out until a backup is known to hold them.
        let reading = try await FilesTree.level(of: folder, model: model)
        #expect(!reading.isComplete)
        #expect(summary(reading) == ["Sub/ disk", "a.txt disk", "new.txt disk"])

        model.indexReconcile(repositoryID: repository.id, listing: listing, generation: generation)
        let deadline = Date.now.addingTimeInterval(60)
        while !(await model.indexIsComplete(repositoryID: repository.id)), Date.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await model.indexIsComplete(repositoryID: repository.id), "the index never read the backup")
        let read = try await FilesTree.level(of: folder, model: model)
        #expect(read.isComplete)
        #expect(summary(read) == [
            "Sub/ disk", ".keep disk", "a.txt disk", "new.txt not backed up", "Old/ deleted", "gone.txt deleted",
        ])
        #expect(summary(try await FilesTree.level(of: roots, model: model)) == ["Data/ disk"])
        // A deleted folder, opened with Show Deleted Items: what the backups
        // held in it.
        let old = try #require(read.entries.first { $0.node.name == "Old" }?.node)
        #expect(summary(try await FilesTree.level(of: old, model: model)) == ["x.txt deleted"])

        // The folder moved away: the root says so, not an empty tree.
        try FileManager.default.moveItem(at: data, to: root.appendingPathComponent("Moved"))
        await #expect(throws: FolderAbsence.missing(name: "Data")) { try await FilesTree.level(of: roots, model: model) }

        await model.shutdown()
    }

    /// A scratch repository of three backups of one folder — a.txt never
    /// changes, b.txt in each, c.txt in the last, a[1].txt (a glob's
    /// brackets) in the second — and a model over it whose index has read
    /// them all, running restic through a wrapper that logs every command.
    @MainActor
    private struct ReadAheadScene {
        let root: URL
        let model: AppModel
        let repositoryID: UUID
        let files: [FileNode]
        let calls: URL

        init() async throws {
            let binary = try ResticBinary.locate(userOverride: nil)
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("SwiftResticReadAhead-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            root = base.resolvingSymlinksInPath()
            calls = root.appendingPathComponent("restic-calls.log")
            let wrapper = root.appendingPathComponent("restic")
            try "#!/bin/sh\necho \"$*\" >> '\(calls.path)'\nexec '\(binary.url.path)' \"$@\"\n"
                .write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

            let data = root.appendingPathComponent("Data")
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            var repository = Repository()
            repository.kind = .local
            repository.localPath = root.appendingPathComponent("repo").path
            let password = "read-ahead-test"
            let service = ResticService(runner: ResticRunner(), binary: binary.url)
            let context = RepositoryContext(repository: repository, password: password)
            _ = try await service.initializeRepository(context)
            var plan = BackupPlan()
            plan.repositoryID = repository.id
            plan.path = data.path
            plan.excludePatterns = []
            plan.schedule.frequency = .manual
            for round in 0 ..< 3 {
                try "a".write(to: data.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
                try String(repeating: "b", count: round + 1).write(to: data.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
                try (round == 2 ? "cc" : "c").write(to: data.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
                try (round >= 1 ? "bracket 2" : "bracket").write(to: data.appendingPathComponent("a[1].txt"), atomically: true, encoding: .utf8)
                _ = try await service.backup(context, plan: plan)
            }

            var configuration = AppConfiguration()
            configuration.repositories = [repository]
            configuration.plans = [plan]
            configuration.settings.resticPathOverride = wrapper.path
            let store = ConfigStore(directory: root.appendingPathComponent("config"))
            try await store.save(configuration)
            model = AppModel(store: store, secrets: .inMemory([repository.id: (password: password, providerSecret: nil)]))
            repositoryID = repository.id
            await model.bootstrap()
            let deadline = Date.now.addingTimeInterval(60)
            while !(await model.indexIsComplete(repositoryID: repository.id)), Date.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(await model.indexIsComplete(repositoryID: repository.id), "the index never read the backups")
            let chain = try #require(model.snapshots(for: repository.id).first.map(SnapshotIndex.chainKey(for:)))
            files = ["a.txt", "b.txt", "c.txt", "a[1].txt"].map {
                FileNode(repositoryID: repository.id, chainKey: chain, path: data.appendingPathComponent($0).path, isDirectory: false)
            }
        }

        /// The finds restic was asked for, as the wrapper logged them.
        func finds() -> [String] {
            let log = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
            return log.split(separator: "\n").map(String.init).filter { $0.hasPrefix("find ") }
        }

        /// Each file's versions' newest backups, from the index.
        func newest() async throws -> [FileNode: [String]] {
            var newest: [FileNode: [String]] = [:]
            for file in files {
                newest[file] = try await model.indexedContentVersions(
                    ofPath: file.path, inChain: file.chainKey, repositoryID: repositoryID
                ).compactMap { $0.snapshots.first?.id }
            }
            return newest
        }
    }

    @MainActor
    @Test("an open folder's files are read ahead in one find naming what they lack; every click is then answered with no restic")
    func folderReadAheadAnswersEveryFile() async throws {
        let scene = try await ReadAheadScene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let model = scene.model
        let files = scene.files
        let newest = try await scene.newest()
        #expect(newest.mapValues(\.count) == [files[0]: 1, files[1]: 3, files[2]: 2, files[3]: 2])
        #expect(scene.finds().isEmpty)

        // Two read-aheads of the folder at once, as a level read again while
        // the first runs: one find between them.
        let first = model.warmFileHistory(files)
        let second = model.warmFileHistory(files)
        await first.value
        await second.value
        let warmFinds = scene.finds()
        #expect(warmFinds.count == 1, "\(warmFinds)")
        let find = try #require(warmFinds.first)
        // Every file by its own path, the brackets escaped; every backup a
        // row lacks named, and no other.
        #expect(files.allSatisfy { find.contains(ResticService.globEscaped($0.path)) }, "\(find)")
        let named = Set(newest.values.joined())
        #expect(named.allSatisfy { find.contains("--snapshot \($0)") }, "\(find)")
        #expect(find.components(separatedBy: "--snapshot ").count - 1 == named.count, "\(find)")
        // Only the rows a click asks are kept: a.txt matched in every backup
        // named, but its one version needs only the newest.
        #expect(model.fileHistoryAnswers.keys.filter { $0.path == files[0].pathKey }.count == 1)

        // Each file's click: every row answered, sizes as backed up, no find.
        for file in files {
            let ids = try #require(newest[file])
            let answers = try await model.fileHistory(repositoryID: scene.repositoryID, path: file.path, backupIDs: ids)
            #expect(Set(answers.keys) == Set(ids), "\(file.name)")
            #expect(answers.values.allSatisfy { $0.size != nil && $0.mtime != nil }, "\(file.name)")
        }
        let bSizes = try #require(newest[files[1]]).compactMap { model.fileHistoryAnswers[FileHistoryKey(
            repositoryID: scene.repositoryID, backupID: $0, path: files[1].pathKey
        )]?.size }
        #expect(bSizes == [3, 2, 1])
        #expect(scene.finds().count == 1)

        await model.shutdown()
    }

    @MainActor
    @Test("a repository removed while its folder's read-ahead runs gets none of the answers back")
    func readAheadOutlivedByItsRepository() async throws {
        let scene = try await ReadAheadScene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let model = scene.model

        let readAhead = model.warmFileHistory(scene.files)
        // The find has started once its files are registered; restic then
        // derives its key for half a second before it answers.
        let deadline = ContinuousClock.now + .seconds(30)
        while model.fileHistoryReadAheads.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!model.fileHistoryReadAheads.isEmpty, "the read-ahead never started its find")
        model.deleteRepository(id: scene.repositoryID)
        await readAhead.value

        #expect(scene.finds().count == 1)
        #expect(model.fileHistoryAnswers.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("a repository removed while one file's find runs gets none of its answers back")
    func fileHistoryOutlivedByItsRepository() async throws {
        let scene = try await ReadAheadScene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let model = scene.model
        let file = scene.files[1]
        let ids = try #require(try await scene.newest()[file])

        let asking = Task { try await model.fileHistory(repositoryID: scene.repositoryID, path: file.path, backupIDs: ids) }
        // The wrapper logs the find as it starts; restic then derives its
        // key before it answers.
        let deadline = ContinuousClock.now + .seconds(30)
        while scene.finds().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!scene.finds().isEmpty, "the click never started its find")
        model.deleteRepository(id: scene.repositoryID)
        _ = try? await asking.value

        #expect(model.fileHistoryAnswers.isEmpty)
        await model.shutdown()
    }

    /// Find Files' restic engine — what runs while the index still reads,
    /// and what a Files tab's "Search All Backups…" hands a bare word to.
    @MainActor
    @Test("Find Files' restic search finds a bare word inside names, and a pattern as typed")
    func findFilesBareWord() async throws {
        let scene = try await ReadAheadScene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let model = scene.model

        func names(_ pattern: String) async throws -> Set<String> {
            let found = try await model.findFiles(repositoryID: scene.repositoryID, pattern: pattern, latestOnly: false)
            return Set(found.flatMap(\.matches).map(\.name))
        }
        // restic matches a pattern against whole names: "b.tx" alone named
        // nothing, so a word without a glob character is looked for inside.
        #expect(try await names("b.tx") == ["b.txt"])
        #expect(try await names("C.*") == ["c.txt"])
        await model.shutdown()
    }
}
