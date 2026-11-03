import Foundation
import Testing

@Suite("restic plan offers", .serialized, .enabled(if: ResticAvailability.isInstalled))
@MainActor
struct ResticPlanIndexOffersTests {
    private struct Scene {
        var root: URL
        var data: URL
        var model: AppModel
        var repository: Repository
        var plan: BackupPlan
    }

    private func makeScene() async throws -> Scene {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticPlanOffers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()
        let data = root.appendingPathComponent("Projects")
        for folder in ["app/build", "go/vendor/x", "notes"] {
            try FileManager.default.createDirectory(at: data.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for (file, text) in [("app/build.gradle", "plugins {}"), ("app/build/out.bin", "built"), ("go/go.mod", "module x"),
                             ("go/vendor/x/x.go", "package x"), ("notes/todo.txt", "hi")] {
            try text.write(to: data.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }

        var repository = Repository()
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        let password = "plan-offers-test"
        _ = try await ResticAvailability.service().initializeRepository(RepositoryContext(repository: repository, password: password))
        var plan = BackupPlan()
        plan.repositoryID = repository.id
        plan.path = data.path
        plan.skipNothing()
        plan.schedule.frequency = .manual

        var configuration = AppConfiguration()
        configuration.repositories = [repository]
        configuration.plans = [plan]
        configuration.settings.resticPathOverride = try ResticAvailability.binary().url.path
        let store = ConfigStore(directory: root.appendingPathComponent("config"))
        try await store.save(configuration)
        let model = AppModel(store: store, secrets: .inMemory([repository.id: (password: password, providerSecret: nil)]))
        await model.bootstrap()
        await model.tasks.drain()
        return Scene(root: root, data: data, model: model, repository: repository, plan: plan)
    }

    /// The backfill runs in the index coordinator, past what the model's
    /// task registry awaits: the suite's own wait, by deadline.
    private func waitForTheIndex(_ scene: Scene) async {
        await scene.model.tasks.drain()
        #expect(
            await eventually(within: 60) { await scene.model.indexIsComplete(repositoryID: scene.repository.id) },
            "the index never finished"
        )
    }

    private func path(_ scene: Scene, _ relative: String) -> String {
        scene.data.appendingPathComponent(relative).path
    }

    @Test("the offers read nothing while the index has not read the backup, then catch up and stop reading once it has")
    func offersCatchUpWithTheIndex() async throws {
        let scene = try await makeScene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let model = scene.model

        // A backup the listing holds and the index has not taken: the moment
        // between a refresh's listing and its reconcile.
        let service = try ResticAvailability.service()
        let context = try await model.context(for: scene.repository)
        _ = try await service.backup(context, plan: scene.plan)
        let listing = try await service.snapshots(context, planID: nil, timeout: 60)
        let generation = model.nextListingGeneration()
        model.snapshots[scene.repository.id] = listing
        model.snapshotsGeneration[scene.repository.id] = generation
        let early = await PlanIndexOffers.read(planID: scene.plan.id, model: model)
        #expect(!early.isIndexComplete)
        #expect(early.rebuildable.isEmpty)

        var rounds: [PlanIndexOffers] = []
        let reading = Task { @MainActor in
            await PlanIndexOffers.keepReading(planID: scene.plan.id, model: model, interval: .milliseconds(50)) { rounds.append($0) }
        }
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            reading.cancel()
        }
        model.indexReconcile(repositoryID: scene.repository.id, listing: listing, generation: generation)
        await model.tasks.drain()
        await reading.value
        timeout.cancel()

        let last = try #require(rounds.last)
        #expect(last.isIndexComplete, "the reading stopped before the index finished: \(rounds.count) rounds")
        #expect(last.rebuildable.map(\.path) == [path(scene, "app/build"), path(scene, "go/vendor")])
        #expect(last.rebuildable.map(\.rule.manifest) == ["build.gradle", "go.mod"])
        #expect(last.inEarlierBackups.isEmpty)
        #expect(last.rebuildableFailure == nil && last.inEarlierBackupsFailure == nil)
        #expect(rounds.dropLast().allSatisfy { !$0.isIndexComplete })
        await model.shutdown()
    }

    @Test("Exclude moves a folder from the offer to the earlier backups, and Remove from Earlier Backups takes it out of them, the backup keeping its run")
    func excludeThenRemove() async throws {
        let scene = try await makeScene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let model = scene.model
        let planID = scene.plan.id
        model.runBackup(planID: planID)
        await model.waitForRun(planID: planID)
        await waitForTheIndex(scene)
        let backupRun = try #require(model.configuration.runs.first { $0.kind == .backup })
        let firstSnapshot = try #require(backupRun.snapshotID)

        model.exclude(paths: [path(scene, "app/build")], fromPlan: planID)
        let excluded = await PlanIndexOffers.read(planID: planID, model: model)
        #expect(excluded.isIndexComplete)
        #expect(excluded.rebuildable.map(\.path) == [path(scene, "go/vendor")])
        #expect(excluded.inEarlierBackups.map(\.excluded.path) == [path(scene, "app/build")])
        #expect(excluded.inEarlierBackups.first?.backups.map(\.id) == [firstSnapshot])

        model.removeFromEarlierBackups(planID: planID, items: excluded.inEarlierBackups.map(\.excluded))
        #expect(model.activity[planID]?.phase == .removingFromEarlierBackups)
        await model.waitForRun(planID: planID)
        let removal = try #require(model.configuration.runs.first)
        #expect(removal.kind == .rewrite)
        #expect(removal.outcome == .succeeded, "\(removal.failureMessage ?? "")")
        #expect(removal.detailText == "Removed 1 item from 1 backup. The space is freed at the next cleanup.")

        // The closing refresh lists the rewritten backup and the index reads it.
        await waitForTheIndex(scene)
        let after = await PlanIndexOffers.read(planID: planID, model: model)
        #expect(after.isIndexComplete)
        #expect(after.inEarlierBackups.isEmpty)
        let rewritten = try #require(model.snapshots(for: scene.repository.id, planID: planID).first)
        #expect(rewritten.id != firstSnapshot)
        #expect(rewritten.original == firstSnapshot)
        #expect(model.backupRun(forSnapshot: rewritten.id)?.id == backupRun.id)
        await model.shutdown()
    }

    @Test("a failing index fails both reads in their own places, never as nothing found")
    func failingIndexSaysSo() async throws {
        let scene = try await makeScene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        // The repository stays; its index is dropped, so every read throws.
        await scene.model.indexCoordinator.dropRepository(repositoryID: scene.repository.id)
        var plan = scene.plan
        plan.excludePatterns = [path(scene, "app/build")]
        scene.model.upsert(plan: plan)

        let offers = await PlanIndexOffers.read(planID: scene.plan.id, model: scene.model)
        #expect(offers.rebuildableFailure != nil)
        #expect(offers.inEarlierBackupsFailure != nil)
        #expect(offers.rebuildable.isEmpty && offers.inEarlierBackups.isEmpty)
        await scene.model.shutdown()
    }
}
