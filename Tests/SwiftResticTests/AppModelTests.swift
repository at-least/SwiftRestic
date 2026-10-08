import Foundation
import Testing
import UniformTypeIdentifiers

/// Exercises the glue between the scheduler, `ResticService` and the stored run
/// history — the layer where a real backup can succeed while the app still
/// records it wrongly.
@Suite("AppModel backup flow", .serialized, .enabled(if: ResticAvailability.isInstalled))
@MainActor
struct AppModelTests {
    private struct Harness {
        var model: AppModel
        var root: URL
        var repository: Repository
        var plan: BackupPlan
        var sourceDirectory: URL
        /// Set only in stub mode; its sleep marker is how a test waits for a
        /// hang to actually establish instead of betting on a fixed delay.
        var stub: StubRestic?
    }

    /// Builds a ready-to-use repository *before* the model exists.
    ///
    /// `bootstrap()` starts the scheduler, so anything a due plan needs has to be
    /// in place first — otherwise the scheduler's own first tick races the test.
    /// Tests that are not about scheduling use `.manual` so only they decide when
    /// a backup happens.
    private func makeHarness(
        retention: RetentionPolicy = RetentionPolicy(),
        frequency: Schedule.Frequency = .manual,
        stubMode: String? = nil
    ) async throws -> Harness {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticApp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()

        let sourceDirectory = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "one".write(to: sourceDirectory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two".write(to: sourceDirectory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        var repository = Repository()
        repository.name = "Test Repo"
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        // In stub mode the model runs a fake restic whose `backup` hangs until
        // killed, reached through the same override the Settings screen uses —
        // timing tests become deterministic instead of betting on restic's
        // speed against a fixed sleep.
        var stub: StubRestic?
        if let stubMode {
            stub = try StubRestic.install(in: root)
            repository.extraEnvironment = ["SWIFTRESTIC_STUB": stubMode]
        }

        var plan = BackupPlan()
        plan.name = "Test Plan"
        plan.repositoryID = repository.id
        plan.sources = [sourceDirectory.path]
        plan.excludePatterns = []
        plan.schedule.frequency = frequency
        plan.schedule.intervalHours = 1
        plan.retention = retention

        var configuration = AppConfiguration()
        configuration.repositories = [repository]
        configuration.plans = [plan]
        if let stub {
            configuration.settings.resticPathOverride = stub.url.path
        }

        let storeDirectory = root.appendingPathComponent("config")
        let store = ConfigStore(directory: storeDirectory)
        try await store.save(configuration)

        if stub == nil {
            let binary = try ResticBinary.locate(userOverride: nil)
            _ = try await ResticService(runner: ResticRunner(), binary: binary.url)
                .initializeRepository(RepositoryContext(repository: repository, password: "test-password"))
        }

        let model = AppModel(
            store: store,
            secrets: .inMemory([repository.id: (password: "test-password", providerSecret: nil)])
        )
        await model.bootstrap()

        return Harness(
            model: model,
            root: root,
            repository: repository,
            plan: plan,
            sourceDirectory: sourceDirectory,
            stub: stub
        )
    }

    @Test("a successful run updates the plan, the history and the snapshot list")
    func successfulBackup() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.outcome == .succeeded)
        #expect(record.kind == .backup)
        #expect(record.snapshotID != nil)
        #expect(record.filesNew == 2)
        #expect(record.failureMessage == nil)

        // The sidebar reads these; a run that produced a snapshot must never
        // leave the plan looking like it has never succeeded.
        let plan = try #require(model.plan(id: harness.plan.id))
        #expect(plan.lastSuccessAt != nil)
        #expect(plan.lastRunAt != nil)

        #expect(model.snapshots(for: harness.repository.id, planID: harness.plan.id).count == 1)
        #expect(model.activity.isEmpty)

        await model.shutdown()
    }

    @Test("a drag restore lands the node in a throwaway directory the drop can read")
    func dragRestoreRestoresNode() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let snapshot = try #require(
            model.snapshots(for: harness.repository.id, planID: harness.plan.id).first
        )

        let node = SnapshotNode(
            name: "a.txt",
            type: .file,
            path: harness.sourceDirectory.appendingPathComponent("a.txt").path
        )
        // The drag path's contract: everything it needs arrives as captured
        // values, because the real caller cannot touch the model once the
        // drag session holds the main thread.
        let url = try await AppModel.restoredFileForDrag(
            service: try model.service(),
            secrets: model.secrets,
            repository: harness.repository,
            settings: model.configuration.settings,
            snapshotID: snapshot.id,
            node: node
        )

        #expect(url.lastPathComponent == "a.txt")
        #expect(url.deletingLastPathComponent().lastPathComponent.hasPrefix(AppModel.dragRestorePrefix))
        #expect(try String(contentsOf: url, encoding: .utf8) == "one")

        // A drag restore is not a UI restore: it borrows neither the progress
        // strip nor the run history.
        #expect(model.restoreActivity == nil)
        #expect(model.configuration.runs.allSatisfy { $0.kind == .backup })

        await model.shutdown()
    }

    @Test("an item named by its path is restored from the node restic lists for it, and a path the backup lacks says so")
    func listedNodeByPath() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let snapshot = try #require(model.snapshots(for: harness.repository.id, planID: harness.plan.id).first)

        let file = try await model.listedNode(
            repositoryID: harness.repository.id, snapshotID: snapshot.id,
            path: harness.sourceDirectory.appendingPathComponent("a.txt").path
        )
        #expect(file.name == "a.txt")
        #expect(!file.isDirectory)
        let folder = try await model.listedNode(
            repositoryID: harness.repository.id, snapshotID: snapshot.id, path: harness.sourceDirectory.path
        )
        #expect(folder.isDirectory)
        await #expect(throws: ResticError.commandFailed(
            exitCode: 0, message: "“gone.txt” is no longer listed in the chosen snapshot — refresh and try again."
        )) {
            try await model.listedNode(
                repositoryID: harness.repository.id, snapshotID: snapshot.id,
                path: harness.sourceDirectory.appendingPathComponent("gone.txt").path
            )
        }

        await model.shutdown()
    }

    @Test("items from several backups restore in one run, each from its own backup, each step's record naming it")
    func restoreFromSeveralBackups() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let a = harness.sourceDirectory.appendingPathComponent("a.txt")

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        try "uno".write(to: a, atomically: true, encoding: .utf8)
        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let backups = model.snapshots(for: harness.repository.id, planID: harness.plan.id).sorted { $0.time < $1.time }
        try #require(backups.count == 2)

        let first = harness.root.appendingPathComponent("from-first")
        let second = harness.root.appendingPathComponent("from-second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let node = try await model.listedNode(repositoryID: harness.repository.id, snapshotID: backups[0].id, path: a.path)
        model.restore(
            repositoryID: harness.repository.id,
            items: [
                (snapshotID: backups[0].id, node: node, directory: first),
                (snapshotID: backups[1].id, node: node, directory: second),
            ],
            overwrite: .keepExisting
        )
        let deadline = Date.now.addingTimeInterval(60)
        while model.isRestoring, Date.now < deadline { try await Task.sleep(for: .milliseconds(50)) }

        #expect(try String(contentsOf: first.appendingPathComponent("a.txt"), encoding: .utf8) == "one")
        #expect(try String(contentsOf: second.appendingPathComponent("a.txt"), encoding: .utf8) == "uno")
        let restores = model.configuration.runs.filter { $0.kind == .restore }
        #expect(restores.count == 2)
        #expect(Set(restores.compactMap(\.snapshotID)) == Set(backups.map(\.id)))
        #expect(restores.allSatisfy { $0.outcome == .succeeded })

        await model.shutdown()
    }

    @Test("a folder and a file deleted from it since, picked from two backups, both come back: the folder as its backup holds it, the file beside it or back inside it")
    func restoreFolderWithAFileItsBackupNoLongerHolds() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let id = harness.repository.id
        let source = harness.sourceDirectory
        let b = source.appendingPathComponent("b.txt")

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        try FileManager.default.removeItem(at: b)
        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let backups = model.snapshots(for: id, planID: harness.plan.id).sorted { $0.time < $1.time }
        try #require(backups.count == 2)

        // Find Files' rows: the folder at the newer backup, the deleted file
        // at the older, the newest that holds it.
        let rows = [
            (snapshotID: backups[1].id, node: try await model.listedNode(repositoryID: id, snapshotID: backups[1].id, path: source.path)),
            (snapshotID: backups[0].id, node: try await model.listedNode(repositoryID: id, snapshotID: backups[0].id, path: b.path)),
        ]
        let (kept, covered) = RestoreBatch.covering(rows, node: { $0.node }, backup: { $0.snapshotID })
        #expect(kept.count == 2)
        #expect(covered.isEmpty)

        func restore(into directories: [URL]) async throws {
            model.restore(
                repositoryID: id,
                items: zip(kept, directories).map { (snapshotID: $0.snapshotID, node: $0.node, directory: $1) },
                overwrite: .keepExisting
            )
            let deadline = Date.now.addingTimeInterval(60)
            while model.isRestoring, Date.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        }

        // One chosen folder: the folder exactly as the newer backup holds it,
        // the file beside it.
        let chosen = harness.root.appendingPathComponent("chosen")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try await restore(into: [chosen, chosen])
        let folder = chosen.appendingPathComponent(source.lastPathComponent)
        #expect(try String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8) == "one")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("b.txt").path))
        #expect(try String(contentsOf: chosen.appendingPathComponent("b.txt"), encoding: .utf8) == "two")

        // Original locations, each item into its own parent: the file is back
        // inside the folder.
        try await restore(into: [source.deletingLastPathComponent(), source])
        #expect(try String(contentsOf: b, encoding: .utf8) == "two")
        #expect(try String(contentsOf: source.appendingPathComponent("a.txt"), encoding: .utf8) == "one")
        #expect(model.configuration.runs.filter { $0.kind == .restore }.allSatisfy { $0.outcome == .succeeded })

        await model.shutdown()
    }

    @Test("a console command that can change the backups re-reads the listing; one that only reads does not")
    func consoleRefreshesAfterAMutatingCommand() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let id = harness.repository.id

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        try "uno".write(to: harness.sourceDirectory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        await model.tasks.drain()
        #expect(model.snapshots(for: id).count == 2)

        // Reading commands leave the listing alone.
        _ = await model.runConsoleCommand(repositoryID: id, arguments: ["snapshots"])
        await model.tasks.drain()
        #expect(model.snapshots(for: id).count == 2)

        // restic forgets one; the app's lists follow without a manual refresh.
        _ = await model.runConsoleCommand(repositoryID: id, arguments: ["forget", "--keep-last", "1"])
        await model.tasks.drain()
        #expect(model.snapshots(for: id).count == 1)

        await model.shutdown()
    }

    @Test("the Restore pane's drag provider promises a file's or a folder's content, restored on demand")
    func dragProviderPromisesContent() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let snapshot = try #require(
            model.snapshots(for: harness.repository.id, planID: harness.plan.id).first
        )

        // A file is promised as data — never as a file URL, which Finder
        // refuses — and named after the node.
        let file = SnapshotNode(
            name: "a.txt",
            type: .file,
            path: harness.sourceDirectory.appendingPathComponent("a.txt").path
        )
        let fileProvider = model.dragRestoreProvider(
            repositoryID: harness.repository.id, snapshotID: snapshot.id, node: file
        )
        #expect(fileProvider.registeredTypeIdentifiers == [UTType.data.identifier])
        #expect(fileProvider.suggestedName == "a.txt")
        let fileLoad = await Self.load(fileProvider, type: .data)
        #expect(fileLoad.error == nil)
        #expect(fileLoad.contents == ["<file> one"])

        // A folder — here a snapshot root, the shape the pane's top rows
        // have — is promised as a folder and arrives whole.
        let folder = SnapshotNode(name: "source", type: .dir, path: harness.sourceDirectory.path)
        let folderProvider = model.dragRestoreProvider(
            repositoryID: harness.repository.id, snapshotID: snapshot.id, node: folder
        )
        #expect(folderProvider.registeredTypeIdentifiers == [UTType.folder.identifier])
        #expect(folderProvider.suggestedName == "source")
        let folderLoad = await Self.load(folderProvider, type: .folder)
        #expect(folderLoad.error == nil)
        #expect(folderLoad.contents == ["a.txt", "b.txt"])

        // A drag restore is not a UI restore: it borrows neither the progress
        // strip nor the run history, and a drop that landed posts no banner.
        #expect(model.restoreActivity == nil)
        #expect(model.configuration.runs.allSatisfy { $0.kind == .backup })
        #expect(!model.banners.contains { $0.title == "Drag restore failed" })

        await model.shutdown()
    }

    /// Loads a promise in-process, the way a drop site would, and reads the
    /// copy inside the completion — the system deletes it when the handler
    /// returns. A file reads as `<file> <contents>`; a folder as its sorted
    /// relative paths.
    private static func load(
        _ provider: NSItemProvider,
        type: UTType
    ) async -> (contents: [String], error: String?) {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(returning: ([], error.map { "\($0)" } ?? "no URL"))
                    return
                }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                    continuation.resume(returning: ([], "nothing at \(url.path)"))
                    return
                }
                if isDirectory.boolValue {
                    let entries = (FileManager.default.enumerator(atPath: url.path)?.allObjects as? [String]) ?? []
                    continuation.resume(returning: (entries.sorted(), nil))
                } else {
                    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    continuation.resume(returning: (["<file> \(text)"], nil))
                }
            }
        }
    }

    @Test("a preview dumps one version into its own temporary folder, and nothing is left once it closes or fails")
    func previewCopy() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let snapshot = try #require(
            model.snapshots(for: harness.repository.id, planID: harness.plan.id).first
        )
        func previewFolders() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
                .filter { $0.hasPrefix(AppModel.previewPrefix) })
        }
        let before = try previewFolders()

        let node = SnapshotNode(
            name: "a.txt",
            type: .file,
            path: harness.sourceDirectory.appendingPathComponent("a.txt").path
        )
        let url = try await model.previewCopy(repositoryID: harness.repository.id, snapshotID: snapshot.id, node: node)
        // The file keeps its own name, so it opens as what it is.
        #expect(url.lastPathComponent == "a.txt")
        let folder = url.deletingLastPathComponent()
        #expect(folder.lastPathComponent.hasPrefix(AppModel.previewPrefix))
        #expect(try String(contentsOf: url, encoding: .utf8) == "one")
        // Quick Look offers to open the file in an app; edits saved there
        // would go with the copy, so the copy is read-only.
        #expect(!FileManager.default.isWritableFile(atPath: url.path))
        // A preview is not a restore: no progress strip, no run record.
        #expect(model.restoreActivity == nil)
        #expect(model.configuration.runs.allSatisfy { $0.kind == .backup })

        try AppModel.removePreviewCopy(url)
        #expect(!FileManager.default.fileExists(atPath: folder.path))

        // A dump that fails takes its folder with it.
        let missing = SnapshotNode(name: "gone.txt", type: .file, path: "/no/such/gone.txt")
        await #expect(throws: (any Error).self) {
            try await model.previewCopy(repositoryID: harness.repository.id, snapshotID: snapshot.id, node: missing)
        }
        #expect(try previewFolders() == before)

        await model.shutdown()
    }

    @Test("Change Password rotates the repository's key and the stored password together; a refused change stores nothing")
    func changePassword() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let id = harness.repository.id
        let service = try model.service()
        func opens(_ password: String) async throws -> Bool {
            do {
                return try await service.repositoryExists(RepositoryContext(repository: harness.repository, password: password), timeout: nil)
            } catch let ResticError.commandFailed(code, _) where code == 12 {
                return false
            }
        }
        // Opened once, so a cached context holds the old password.
        #expect(try await model.context(for: harness.repository).password == "test-password")

        try await model.changeRepositoryPassword(repositoryID: id, to: "new-password")
        #expect(try await model.secrets.load(id).password == "new-password")
        #expect(try await opens("new-password"))
        #expect(try await !opens("test-password"))
        // The cached context went with the old password.
        #expect(try await model.context(for: harness.repository).password == "new-password")

        // A stored password the repository does not take: restic refuses
        // (exit 12), and neither the key nor the stored password moves.
        try await model.secrets.save(id, "stale-password", nil)
        model.noteAuthFailure(ResticError.commandFailed(exitCode: 12, message: ""), repositoryID: id)
        await #expect(throws: ResticError.commandFailed(exitCode: 12, message: "Fatal: wrong password or no key found")) {
            try await model.changeRepositoryPassword(repositoryID: id, to: "third-password")
        }
        #expect(try await model.secrets.load(id).password == "stale-password")
        #expect(try await opens("new-password"))
        #expect(try await !opens("third-password"))

        await model.shutdown()
    }

    @Test("a backup whose every folder is missing is skipped, not failed: the slot is stamped and nothing calls it a problem")
    func everySourceMissingIsSkipped() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let index = try #require(model.configuration.plans.firstIndex { $0.id == harness.plan.id })
        model.configuration.plans[index].sources = ["/Volumes/SwiftRestic Test Drive/Documents"]

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.outcome == .skipped)
        #expect(record.detailText == "“SwiftRestic Test Drive” is not connected.")
        #expect(record.failureMessage == nil)
        #expect(record.snapshotID == nil)
        #expect(RunRecordPresentation.detail(for: record) == "“SwiftRestic Test Drive” is not connected.")
        let plan = try #require(model.plan(id: harness.plan.id))
        #expect(plan.lastRunAt != nil, "the slot is stamped, so the plan does not re-fire every tick")
        #expect(plan.lastSuccessAt == nil)
        #expect(model.currentProblem(for: harness.plan.id) == nil)

        // A folder that is simply gone, not on a volume.
        model.configuration.plans[index].sources = [harness.root.appendingPathComponent("gone").path]
        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        #expect(model.configuration.runs.first?.detailText == "None of its folders are on this Mac.")

        await model.shutdown()
    }

    @Test("a backup to a repository whose drive is away is skipped, not failed; one whose folder is gone from a drive that is here fails with the editor as its fix")
    func repositoryDriveAwayIsSkipped() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let index = try #require(model.configuration.repositories.firstIndex { $0.id == harness.repository.id })
        model.configuration.repositories[index].localPath = "/Volumes/SwiftRestic Absent Drive/restic"

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.outcome == .skipped)
        #expect(record.detailText == "“SwiftRestic Absent Drive” is not connected.")
        #expect(record.failureMessage == nil)
        #expect(record.exitCode == nil, "restic is never asked")
        let plan = try #require(model.plan(id: harness.plan.id))
        #expect(plan.lastRunAt != nil, "the slot is stamped, so the plan does not re-fire every tick")
        #expect(plan.lastSuccessAt == nil)
        #expect(model.currentProblem(for: harness.plan.id) == nil)

        // The drive is here and the folder is not: restic's exit 10 stays
        // a failure, and the repository's editor is where the path is fixed.
        model.configuration.repositories[index].localPath = harness.root.appendingPathComponent("moved").path
        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let failed = try #require(model.configuration.runs.first)
        #expect(failed.outcome == .failed)
        #expect(failed.exitCode == 10)
        #expect(RunRecordPresentation.fix(for: failed, repositoryExists: true, repositoryBusy: false)
            == .editRepositoryPath(harness.repository.id))

        await model.shutdown()
    }

    @Test("a repository whose drive is away reads its listing as the skip does, with no restic and no banner; a run and a mount, under a pause too, bring the words")
    func repositoryDriveAwayListing() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let id = harness.repository.id
        let rows = model.snapshots[id]
        let banners = model.banners.count
        let away = SnapshotListingOutcome.failed("“SwiftRestic Absent Drive” is not connected.")
        let index = try #require(model.configuration.repositories.firstIndex { $0.id == id })
        model.configuration.repositories[index].localPath = "/Volumes/SwiftRestic Absent Drive/restic"

        // Not restic's exit 10 ("Repository missing. …") with a red banner.
        await model.refreshSnapshots(repositoryID: id)
        #expect(model.snapshotListingOutcomes[id] == away)
        #expect(model.banners.count == banners)
        #expect(model.snapshots[id] == rows, "earlier rows stay, as for any failed read")

        // The run that finds the drive away says it on the listing at once.
        model.snapshotListingOutcomes[id] = .loaded
        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        #expect(model.snapshotListingOutcomes[id] == away)

        // A mount of its drive re-reads it while backups are paused; another
        // drive's leaves it alone. (The drive is still away here, so the
        // re-read answers the same words — what shows it ran.)
        model.pauseBackups(for: .untilResumed)
        model.snapshotListingOutcomes[id] = .loaded
        model.refreshRepositories(onVolume: "/Volumes/Some Other Drive")
        await model.tasks.drain()
        #expect(model.snapshotListingOutcomes[id] == .loaded)
        model.refreshRepositories(onVolume: "/Volumes/SwiftRestic Absent Drive")
        await model.tasks.drain()
        #expect(model.snapshotListingOutcomes[id] == away)

        await model.shutdown()
    }

    @Test("a Back Up Now that ends skipped is answered with a passing banner in the skip's words; the scheduler's skip stays quiet")
    func askedSkipIsAnswered() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let index = try #require(model.configuration.repositories.firstIndex { $0.id == harness.repository.id })
        model.configuration.repositories[index].localPath = "/Volumes/SwiftRestic Absent Drive/restic"
        model.banners.removeAll()

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let banner = try #require(model.banners.first)
        #expect(banner.title.hasSuffix("skipped"))
        #expect(banner.message == "“SwiftRestic Absent Drive” is not connected.")
        #expect(!banner.isError, "it goes by itself, like a success's")
        #expect(banner.symbolName == "minus.circle", "the skipped row's glyph, not a success's check")

        // The same skip at a scheduled slot posts nothing.
        model.banners.removeAll()
        let planIndex = try #require(model.configuration.plans.firstIndex { $0.id == harness.plan.id })
        model.configuration.plans[planIndex].schedule.frequency = .hourly
        model.configuration.plans[planIndex].lastRunAt = nil
        let runs = model.configuration.runs.count
        await model.runDuePlans()
        await model.waitForRun(planID: harness.plan.id)
        #expect(model.configuration.plans[planIndex].lastRunAt != nil, "the slot ran")
        #expect(model.configuration.runs.count == runs, "merged into the standing skip")
        #expect(model.banners.isEmpty)

        await model.shutdown()
    }

    @Test("a backup that skipped only folders on a drive that is away is skipped, its snapshot kept; a folder simply gone stays a warning")
    func someSourcesAwayIsSkipped() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let index = try #require(model.configuration.plans.firstIndex { $0.id == harness.plan.id })
        let source = try #require(harness.plan.sources.first)
        model.configuration.plans[index].sources = [source, "/Volumes/SwiftRestic Absent Drive/Photos"]

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.outcome == .skipped)
        #expect(record.snapshotID != nil, "the folders that are here were backed up")
        #expect(record.filesNew == 2)
        #expect(record.detailText == "“SwiftRestic Absent Drive” is not connected; the other folders were backed up.")
        #expect(record.itemErrorCount == 0)
        #expect(record.itemErrors.isEmpty)
        #expect(record.exitCode == 3)
        let plan = try #require(model.plan(id: harness.plan.id))
        #expect(plan.lastSuccessAt != nil)
        #expect(model.currentProblem(for: harness.plan.id) == nil)

        // A folder gone from the startup disk is not a drive away.
        model.configuration.plans[index].sources = [source, harness.root.appendingPathComponent("gone").path]
        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let warned = try #require(model.configuration.runs.first)
        #expect(warned.outcome == .completedWithErrors)
        #expect(warned.itemErrorCount == 1)

        await model.shutdown()
    }

    @Test("a drive away at every slot leaves one record that counts the runs, and the replaced run's log goes with it")
    func standingSkipIsOneRecord() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let index = try #require(model.configuration.plans.firstIndex { $0.id == harness.plan.id })
        model.configuration.plans[index].sources = ["/Volumes/SwiftRestic Test Drive/Documents"]

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let first = try #require(model.configuration.runs.first)
        #expect(await model.loadRunLog(first) != nil)
        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)

        let backups = model.configuration.runs.filter { $0.planID == harness.plan.id && $0.kind == .backup }
        #expect(backups.count == 1)
        let standing = try #require(backups.first)
        #expect(standing.id != first.id)
        #expect(standing.skipCount == 2)
        #expect(standing.skippedSince == first.startedAt)
        #expect(await model.loadRunLog(standing) != nil)
        await model.tasks.drain()
        #expect(await model.loadRunLog(first) == nil, "the replaced run's log leaves with it")

        await model.shutdown()
    }

    @Test("online-only cloud files are left out with restic's own flag when the plan asks for it")
    func excludeCloudFilesFlag() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let index = try #require(model.configuration.plans.firstIndex { $0.id == harness.plan.id })

        model.configuration.plans[index].excludeCloudFiles = true
        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let with = try #require(model.configuration.runs.first)
        #expect(with.outcome == .succeeded)
        #expect(model.runLogs.read(with.id)?.contains("--exclude-cloud-files") == true)

        model.configuration.plans[index].excludeCloudFiles = false
        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let without = try #require(model.configuration.runs.first)
        #expect(without.id != with.id)
        #expect(model.runLogs.read(without.id)?.contains("--exclude-cloud-files") == false)

        await model.shutdown()
    }

    @Test("the launch sweep removes old drag and preview staging and nothing else")
    func dragStagingSweep() throws {
        let temp = FileManager.default.temporaryDirectory
        let stale = temp.appendingPathComponent("\(AppModel.dragRestorePrefix)\(UUID().uuidString)")
        let file = temp.appendingPathComponent("\(AppModel.dragRestorePrefix)\(UUID().uuidString)")
        let preview = temp.appendingPathComponent("\(AppModel.previewPrefix)\(UUID().uuidString)")
        let unrelated = temp.appendingPathComponent("SwiftRestic-Keep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try "x".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: stale)
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: preview)
            try? FileManager.default.removeItem(at: unrelated)
        }

        AppModel.sweepDragRestoreStaging()

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: preview.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("retention runs after the backup and trims the plan's own snapshots")
    func retentionAfterBackup() async throws {
        var retention = RetentionPolicy()
        retention.keepLast = 1
        retention.keepHourly = 0
        retention.keepDaily = 0
        retention.keepWeekly = 0
        retention.keepMonthly = 0
        retention.keepYearly = 0
        let harness = try await makeHarness(retention: retention)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        for index in 0 ..< 3 {
            try "change \(index)".write(
                to: harness.sourceDirectory.appendingPathComponent("a.txt"),
                atomically: true,
                encoding: .utf8
            )
            model.runBackup(planID: harness.plan.id)
            await model.waitForRun(planID: harness.plan.id)
        }

        #expect(model.configuration.runs.count == 3)
        #expect(model.configuration.runs.allSatisfy { $0.outcome == .succeeded })
        #expect(model.snapshots(for: harness.repository.id, planID: harness.plan.id).count == 1)

        await model.shutdown()
    }

    @Test("a run against a missing repository is recorded as failed, not silently dropped")
    func failedBackupIsRecorded() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        // Delete the repository out from under the plan.
        try FileManager.default.removeItem(at: harness.root.appendingPathComponent("repo"))

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.outcome == .failed)
        #expect(record.failureMessage != nil)
        #expect(model.plan(id: harness.plan.id)?.lastSuccessAt == nil)
        #expect(model.plan(id: harness.plan.id)?.lastRunAt != nil)

        await model.shutdown()
    }

    @Test("an after-success hook runs and is told about the snapshot")
    func afterSuccessHookRuns() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        let markerPath = harness.root.appendingPathComponent("hook-output.txt").path
        var hook = BackupHook()
        hook.name = "record snapshot"
        hook.event = .afterSuccess
        hook.command = #"printf '%s %s' "$SWIFTRESTIC_OUTCOME" "$SWIFTRESTIC_SNAPSHOT_ID" > "\#(markerPath)""#

        var plan = harness.plan
        plan.hooks = [hook]
        model.upsert(plan: plan)

        model.runBackup(planID: plan.id)
        await model.waitForRun(planID: plan.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.outcome == .succeeded)
        let snapshotID = try #require(record.snapshotID)

        let written = try String(contentsOfFile: markerPath, encoding: .utf8)
        #expect(written == "succeeded \(snapshotID)")

        await model.shutdown()
    }

    @Test("a before-backup hook set to cancel stops the backup happening at all")
    func abortingHookPreventsBackup() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        var hook = BackupHook()
        hook.name = "gatekeeper"
        hook.event = .beforeBackup
        hook.command = "echo 'not today' >&2; exit 1"
        hook.failureBehaviour = .abortBackup

        var plan = harness.plan
        plan.hooks = [hook]
        model.upsert(plan: plan)

        model.runBackup(planID: plan.id)
        await model.waitForRun(planID: plan.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.outcome == .failed)
        #expect(record.snapshotID == nil)
        #expect(record.hookMessages.contains { $0.contains("gatekeeper") })
        // Hook output must not be filed as a restic warning: that is what gets
        // sent to external notification channels.
        #expect(record.itemErrors.isEmpty)
        // Nothing may have been written to the repository.
        #expect(model.snapshots(for: harness.repository.id, planID: plan.id).isEmpty)
        #expect(model.plan(id: plan.id)?.lastSuccessAt == nil)

        await model.shutdown()
    }

    @Test("a failing after-success hook is recorded but does not undo the backup")
    func failingAfterHookDoesNotFailTheRun() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        var hook = BackupHook()
        hook.name = "noisy"
        hook.event = .afterAny
        hook.command = "exit 9"

        var plan = harness.plan
        plan.hooks = [hook]
        model.upsert(plan: plan)

        model.runBackup(planID: plan.id)
        await model.waitForRun(planID: plan.id)

        let record = try #require(model.configuration.runs.first)
        // The snapshot exists, so the run is not a failure — but the hook's exit
        // code has to be visible somewhere.
        #expect(record.outcome != .failed)
        #expect(record.snapshotID != nil)
        #expect(record.hookMessages.contains { $0.contains("noisy") && $0.contains("exited 9") })
        #expect(record.itemErrors.isEmpty)
        #expect(model.plan(id: plan.id)?.lastSuccessAt != nil)

        await model.shutdown()
    }

    @Test("repository hooks run around a check and are told which task it was")
    func maintenanceHooksRun() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        let markerPath = harness.root.appendingPathComponent("check-hook.txt").path
        var hook = BackupHook()
        hook.name = "record check"
        hook.event = .afterMaintenanceSuccess
        hook.command = #"printf '%s %s %s' "$SWIFTRESTIC_TASK" "$SWIFTRESTIC_OUTCOME" "$SWIFTRESTIC_EVENT" > "\#(markerPath)""#

        var repository = harness.repository
        repository.hooks = [hook]
        await model.upsert(repository: repository, password: nil, providerSecret: nil)

        model.runMaintenance(repositoryID: repository.id, task: .check, readDataPercent: 0)
        await model.waitForMaintenance(repositoryID: repository.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.kind == .check)
        #expect(record.outcome == .succeeded)
        #expect(record.hookMessages.isEmpty)
        #expect(try String(contentsOfFile: markerPath, encoding: .utf8) == "check succeeded afterMaintenanceSuccess")

        await model.shutdown()
    }

    @Test("a before-maintenance hook set to cancel stops the check and still stamps the schedule")
    func abortingHookPreventsMaintenance() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        var gate = BackupHook()
        gate.name = "gatekeeper"
        gate.event = .beforeMaintenance
        gate.command = "echo 'disk is busy' >&2; exit 1"
        gate.failureBehaviour = .abortBackup

        let markerPath = harness.root.appendingPathComponent("failure-hook.txt").path
        var onFailure = BackupHook()
        onFailure.name = "report"
        onFailure.event = .afterMaintenanceFailure
        onFailure.command = #"printf '%s' "$SWIFTRESTIC_ERROR" > "\#(markerPath)""#

        var repository = harness.repository
        repository.hooks = [gate, onFailure]
        await model.upsert(repository: repository, password: nil, providerSecret: nil)

        model.runMaintenance(repositoryID: repository.id, task: .check, readDataPercent: 0)
        await model.waitForMaintenance(repositoryID: repository.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.outcome == .failed)
        #expect(record.hookMessages.contains { $0.contains("gatekeeper") && $0.contains("disk is busy") })
        #expect(record.itemErrors.isEmpty)
        // The after-failure hook still fires, with the reason.
        #expect(try String(contentsOfFile: markerPath, encoding: .utf8).contains("cancel the check"))
        // A hook that always refuses must not turn into a retry every minute.
        #expect(model.repository(id: repository.id)?.maintenance.lastCheckAt != nil)

        await model.shutdown()
    }

    @Test("quitting during a backup still gets the run onto disk, and records why it stopped")
    func shutdownPersistsInFlightRun() async throws {
        // hang-backup, not hang: after the run ends the model refreshes
        // snapshots and stats, and those must answer instead of burning their
        // 300 s refresh timeout.
        let harness = try await makeHarness(stubMode: "hang-backup")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        // The stub backup never finishes on its own, so once its hang shows up
        // in the process table the run is guaranteed still in flight when we
        // quit — no fixed delay to bet on.
        model.runBackup(planID: harness.plan.id)
        let stub = try #require(harness.stub)
        #expect(
            await StubRestic.waitForHang(matching: stub.sleepMarker, within: 10),
            "the stub never established its hang within 10 s"
        )

        // shutdown() cancels the run; the record is written while it unwinds, and
        // the debounced save would never fire if shutdown did not wait for it.
        await model.shutdown()

        let reloaded = try await ConfigStore(
            directory: harness.root.appendingPathComponent("config")
        ).load().configuration
        #expect(reloaded.runs.count == 1, "the in-flight run never reached disk")
        #expect(reloaded.runs.first?.outcome != .failed)
        // Nobody clicked cancel: the record must not send someone hunting for a
        // cancel click that never happened.
        #expect(reloaded.runs.first?.failureMessage == "Interrupted by quitting SwiftRestic")
        #expect(reloaded.plans.first?.lastRunAt != nil)
    }

    @Test("a run the user cancels is recorded as cancelled, not as an interruption")
    func userCancellationIsRecorded() async throws {
        // hang-backup, not hang: the post-run refresh must answer instead of
        // burning its 300 s timeout.
        let harness = try await makeHarness(stubMode: "hang-backup")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        // The cancel must land mid-run, so wait for the stub's sleep child to
        // show up in the process table instead of betting that 300 ms is long
        // enough for a cold first spawn.
        model.runBackup(planID: harness.plan.id)
        let stub = try #require(harness.stub)
        #expect(
            await StubRestic.waitForHang(matching: stub.sleepMarker, within: 10),
            "the stub never established its hang within 10 s"
        )
        model.cancelBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.outcome == .cancelled)
        #expect(record.failureMessage == "Cancelled")

        await model.shutdown()
    }

    @Test("the scheduler starts a due plan on its own, and the history is persisted")
    func schedulerRunsDuePlanUnprompted() async throws {
        // An hourly plan that has never run is due the moment the app starts, so
        // nothing here triggers the backup — the scheduler has to.
        let harness = try await makeHarness(frequency: .hourly)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        let deadline = Date.now.addingTimeInterval(30)
        while model.configuration.runs.isEmpty, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        await model.waitForRun(planID: harness.plan.id)

        let record = try #require(model.configuration.runs.first, "the scheduler never ran the plan")
        #expect(record.planID == harness.plan.id)
        // Once a snapshot exists, the run is never recorded as a failure,
        // whatever happens during the retention step.
        #expect(record.outcome != .failed)
        #expect(model.plan(id: harness.plan.id)?.lastSuccessAt != nil)
        #expect(record.outcome == .succeeded, "unexpected warnings: \(record.itemErrors)")

        // Having just run, the plan must not be due again immediately.
        #expect(Scheduler.duePlans(
            in: model.configuration.plans,
            existingRepositoryIDs: Set(model.configuration.repositories.map(\.id))
        ).isEmpty)

        await model.flushSave()
        let reloaded = try await ConfigStore(
            directory: harness.root.appendingPathComponent("config")
        ).load().configuration
        #expect(reloaded.runs.count == 1)
        #expect(reloaded.runs.first?.outcome == .succeeded)
        #expect(reloaded.plans.first?.lastSuccessAt != nil)

        await model.shutdown()
    }
}

/// The banner queue's contract: an unread error survives the next message,
/// the queue is bounded, and dismissal removes exactly one message.
@Suite("Banner queue")
@MainActor
struct BannerQueueTests {
    private func makeModel() -> AppModel {
        var secrets: [UUID: (password: String, providerSecret: String?)] = [:]
        return AppModel(
            store: ConfigStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SwiftResticBanners-\(UUID().uuidString)")
            ),
            secrets: .inMemory(secrets)
        )
    }

    @Test("newest first, dismissal by identity")
    func queueSemantics() {
        let model = makeModel()
        model.post(Banner(title: "first", message: "", isError: true))
        model.post(Banner(title: "second", message: "", isError: true))
        #expect(model.banners.map(\.title) == ["second", "first"])

        model.dismiss(model.banners[0])
        #expect(model.banners.map(\.title) == ["first"])
    }

    @Test("the queue is bounded so a failure loop cannot stack banners without end")
    func bounded() {
        let model = makeModel()
        for index in 0 ..< 10 {
            model.post(Banner(title: "banner \(index)", message: "", isError: true))
        }
        #expect(model.banners.count == 4)
        // The newest survive: the oldest were dropped, not the ones the user
        // is most likely to be reading.
        #expect(model.banners.map(\.title) == ["banner 9", "banner 8", "banner 7", "banner 6"])
    }

    @Test("the cap evicts a success before it gives up an error")
    func capPrefersErrors() {
        let model = makeModel()
        model.post(Banner(title: "error", message: "", isError: true))
        for index in 0 ..< 4 {
            model.post(Banner(title: "ok \(index)", message: "", isError: false))
        }
        // Queue is at the cap ("ok 3" … "ok 0", "error"). One more post has to
        // evict the oldest success, never the unread error.
        model.post(Banner(title: "ok 4", message: "", isError: false))
        #expect(model.banners.count == 4)
        #expect(model.banners.contains { $0.title == "error" })
        #expect(model.banners.first?.title == "ok 4")

        // An all-error queue falls back to dropping its oldest.
        let errors = makeModel()
        for index in 0 ..< 5 {
            errors.post(Banner(title: "e\(index)", message: "", isError: true))
        }
        #expect(errors.banners.map(\.title) == ["e4", "e3", "e2", "e1"])
    }
}

/// The snapshot → backup-run join behind the incomplete marks: derived when
/// the run history is written, never rebuilt by the rows that read it.
@Suite("Snapshot run lookup")
@MainActor
struct SnapshotRunLookupTests {
    private func backup(_ snapshotID: String?) -> RunRecord {
        var record = RunRecord(kind: .backup, planName: "Docs")
        record.snapshotID = snapshotID
        return record
    }

    @Test("the model keeps each snapshot's backup run in step with the history")
    func modelKeepsSnapshotRunsInStep() {
        let model = AppModel(
            store: ConfigStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SwiftResticSnapshotRuns-\(UUID().uuidString)")
            ),
            secrets: .inMemory()
        )
        model.configuration.settings.maxRunHistory = 20

        let wrote = backup("s1")
        model.append(record: wrote)
        #expect(model.backupRun(forSnapshot: "s1")?.id == wrote.id)

        // A restore that read the snapshot is not what wrote it.
        var restore = RunRecord(kind: .restore)
        restore.snapshotID = "s1"
        model.append(record: restore)
        #expect(model.backupRun(forSnapshot: "s1")?.id == wrote.id)

        // Trimmed out of the history: the join forgets it rather than
        // keeping a mark the history no longer backs.
        for _ in 0 ..< 20 { model.append(record: backup(nil)) }
        #expect(!model.configuration.runs.contains { $0.id == wrote.id })
        #expect(model.backupRun(forSnapshot: "s1") == nil)

        model.append(record: backup("s2"))
        #expect(model.backupRun(forSnapshot: "s2") != nil)
        model.clearRunHistory()
        #expect(model.backupRun(forSnapshot: "s2") == nil)

        // Any write to the history counts, not only the model's own helpers.
        let assigned = backup("s3")
        model.configuration.runs = [assigned]
        #expect(model.backupRun(forSnapshot: "s3")?.id == assigned.id)
    }
}

/// The numbers the index orders a repository's listings by. One counter
/// serves every repository — the index compares numbers only within one
/// (IndexCoordinatorGenerationTests) — so each number must be newer than
/// every one handed out before it, and none may be 0, which `rebuildIndex`
/// sends for a listing never read.
@Suite("Listing generations")
@MainActor
struct ListingGenerationTests {
    @Test("each listing number is newer than every one handed out before it")
    func numbersOnlyRise() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticListingGenerations-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(store: ConfigStore(directory: directory), secrets: .inMemory())
        #expect((0 ..< 5).map { _ in model.nextListingGeneration() } == [1, 2, 3, 4, 5])
    }
}

/// Saving an editor draft must never erase what the model wrote while the
/// sheet was open: the run and maintenance stamps are the scheduler's and the
/// dashboard's ground truth.
@Suite("Editor upsert preserves model-written stamps")
@MainActor
struct UpsertStampTests {
    private func makeModel() -> AppModel {
        var secrets: [UUID: (password: String, providerSecret: String?)] = [:]
        return AppModel(
            store: ConfigStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SwiftResticUpsert-\(UUID().uuidString)")
            ),
            secrets: .inMemory(secrets)
        )
    }

    @Test("a stale plan draft keeps the last-run and last-success stamps")
    func planStampsSurviveStaleUpsert() {
        let model = makeModel()
        var plan = BackupPlan()
        plan.name = "Nightly"
        plan.repositoryID = UUID()
        plan.sources = ["/tmp"]

        model.upsert(plan: plan)

        // The model stamps a finished run, the way markPlanRun does.
        let ranAt = Date.now.addingTimeInterval(-600)
        model.configuration.plans[0].lastRunAt = ranAt
        model.configuration.plans[0].lastSuccessAt = ranAt

        // A draft taken before that run is saved with an unrelated edit.
        var staleDraft = plan
        staleDraft.schedule.intervalHours = 7
        model.upsert(plan: staleDraft)

        #expect(model.configuration.plans[0].lastRunAt == ranAt)
        #expect(model.configuration.plans[0].lastSuccessAt == ranAt)
        #expect(model.configuration.plans[0].schedule.intervalHours == 7)
    }

    @Test("a stale plan draft keeps the plan's timed pause")
    func planPauseSurvivesStaleUpsert() {
        let model = makeModel()
        var plan = BackupPlan()
        plan.name = "Nightly"
        plan.repositoryID = UUID()
        plan.sources = ["/tmp"]
        model.upsert(plan: plan)

        // Paused while the editor held its copy, as pausePlanSchedule does.
        let until = Date(timeIntervalSince1970: 1_790_400_000)
        model.configuration.plans[0].pausedUntil = until

        var staleDraft = plan
        staleDraft.schedule.intervalHours = 7
        model.upsert(plan: staleDraft)
        #expect(model.configuration.plans[0].pausedUntil == until)
        #expect(model.configuration.plans[0].schedule.intervalHours == 7)

        // The tick cleared the lapsed pause meanwhile; a draft still carrying
        // it must not bring it back.
        model.configuration.plans[0].pausedUntil = nil
        var lapsedDraft = plan
        lapsedDraft.pausedUntil = until
        model.upsert(plan: lapsedDraft)
        #expect(model.configuration.plans[0].pausedUntil == nil)
    }

    @Test("a stale repository draft keeps the check and prune stamps")
    func repositoryStampsSurviveStaleUpsert() async {
        let model = makeModel()
        var repository = Repository()
        repository.name = "NAS"
        repository.kind = .local
        repository.localPath = "/tmp/somewhere"

        await model.upsert(repository: repository, password: nil, providerSecret: nil)

        let checkedAt = Date.now.addingTimeInterval(-3_600)
        model.configuration.repositories[0].maintenance.lastCheckAt = checkedAt
        model.configuration.repositories[0].maintenance.lastPruneAt = checkedAt

        var staleDraft = repository
        staleDraft.name = "NAS (renamed)"
        await model.upsert(repository: staleDraft, password: nil, providerSecret: nil)

        #expect(model.configuration.repositories[0].maintenance.lastCheckAt == checkedAt)
        #expect(model.configuration.repositories[0].maintenance.lastPruneAt == checkedAt)
        #expect(model.configuration.repositories[0].name == "NAS (renamed)")
    }
}

/// The model's pause surface: what the plan menus, the tray and the tick
/// write, and the one hold every display reads.
@Suite("Pausing")
@MainActor
struct PausingTests {
    private func makeModel() -> AppModel {
        let secrets: [UUID: (password: String, providerSecret: String?)] = [:]
        return AppModel(
            store: ConfigStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SwiftResticPausing-\(UUID().uuidString)")
            ),
            secrets: .inMemory(secrets)
        )
    }

    private func plan(_ name: String) -> BackupPlan {
        var plan = BackupPlan()
        plan.name = name
        plan.repositoryID = UUID()
        plan.sources = ["/tmp"]
        return plan
    }

    @Test("plan pauses, the app-wide pause and the battery hold reach the model's hold; lapsed pauses clear themselves")
    func pauseModelSemantics() {
        let model = makeModel()
        let nightly = plan("Nightly")
        model.upsert(plan: nightly)
        let now = Date(timeIntervalSince1970: 1_790_400_000)

        model.pausePlanSchedule(id: nightly.id, for: .oneHour, now: now)
        #expect(model.configuration.plans[0].isEnabled)
        #expect(model.configuration.plans[0].pausedUntil == now.addingTimeInterval(3600))
        model.pausePlanSchedule(id: nightly.id, for: .untilResumed, now: now)
        #expect(!model.configuration.plans[0].isEnabled)
        #expect(model.configuration.plans[0].pausedUntil == nil)
        model.resumePlanSchedule(id: nightly.id)
        #expect(model.configuration.plans[0].isEnabled)
        #expect(model.configuration.plans[0].pausedUntil == nil)

        #expect(model.scheduleHold == nil)
        model.pauseBackups(for: .untilResumed)
        #expect(model.scheduleHold == .paused(until: nil))
        model.resumeBackups()
        #expect(model.scheduleHold == nil)
        #expect(model.configuration.settings.schedulePause == nil)

        model.configuration.settings.pauseOnBattery = true
        model.isOnBattery = true
        #expect(model.scheduleHold == .onBattery)
        model.isOnBattery = false
        #expect(model.scheduleHold == nil)

        // The tick's sweep clears exactly what lapsed.
        let lapsedPlan = plan("Lapsed")
        let livePlan = plan("Live")
        model.upsert(plan: lapsedPlan)
        model.upsert(plan: livePlan)
        let later = Date.now.addingTimeInterval(7200)
        model.configuration.settings.schedulePause = SchedulePause(until: later.addingTimeInterval(-60))
        model.configuration.plans[1].pausedUntil = later.addingTimeInterval(-1)
        model.configuration.plans[2].pausedUntil = later.addingTimeInterval(3600)
        model.expireLapsedPauses(now: later)
        #expect(model.configuration.settings.schedulePause == nil)
        #expect(model.configuration.plans[1].pausedUntil == nil)
        #expect(model.configuration.plans[2].pausedUntil == later.addingTimeInterval(3600))
        // An open-ended pause never lapses.
        model.configuration.settings.schedulePause = SchedulePause(until: nil)
        model.expireLapsedPauses(now: later)
        #expect(model.configuration.settings.schedulePause == SchedulePause(until: nil))
    }
}

/// The scheduler lives in the app's process, so a schedule dies with it. What
/// the plan editor and the quit alert say about that, from the model's side.
@Suite("Start at login surfaces")
@MainActor
struct StartAtLoginSurfaceTests {
    private func makeModel() -> (model: AppModel, plan: BackupPlan) {
        let model = AppModel(
            store: ConfigStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SwiftResticLoginItem-\(UUID().uuidString)")
            ),
            secrets: .inMemory()
        )
        var repository = Repository()
        repository.name = "NAS"
        repository.kind = .local
        repository.localPath = "/tmp/somewhere"
        var plan = BackupPlan()
        plan.name = "Documents"
        plan.repositoryID = repository.id
        plan.sources = ["/tmp"]
        plan.schedule.frequency = .daily
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan]
        return (model, plan)
    }

    @Test("an idle quit asks only when the user chose it — a quit requested from outside never waits")
    func idleQuitAsksOnlyWhenChosen() throws {
        let (model, plan) = makeModel()
        let chosen = try #require(model.quitConfirmation(userChoseQuit: true))
        #expect(!chosen.interruptsWork)
        #expect(chosen.message.contains(plan.name))
        #expect(chosen.message.contains("nothing will run until you open it again"))
        // Logout, restart, shutdown, the Dock and AppleScript all arrive as
        // a quit the user did not choose here: an idle app never holds them.
        #expect(model.quitConfirmation(userChoseQuit: false) == nil)

        model.startsAtLogin = true
        #expect(model.quitConfirmation(userChoseQuit: true) == nil)
        model.startsAtLogin = false
        model.configuration.plans[0].schedule.frequency = .manual
        #expect(model.quitConfirmation(userChoseQuit: true) == nil)
    }

    /// `Format.relative` reads the real clock, so a notice's date is
    /// anchored there: a fixed date would read "is next due 2 days ago" and
    /// still pass a prefix check. The daily slot sits twelve hours off
    /// that clock, so "due" and "next" cannot tie whenever this runs.
    private func anchorToRealClock(_ model: AppModel) -> Date {
        let now = Date.now
        model.configuration.plans[0].schedule.hour = (Calendar.current.component(.hour, from: now) + 12) % 24
        return now
    }

    @Test("a scheduled run already overdue is named as due now, not in the past")
    func overdueRunIsDueNow() throws {
        let (model, _) = makeModel()
        let now = anchorToRealClock(model)
        // Never run: the slot that passed is due, and the pick clamps to now.
        let overdue = try #require(model.quitScheduleNotice(now: now))
        #expect(overdue.hasPrefix("Documents (NAS) is due now."))
        model.configuration.plans[0].lastRunAt = now
        let next = try #require(model.configuration.plans[0].schedule.nextRunDate(after: now, now: now))
        let upcoming = try #require(model.quitScheduleNotice(now: now))
        #expect(upcoming.hasPrefix("Documents (NAS) is next due \(Format.relative(next))."))
        #expect(!upcoming.contains(" ago"))
        // Seconds away is due now too: the relative phrase for it is
        // "Just now", and "is next due Just now" is no sentence.
        model.configuration.plans[0].schedule.frequency = .hourly
        model.configuration.plans[0].schedule.intervalHours = 1
        model.configuration.plans[0].lastRunAt = now.addingTimeInterval(-3600 + 30)
        let imminent = try #require(model.quitScheduleNotice(now: now))
        #expect(imminent.hasPrefix("Documents (NAS) is due now."))
        // A repository named like the plan is not said twice — the tray's rule.
        model.configuration.repositories[0].name = "Documents"
        let sameName = try #require(model.quitScheduleNotice(now: now))
        #expect(sameName.hasPrefix("Documents is due now."))
    }

    @Test("under a hold the quit sentence names it first, as the tray's line does")
    func quitNoticeNamesTheHold() throws {
        let (model, _) = makeModel()
        let now = anchorToRealClock(model)
        // A timed hold moves a due run to its end, where the scheduler
        // picks it up, and says whose end that is.
        model.pauseBackups(for: .oneHour, now: now)
        let end = try #require(model.configuration.settings.schedulePause?.until)
        let timed = try #require(model.quitScheduleNotice(now: now))
        #expect(timed.hasPrefix(
            "\(ScheduleHold.paused(until: end).summary(now: now)). Documents (NAS) is next due \(Format.relative(end))."
        ))
        #expect(!timed.contains(" ago"))

        // An open-ended hold sets no date. A slot still ahead keeps its
        // date, which the scheduler keeps only if the hold lifts by then —
        // so the hold is named, as the tray's line names it …
        model.pauseBackups(for: .untilResumed, now: now)
        model.configuration.plans[0].lastRunAt = now
        let next = try #require(model.configuration.plans[0].schedule.nextRunDate(after: now, now: now))
        let paused = try #require(model.quitScheduleNotice(now: now))
        #expect(paused.hasPrefix("Backups paused until you resume. Documents (NAS) is next due \(Format.relative(next))."))
        // … and a due run waits, never "due now".
        model.configuration.plans[0].lastRunAt = nil
        let pausedDue = try #require(model.quitScheduleNotice(now: now))
        #expect(pausedDue.hasPrefix("Backups paused until you resume. Documents (NAS) is waiting to run."))

        model.resumeBackups()
        model.configuration.settings.pauseOnBattery = true
        model.isOnBattery = true
        model.configuration.plans[0].lastRunAt = now
        let battery = try #require(model.quitScheduleNotice(now: now))
        #expect(battery.hasPrefix(
            "Backups wait for power — this Mac is on battery. Documents (NAS) is next due \(Format.relative(next))."
        ))
        model.configuration.plans[0].lastRunAt = nil
        let batteryDue = try #require(model.quitScheduleNotice(now: now))
        #expect(batteryDue.hasPrefix("Backups wait for power — this Mac is on battery. Documents (NAS) is waiting to run."))

        // Only a hold in force at `now` counts.
        model.isOnBattery = false
        let clear = try #require(model.quitScheduleNotice(now: now))
        #expect(clear.hasPrefix("Documents (NAS) is due now."))
    }

    @Test("a backup the quit stops has its slot counted as run, as the stop will stamp it — unless Pause and Stop ended it")
    func runInFlightIsNotTheMissedRun() throws {
        let (model, plan) = makeModel()
        let now = anchorToRealClock(model)
        // Due, and running: the quit's cancel stamps the run's start, so
        // this slot is covered and the one missed is the next.
        let startedAt = now.addingTimeInterval(-60)
        model.activity[plan.id] = PlanActivity(phase: .backingUp, startedAt: startedAt)
        let next = try #require(model.configuration.plans[0].schedule.nextRunDate(after: startedAt, now: now))
        let running = try #require(model.quitScheduleNotice(now: now))
        #expect(running.hasPrefix("Documents (NAS) is next due \(Format.relative(next))."))

        // Pause and Stop leaves the slot unstamped, so it runs again when
        // the pause ends: that end is the date.
        model.pauseBackups(for: .oneHour, now: now)
        model.pauseStoppedPlanIDs.insert(plan.id)
        let end = try #require(model.configuration.settings.schedulePause?.until)
        let stopped = try #require(model.quitScheduleNotice(now: now))
        #expect(stopped.contains("Documents (NAS) is next due \(Format.relative(end))."))
    }
}

/// A progress hop still in flight when a run unwinds must not write into the
/// next run's strip — the run-identity rule `restoreRunToken` gives restores,
/// pinned here at the seam the engines use.
@Suite("Run reporters answer to their own run")
@MainActor
struct RunReporterTokenTests {
    private func makeModel() -> AppModel {
        var secrets: [UUID: (password: String, providerSecret: String?)] = [:]
        return AppModel(
            store: ConfigStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SwiftResticRunTokens-\(UUID().uuidString)")
            ),
            secrets: .inMemory(secrets)
        )
    }

    /// Lets a reporter's `Task { @MainActor in … }` land before asserting.
    /// The passing run lands on the first poll; the 1 s bound is for a
    /// loaded machine, so a slow hop cannot flake the test.
    private func drainReporterHops() async {
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("a late progress hop from a finished backup never lands in the next run's strip")
    func lateBackupProgressHopDrops() async throws {
        let model = makeModel()
        var plan = BackupPlan()
        plan.name = "Hop"
        model.upsert(plan: plan)

        // Run 1: a strip is installed and the engine captures its reporter.
        model.installPlanActivity(planID: plan.id)
        let reporter = model.progressReporter(planID: plan.id)

        // Run 1 unwinds: token and strip are retired, exactly as the engine
        // task does.
        model.backupRunTokens[plan.id] = nil
        model.activity[plan.id] = nil
        model.planProgress[plan.id] = nil
        // A hop still in flight must not resurrect the cleared strip.
        var staleHop = OperationProgress()
        staleHop.filesDone = 11
        reporter(staleHop)
        await drainReporterHops()
        #expect(model.activity[plan.id] == nil)
        #expect(model.planProgress[plan.id] == nil)

        // Run 2 installs a fresh strip; run 1's hop finally lands. A fresh
        // strip starts from zeroed progress, so a new run's strip cannot open
        // on the previous run's last percentage.
        model.installPlanActivity(planID: plan.id)
        #expect(model.planProgress[plan.id] == OperationProgress())
        var seed = OperationProgress()
        seed.filesDone = 1
        model.planProgress[plan.id] = seed
        reporter(staleHop)
        await drainReporterHops()
        #expect(model.planProgress[plan.id]?.filesDone == 1)
    }

    @Test("a late maintenance line never lands in the next job's activity")
    func lateMaintenanceLineDrops() async throws {
        let model = makeModel()
        var repository = Repository()
        repository.name = "NAS"
        repository.kind = .local
        repository.localPath = "/tmp/somewhere"
        try await model.upsert(repository: repository, password: nil, providerSecret: nil)

        model.installMaintenanceActivity(repositoryID: repository.id, task: .prune)
        let reporter = model.lineReporter(repositoryID: repository.id)

        // Job 1 unwinds: token and activity are retired; a line still in
        // flight must not resurrect either.
        model.maintenanceRunTokens[repository.id] = nil
        model.maintenance[repository.id] = nil
        reporter("run 1: pruning…")
        await drainReporterHops()
        #expect(model.maintenance[repository.id] == nil)

        // Job 2 starts; job 1's line lands late and must not overwrite it.
        model.installMaintenanceActivity(repositoryID: repository.id, task: .prune)
        model.maintenance[repository.id]?.lastOutput = "run 2: pruning…"
        reporter("run 1: pruning…")
        await drainReporterHops()
        #expect(model.maintenance[repository.id]?.lastOutput == "run 2: pruning…")
    }
}


/// A Keychain read failure must keep its own name. Read as nil, it borrows
/// the "no password stored" costume and the app diagnoses the wrong thing.
@Suite("keychain failure honesty")
struct KeychainFailureHonestyTests {
    @Test("a failing keychain read is not a missing password")
    func keychainErrorKeepsItsName() async {
        let secrets = SecretStore(
            load: { (_: UUID) in throw KeychainStore.KeychainError.unexpectedStatus(errSecInteractionNotAllowed) },
            save: { _, _, _ in },
            remove: { _ in }
        )
        var repository = Repository()
        repository.kind = .local
        repository.localPath = "/tmp/some-repo"

        do {
            _ = try await AppModel.dragContext(
                repository: repository,
                settings: AppSettings(),
                secrets: secrets
            )
            Issue.record("expected the keychain failure to surface")
        } catch ResticError.passwordMissing {
            Issue.record("a keychain failure must not masquerade as a missing password")
        } catch {
            // Anything else is the error itself, carried to the run record
            // and banner with its own words.
        }
    }

    @Test("a failing keychain save leaves the repository waiting for a password")
    @MainActor
    func failedSaveKeepsTheMissingPasswordFlag() async {
        let secrets = SecretStore(
            load: { (_: UUID) in (password: nil, providerSecret: nil) },
            save: { (_: UUID, _: String?, _: String?) in
                throw KeychainStore.KeychainError.unexpectedStatus(errSecInteractionNotAllowed)
            },
            remove: { (_: UUID) in }
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticKeychainSave-\(UUID().uuidString)")
        let model = AppModel(store: ConfigStore(directory: root), secrets: secrets)
        model.isLoaded = true

        var repository = Repository()
        repository.kind = .local
        repository.localPath = "/tmp/some-repo"
        model.repositoriesMissingPassword.insert(repository.id)

        await model.upsert(repository: repository, password: "new password", providerSecret: nil)

        // The save failed: the repository has no usable password, and the
        // scheduler must keep treating it as the skip-not-retry case instead
        // of scheduling upkeep that can only fail.
        #expect(model.repositoriesMissingPassword.contains(repository.id))
    }
}


@Suite("configuration saves")
@MainActor
struct ConfigurationSaveTests {
    @Test("overlapping saves all return, and the last state asked for is what lands")
    func overlappingSavesSettle() async throws {
        // A quit's flush landing on the debounced save's, or the repository
        // editor's flush on either: the calls overlap, and must all return —
        // a wait loop here spins the main actor (awaiting an already-finished
        // task never suspends).
        let watchdog = HangWatchdog(seconds: 10, "three overlapping flushSave calls never returned — the main actor is spinning")
        defer { watchdog.disarm() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticOverlappingSaves-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: ConfigStore(directory: root), secrets: .inMemory())
        model.isLoaded = true
        // Only the three flushes below write: no debounced save joins in.
        model.suppressConfigurationSave = true

        let saves = (1 ... 3).map { index in
            Task { @MainActor in
                model.configuration.settings.maxRunHistory = 100 + index
                await model.flushSave()
            }
        }
        for save in saves { await save.value }

        let saved = try await ConfigStore(directory: root).load().configuration
        #expect(saved.settings.maxRunHistory == 103)
    }
}

@Suite("snapshot index location")
@MainActor
struct IndexLocationTests {
    @Test("a model's snapshot indexes live beside its configuration")
    func indexFollowsTheStore() {
        // Every model a test builds points its store at a temporary folder;
        // the index must follow it and never write into the real Application
        // Support folder.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticIndexHome-\(UUID().uuidString)")
        let model = AppModel(store: ConfigStore(directory: root), secrets: .inMemory())
        #expect(model.indexCoordinator.directory == root)
        // The files themselves live in a folder of their own inside it, the
        // only folder the orphan sweep may touch.
        #expect(model.indexCoordinator.indexDirectory.path == root.appendingPathComponent("index").path)
        let repositoryID = UUID()
        #expect(
            model.indexCoordinator.fileURL(for: repositoryID).path
                == root.appendingPathComponent("index/\(repositoryID.uuidString).sqlite").path
        )
    }
}

/// Launch's orphan-index sweep, through `bootstrap`: it runs only from a
/// repository list that read whole. Every other load can miss a live
/// repository — and then that repository's index reads as an orphan.
@Suite("index orphan sweep at launch")
@MainActor
struct IndexOrphanSweepLaunchTests {
    /// How the configuration folder is left before launch.
    enum Load: String, CaseIterable, CustomTestStringConvertible {
        /// No generation reads: the configuration reads as no repositories.
        case unreadable
        /// The live file is corrupt; `config.json.1` is read instead.
        case recovered
        /// The live file reads, but the repository's `id` does not — tolerant
        /// decoding gives it a fresh one, so its real index looks orphaned.
        case substitutedID

        var testDescription: String { rawValue }
    }

    /// A configuration folder, and the three files the sweep must judge.
    private struct Folder {
        var root: URL
        var config: URL
        /// The configured repository's index file.
        var repositoryFile: URL
        /// An index file whose repository no configuration names.
        var orphanFile: URL
        /// The orphan's file at the index's earlier home, `<configDir>/<uuid>.sqlite`.
        var earlierHome: URL
    }

    /// A configuration folder naming one repository (no password stored, so
    /// the launch refresh never runs restic), left the way `load` says, with
    /// the three files already on disk.
    private func makeFolder(_ load: Load?) throws -> Folder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticLaunchSweep-\(UUID().uuidString)")
        let config = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)

        var repository = Repository()
        repository.name = "Kept"
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        var configuration = AppConfiguration()
        configuration.repositories = [repository]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let whole = try encoder.encode(configuration)
        let live = config.appendingPathComponent("config.json")
        switch load {
        case nil:
            try whole.write(to: live)
        case .unreadable:
            for name in ["config.json", "config.json.1", "config.json.2"] {
                try Data("{ not json".utf8).write(to: config.appendingPathComponent(name))
            }
        case .recovered:
            try Data("{ not json".utf8).write(to: live)
            try whole.write(to: config.appendingPathComponent("config.json.1"))
        case .substitutedID:
            let text = String(decoding: whole, as: UTF8.self)
            try #require(text.contains(repository.id.uuidString))
            try Data(text.replacingOccurrences(of: repository.id.uuidString, with: "not-a-uuid").utf8).write(to: live)
        }

        // The paths the model's own coordinator will use for this folder.
        let paths = IndexCoordinator(directory: config)
        try FileManager.default.createDirectory(at: paths.indexDirectory, withIntermediateDirectories: true)
        let orphan = UUID()
        let folder = Folder(
            root: root,
            config: config,
            repositoryFile: paths.fileURL(for: repository.id),
            orphanFile: paths.fileURL(for: orphan),
            earlierHome: config.appendingPathComponent(orphan.uuidString + ".sqlite")
        )
        for file in [folder.repositoryFile, folder.orphanFile, folder.earlierHome] {
            try Data("x".utf8).write(to: file)
        }
        return folder
    }

    private func launch(in folder: Folder) async {
        let model = AppModel(store: ConfigStore(directory: folder.config), secrets: .inMemory())
        await model.bootstrap()
        // The sweep rides the background lane, which shutdown drains.
        await model.shutdown()
    }

    @Test("a whole configuration sweeps the orphan and keeps its repository's index and the earlier home")
    func wholeConfigurationSweeps() async throws {
        let folder = try makeFolder(nil)
        defer { try? FileManager.default.removeItem(at: folder.root) }

        await launch(in: folder)

        #expect(!FileManager.default.fileExists(atPath: folder.orphanFile.path), "the orphan's index survived a whole configuration")
        #expect(FileManager.default.fileExists(atPath: folder.repositoryFile.path), "a configured repository's index was swept")
        #expect(FileManager.default.fileExists(atPath: folder.earlierHome.path), "a file outside index/ was swept")
    }

    @Test("a configuration that did not read whole sweeps nothing", arguments: Load.allCases)
    func partialConfigurationSweepsNothing(_ load: Load) async throws {
        let folder = try makeFolder(load)
        defer { try? FileManager.default.removeItem(at: folder.root) }

        await launch(in: folder)

        for file in [folder.repositoryFile, folder.orphanFile, folder.earlierHome] {
            #expect(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent) was swept after a \(load) load")
        }
    }
}

/// Launch's orphan-plan purge, through `bootstrap`: a plan naming no
/// configured repository is deleted, and the deletion is saved. Only from a
/// repository list that read whole, for the index sweep's reason: every
/// other load can miss a live repository, and its plans would read as
/// orphans.
@Suite("orphan plan purge at launch")
@MainActor
struct OrphanPlanPurgeLaunchTests {
    private struct Folder {
        var root: URL
        var config: URL
        var attached: BackupPlan
        /// No repository: a plan naming nothing.
        var detached: BackupPlan
        /// A repository id no configured repository has.
        var dangling: BackupPlan
    }

    /// A configuration folder naming one repository (no password stored, so
    /// the launch refresh never runs restic) and three plans, left the way
    /// `load` says.
    private func makeFolder(_ load: IndexOrphanSweepLaunchTests.Load?) throws -> Folder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticOrphanPlans-\(UUID().uuidString)")
        let config = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)

        var repository = Repository()
        repository.name = "Kept"
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        func plan(_ name: String, repositoryID: UUID?) -> BackupPlan {
            var plan = BackupPlan()
            plan.name = name
            plan.repositoryID = repositoryID
            plan.sources = [root.path]
            plan.schedule.frequency = .manual
            plan.isEnabled = repositoryID == repository.id
            return plan
        }
        let folder = Folder(
            root: root,
            config: config,
            attached: plan("Attached", repositoryID: repository.id),
            detached: plan("Detached", repositoryID: nil),
            dangling: plan("Dangling", repositoryID: UUID())
        )
        var configuration = AppConfiguration()
        configuration.repositories = [repository]
        configuration.plans = [folder.detached, folder.attached, folder.dangling]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let whole = try encoder.encode(configuration)
        let live = config.appendingPathComponent("config.json")
        switch load {
        case nil:
            try whole.write(to: live)
        case .unreadable:
            for name in ["config.json", "config.json.1", "config.json.2"] {
                try Data("{ not json".utf8).write(to: config.appendingPathComponent(name))
            }
        case .recovered:
            try Data("{ not json".utf8).write(to: live)
            try whole.write(to: config.appendingPathComponent("config.json.1"))
        case .substitutedID:
            // The repository's own `id` does not read, so it decodes with a
            // fresh one and the attached plan's id names nothing — the plan
            // the gate exists to keep.
            let text = String(decoding: whole, as: UTF8.self)
            let marker = "\"id\":\"\(repository.id.uuidString)\""
            try #require(text.contains(marker))
            try Data(text.replacingOccurrences(of: marker, with: "\"id\":\"not-a-uuid\"").utf8).write(to: live)
        }
        return folder
    }

    /// The plans after launch, and the plans a fresh read of the folder finds.
    private func launch(in folder: Folder) async throws -> (memory: [UUID], disk: [UUID]?) {
        let store = ConfigStore(directory: folder.config)
        let model = AppModel(store: store, secrets: .inMemory())
        await model.bootstrap()
        let memory = model.configuration.plans.map(\.id)
        await model.flushSave()
        await model.shutdown()
        let disk = try? await ConfigStore(directory: folder.config).load().configuration.plans.map(\.id)
        return (memory, disk)
    }

    @Test("a whole configuration deletes the plans whose repository is gone, and saves it")
    func wholeConfigurationPurges() async throws {
        let folder = try makeFolder(nil)
        defer { try? FileManager.default.removeItem(at: folder.root) }

        let plans = try await launch(in: folder)

        #expect(plans.memory == [folder.attached.id])
        #expect(plans.disk == [folder.attached.id], "the purge was not saved")
    }

    @Test("a configuration that did not read whole deletes no plan", arguments: IndexOrphanSweepLaunchTests.Load.allCases)
    func partialConfigurationKeepsPlans(_ load: IndexOrphanSweepLaunchTests.Load) async throws {
        let folder = try makeFolder(load)
        defer { try? FileManager.default.removeItem(at: folder.root) }

        let plans = try await launch(in: folder)

        let all = [folder.detached.id, folder.attached.id, folder.dangling.id]
        switch load {
        case .unreadable:
            // Nothing read, so nothing is in memory — and nothing may reach
            // the files, which still hold every plan in their backup copies.
            #expect(plans.memory.isEmpty)
            #expect(plans.disk == nil)
        case .recovered, .substitutedID:
            #expect(plans.memory == all, "a plan was purged after a \(load) load")
            #expect(plans.disk == all, "a purge reached the file after a \(load) load")
        }
    }
}

/// When no generation of the configuration reads, the files on disk are the
/// only good copy left — and every save's rotation would shuffle the corrupt
/// live file over them. Refusing saves is the whole protection.
@Suite("unreadable configuration protection")
@MainActor
struct UnreadableConfigurationTests {
    @Test("nothing is saved over the backup copies when no generation reads")
    func savesAreRefusedAfterUnreadableLoad() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticUnreadable-\(UUID().uuidString)")
        let configDirectory = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["config.json", "config.json.1", "config.json.2"] {
            try Data("{ not json".utf8).write(to: configDirectory.appendingPathComponent(name))
        }

        let model = AppModel(
            store: ConfigStore(directory: configDirectory),
            secrets: .inMemory()
        )
        await model.bootstrap()
        defer { Task { await model.shutdown() } }

        #expect(model.isConfigurationUnreadable, "a fully unreadable configuration must say so")

        // Any edit — and the shutdown flush — must leave the three files
        // exactly as they were: the rotation behind a save would otherwise
        // carry the corrupt live file across the good generations, and two
        // saves would erase the last readable copy.
        func snapshot() throws -> (names: [String], data: [Data]) {
            let names = try FileManager.default.contentsOfDirectory(atPath: configDirectory.path).sorted()
            return (names, try names.map { try Data(contentsOf: configDirectory.appendingPathComponent($0)) })
        }
        let before = try snapshot()
        model.configuration.settings.maxRunHistory = 111
        await model.flushSave()
        let after = try snapshot()
        #expect(after.names == before.names, "a save changed the configuration files")
        #expect(after.data == before.data, "a save landed over an unreadable configuration's backup copies")
    }
}

/// The drawer's snapshot link: whether a run's snapshot can still be opened,
/// and why not when it cannot.
@Suite("run snapshot link")
struct RunSnapshotLinkTests {
    private func snapshot(_ id: String) throws -> Snapshot {
        try ResticMessageDecoder.jsonDecoder.decode(
            Snapshot.self,
            from: Data(#"{"id":"\#(id)","short_id":"\#(id.prefix(8))","time":"2026-09-25T18:00:00Z","paths":["/src"]}"#.utf8)
        )
    }

    @Test("a run's snapshot link says available, removed, unavailable or repository gone")
    func resolve() throws {
        let full = "abf728998814d029436dc76f64e5204a4d2336134e43b921a53e52e53144137f"
        let listing = [try snapshot(full), try snapshot("73d9b51de71d34eb451a02fefd7e94ca3daa4e6c817f27549d2ff6bbf54d093f")]

        let byFull = RunSnapshotLink.resolve(snapshotID: full, repositoryExists: true, listing: listing, outcome: .loaded)
        #expect(byFull == .available(listing[0]))
        // Records that named a snapshot by its short ID still find it.
        let byShort = RunSnapshotLink.resolve(snapshotID: "abf72899", repositoryExists: true, listing: listing, outcome: .loaded)
        #expect(byShort == .available(listing[0]))
        // A stale listing that still holds it is good enough to open it.
        #expect(RunSnapshotLink.resolve(snapshotID: full, repositoryExists: true, listing: listing, outcome: .failed("offline"))
            == .available(listing[0]))

        let gone = "672523f5c8ba09c0944bb548d670cf24a9c8b5061c74a140f8232b5f8f5e1005"
        #expect(RunSnapshotLink.resolve(snapshotID: gone, repositoryExists: true, listing: listing, outcome: .loaded) == .removed)
        // Not loaded yet, or unreadable: nobody knows, so nothing is claimed.
        #expect(RunSnapshotLink.resolve(snapshotID: gone, repositoryExists: true, listing: [], outcome: .idle) == .unavailable)
        #expect(RunSnapshotLink.resolve(snapshotID: gone, repositoryExists: true, listing: listing, outcome: .failed("offline"))
            == .unavailable)
        #expect(RunSnapshotLink.resolve(snapshotID: full, repositoryExists: false, listing: listing, outcome: .loaded)
            == .repositoryGone)
    }
}

/// The banner a finished restore posts: where the item landed, and — under
/// Keep — what restic left alone, since a restore that kept files must not
/// read like one that replaced them.
@Suite("restore banner")
struct RestoreBannerTests {
    private func summary(restored: Int?, skipped: Int?) -> ResticSummary {
        var summary = ResticSummary()
        summary.filesRestored = restored
        summary.filesSkipped = skipped
        return summary
    }

    @Test("restore banner names what Keep kept and reveals the restored item")
    func restoreBannerWording() {
        let landing = URL(fileURLWithPath: "/Users/x/Restored/Project")

        let kept = AppModel.restoreBanner(
            itemName: "Project", isDirectory: true, landing: landing,
            summary: summary(restored: 1, skipped: 3), policy: .keepExisting
        )
        #expect(kept.title == "Restored Project")
        #expect(kept.message == "/Users/x/Restored/Project\nKept 3 existing files as they were.")
        #expect(kept.revealPaths == ["/Users/x/Restored/Project"])
        #expect(!kept.isError)

        let keptOne = AppModel.restoreBanner(
            itemName: "Project", isDirectory: true, landing: landing,
            summary: summary(restored: 1, skipped: 1), policy: .keepExisting
        )
        #expect(keptOne.message == "/Users/x/Restored/Project\nKept 1 existing file as it was.")

        // Replace skips only files that already match the backup: nothing was
        // kept that differs, so nothing is said.
        let replaced = AppModel.restoreBanner(
            itemName: "Project", isDirectory: true, landing: landing,
            summary: summary(restored: 1, skipped: 3), policy: .replaceExisting
        )
        #expect(replaced.title == "Restored Project")
        #expect(replaced.message == "/Users/x/Restored/Project")
        #expect(replaced.revealPaths == ["/Users/x/Restored/Project"])

        let fileLanding = URL(fileURLWithPath: "/Users/x/Restored/a.txt")
        let keptFile = AppModel.restoreBanner(
            itemName: "a.txt", isDirectory: false, landing: fileLanding,
            summary: summary(restored: 0, skipped: 1), policy: .keepExisting
        )
        #expect(keptFile.title == "Kept the existing “a.txt”")
        #expect(keptFile.message == "/Users/x/Restored/a.txt\nA file with this name was already there, so nothing was restored.")
        #expect(keptFile.revealPaths == ["/Users/x/Restored/a.txt"])

        let silent = AppModel.restoreBanner(
            itemName: "a.txt", isDirectory: false, landing: fileLanding,
            summary: summary(restored: 1, skipped: nil), policy: .keepExisting
        )
        #expect(silent.title == "Restored a.txt")
        #expect(silent.message == "/Users/x/Restored/a.txt")

        // A whole backup lands as a folder of recreated paths: the banner
        // names that folder and reveals it. "Backup" is the restore
        // surfaces' shared word, the Restore pane included.
        let destination = URL(fileURLWithPath: "/Users/x/Restored")
        let whole = AppModel.restoreBanner(
            itemName: nil, isDirectory: true, landing: destination,
            summary: summary(restored: 12, skipped: 4), policy: .keepExisting
        )
        #expect(whole.title == "Restored the whole backup")
        #expect(whole.message == "/Users/x/Restored\nKept 4 existing files as they were.")
        #expect(whole.revealPaths == ["/Users/x/Restored"])
    }
}

/// The index answers for the last listing it took. A listing the model
/// already shows but whose reconcile has not returned is not one of those:
/// read then, an index complete for the listing before answers "complete"
/// for this one too, and the Files view shows an empty folder — or a backup
/// already forgotten — without reading again.
@MainActor
@Suite("Index completeness")
struct IndexCompletenessTests {
    @Test("a listing whose reconcile has not returned is not complete, however complete the index is for the one before")
    func completenessWaitsForTheReconcile() async {
        let model = AppModel(
            store: ConfigStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SwiftResticIndexCompleteness-\(UUID().uuidString)")
            ),
            secrets: .inMemory([:])
        )
        let repositoryID = UUID()

        // The index takes an empty listing: complete for it.
        model.snapshotsGeneration[repositoryID] = 1
        model.indexReconcile(repositoryID: repositoryID, listing: [], generation: 1)
        await model.tasks.drain()
        #expect(await model.indexIsComplete(repositoryID: repositoryID))

        // A newer listing on screen, its reconcile not yet run.
        model.snapshotsGeneration[repositoryID] = 2
        #expect(await !model.indexIsComplete(repositoryID: repositoryID))

        model.indexReconcile(repositoryID: repositoryID, listing: [], generation: 2)
        await model.tasks.drain()
        #expect(await model.indexIsComplete(repositoryID: repositoryID))
    }
}

/// The "Keep runs" cap and what a standing problem still reads: the trim
/// drops the oldest records by count, except the ones a standing surface
/// would lose its problem with.
@Suite("Run history trim")
@MainActor
struct RunHistoryTrimTests {
    private func model() -> AppModel {
        let model = AppModel(
            store: ConfigStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SwiftResticTrim-\(UUID().uuidString)")
            ),
            secrets: .inMemory()
        )
        model.configuration.settings.maxRunHistory = 20
        return model
    }

    private func run(
        _ kind: RunRecord.Kind,
        plan: UUID? = nil,
        _ outcome: RunRecord.Outcome,
        hoursAgo: Double
    ) -> RunRecord {
        var record = RunRecord(kind: kind, planID: plan, planName: "Docs", startedAt: .now.addingTimeInterval(-hoursAgo * 3600))
        record.outcome = outcome
        return record
    }

    @Test("a plan's standing failure and a recent failed check outlive the cap; a healed failure, an old check and the rest trim by count")
    func standingProblemsOutliveTheCap() {
        let model = model()
        let stuck = UUID()
        let healed = UUID()
        let busy = UUID()
        // Oldest first, as they happen.
        let standing = run(.backup, plan: stuck, .failed, hoursAgo: 300)
        let olderFailure = run(.backup, plan: stuck, .completedWithErrors, hoursAgo: 310)
        let healedFailure = run(.backup, plan: healed, .failed, hoursAgo: 299)
        let healing = run(.backup, plan: healed, .succeeded, hoursAgo: 298)
        let oldCheck = run(.check, .failed, hoursAgo: 200)
        let recentCheck = run(.check, .failed, hoursAgo: 100)
        for record in [olderFailure, standing, healedFailure, healing, oldCheck, recentCheck] {
            model.append(record: record)
        }
        // A busy plan's successes push all of them past the cap.
        for index in 0 ..< 25 {
            model.append(record: run(.backup, plan: busy, .succeeded, hoursAgo: 50 - Double(index)))
        }

        let ids = Set(model.configuration.runs.map(\.id))
        #expect(ids.contains(standing.id), "the plan's caption and dot still read it")
        #expect(model.currentProblem(for: stuck)?.id == standing.id)
        #expect(ids.contains(recentCheck.id), "inside the week the repository card and the menu bar count")
        #expect(!ids.contains(olderFailure.id), "only the newest stands")
        #expect(!ids.contains(healedFailure.id))
        #expect(!ids.contains(healing.id))
        #expect(!ids.contains(oldCheck.id))
        #expect(model.configuration.runs.count == 22)
        // Newest first still.
        #expect(model.configuration.runs.first?.planID == busy)
        #expect(model.configuration.runs.last?.id == standing.id)

        // Healed, it trims like any other record.
        model.append(record: run(.backup, plan: stuck, .succeeded, hoursAgo: 0))
        model.append(record: run(.backup, plan: busy, .succeeded, hoursAgo: 0))
        #expect(!model.configuration.runs.contains { $0.id == standing.id })
        #expect(model.currentProblem(for: stuck) == nil)
    }
}
