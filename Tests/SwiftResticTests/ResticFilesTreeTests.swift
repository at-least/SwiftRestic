import Foundation
import Testing

@Suite("restic file history and index search", .serialized)
struct ResticFilesTreeTests {
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
            let binary = try PinnedRestic.binary()
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
            let service = try PinnedRestic.service()
            let context = RepositoryContext(repository: repository, password: password)
            _ = try await service.initializeRepository(context)
            var plan = BackupPlan()
            plan.repositoryID = repository.id
            plan.path = data.path
            plan.skipNothing()
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
            let store = ConfigStore(directory: root.appendingPathComponent("config"))
            try await store.save(configuration)
            model = AppModel(store: store, secrets: .inMemory([repository.id: (password: password, providerSecret: nil)]), resticExecutable: wrapper)
            repositoryID = repository.id
            // A local, not the property: `files` is not set yet, so a closure
            // over the property would capture self half-initialized.
            let model = self.model
            await model.bootstrap()
            #expect(
                await eventually(within: 60) { (try? await model.indexIsComplete(repositoryID: repository.id)) == true },
                "the index never read the backups"
            )
            let chain = try #require(model.snapshots(for: repository.id).first.map(SnapshotIndex.chainKey(for:)))
            files = ["a.txt", "b.txt", "c.txt", "a[1].txt"].map {
                FileNode(repositoryID: repository.id, chainKey: chain, path: data.appendingPathComponent($0).path, isDirectory: false)
            }
        }

        func finds() -> [String] {
            let log = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
            return log.split(separator: "\n").map(String.init).filter { $0.hasPrefix("find ") }
        }

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
        // The patterns follow "--": a pattern starting with "-" is a
        // pattern to restic, not a flag.
        let patternsStart = try #require(find.range(of: " -- "), "\(find)")
        #expect(files.allSatisfy { find[patternsStart.upperBound...].contains(ResticService.globEscaped($0.path)) }, "\(find)")
        #expect(!find[..<patternsStart.lowerBound].contains(ResticService.globEscaped(files[0].path)), "\(find)")
        let named = Set(newest.values.joined())
        #expect(named.allSatisfy { find.contains("--snapshot \($0)") }, "\(find)")
        #expect(find.components(separatedBy: "--snapshot ").count - 1 == named.count, "\(find)")
        // Only the rows a click asks are kept: a.txt matched in every backup
        // named, but its one version needs only the newest.
        #expect(model.fileHistoryAnswers.keys.filter { $0.path == files[0].pathKey }.count == 1)

        for file in files {
            let ids = try #require(newest[file])
            let answers = try await model.fileHistory(repositoryID: scene.repositoryID, path: file.path, snapshotIDs: ids)
            #expect(Set(answers.keys) == Set(ids), "\(file.name)")
            #expect(answers.values.allSatisfy { $0.size != nil && $0.mtime != nil }, "\(file.name)")
        }
        let bSizes = try #require(newest[files[1]]).compactMap { model.fileHistoryAnswers[FileHistoryKey(
            repositoryID: scene.repositoryID, snapshotID: $0, path: files[1].pathKey
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
        #expect(
            await eventually(within: 30) { !model.fileHistoryReadAheads.isEmpty },
            "the read-ahead never started its find"
        )
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

        let asking = Task { try await model.fileHistory(repositoryID: scene.repositoryID, path: file.path, snapshotIDs: ids) }
        // The wrapper logs the find as it starts; restic then derives its
        // key before it answers.
        #expect(
            await eventually(within: 30) { !scene.finds().isEmpty },
            "the click never started its find"
        )
        model.deleteRepository(id: scene.repositoryID)
        _ = try? await asking.value

        #expect(model.fileHistoryAnswers.isEmpty)
        await model.shutdown()
    }

    /// The index searches' cap, over the index the app builds: a full page
    /// of hits is the whole answer, one hit past the cap says it was cut —
    /// the model's probe of asking one hit past the limit, for a plan's
    /// search and Search All Backups. The ceiling itself is pinned
    /// store-side (`SnapshotIndexScaleTests.search`).
    @MainActor
    @Test("an index search's full page is not called cut short; one hit past the cap is")
    func searchTruncationAtTheCap() async throws {
        try PinnedRestic.binary()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticSearchCap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }

        var repository = Repository()
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        let password = "search-cap-test"
        _ = try await PinnedRestic.service().initializeRepository(RepositoryContext(repository: repository, password: password))

        // Two plans of one repository: one a full page of notes, one a page
        // and one more. Finder files kept out, so the counts are the writes.
        func plan(folder named: String, files: Int) throws -> BackupPlan {
            let folder = root.appendingPathComponent(named)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 1 ... files {
                try "x".write(to: folder.appendingPathComponent(String(format: "note%03d", index)), atomically: true, encoding: .utf8)
            }
            var plan = BackupPlan()
            plan.repositoryID = repository.id
            plan.path = folder.path
            plan.skipNothing()
            plan.schedule.frequency = .manual
            return plan
        }
        let full = try plan(folder: "Full", files: AppModel.indexSearchLimit)
        let over = try plan(folder: "Over", files: AppModel.indexSearchLimit + 1)

        var configuration = AppConfiguration()
        configuration.repositories = [repository]
        configuration.plans = [full, over]
        let store = ConfigStore(directory: root.appendingPathComponent("config"))
        try await store.save(configuration)
        let model = AppModel(store: store, secrets: .inMemory([repository.id: (password: password, providerSecret: nil)]), resticExecutable: try PinnedRestic.binary().url)
        await model.bootstrap()
        await model.tasks.drain()

        for plan in [full, over] {
            model.runBackup(planID: plan.id)
            await model.waitForRun(planID: plan.id)
            // The backup's closing refresh lands through the background lane
            // and the backfill with it.
            try #require(
                await eventually(within: 60) { (try? await model.indexIsComplete(repositoryID: repository.id)) == true },
                "the index never read \(plan.path)'s backup"
            )
            let found = try await model.searchIndex(
                pattern: "note", inChain: ResticService.planTag(plan.id), repositoryID: repository.id
            )
            #expect(found.hits.count == AppModel.indexSearchLimit, "\(plan.path) returned \(found.hits.count) hits")
            #expect(found.isTruncated == (plan.id == over.id), "\(plan.path) read as truncated \(found.isTruncated)")

            // The repository-wide searches hold every plan backed up so far:
            // Full's page alone, then Full's notes and Over's together.
            let summaries = try await model.searchIndexWithSummaries(pattern: "note", repositoryID: repository.id)
            #expect(summaries.hits.count == AppModel.indexSearchLimit)
            #expect(summaries.isTruncated == (plan.id == over.id), "Search All Backups read as truncated \(summaries.isTruncated) after \(plan.path)")
        }
        await model.shutdown()
    }
}
