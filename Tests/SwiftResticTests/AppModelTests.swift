import Foundation
import Testing
import UniformTypeIdentifiers

/// Exercises the glue between the scheduler, `ResticService` and the stored run
/// history — the layer where a real backup can succeed while the app still
/// records it wrongly.
@Suite("AppModel backup flow", .serialized)
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
        plan.repositoryID = repository.id
        plan.path = sourceDirectory.path
        plan.skipNothing()
        plan.schedule.frequency = frequency

        var configuration = AppConfiguration()
        configuration.repositories = [repository]
        configuration.plans = [plan]
        if stub == nil {
            _ = try await PinnedRestic.service()
                .initializeRepository(RepositoryContext(repository: repository, password: "test-password"))
        }

        let storeDirectory = root.appendingPathComponent("config")
        let store = ConfigStore(directory: storeDirectory)
        try await store.save(configuration)

        let model = AppModel(
            store: store,
            secrets: .inMemory([repository.id: (password: "test-password", providerSecret: nil)]),
            resticExecutable: try stub?.url ?? PinnedRestic.binary().url
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
        defer { try? FileManager.default.removeItem(at: model.stagingDirectory) }

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
            repositoryLabel: model.label(of: harness.repository),
            snapshotID: snapshot.id,
            node: node,
            stagingDirectory: model.stagingDirectory
        )

        #expect(url.lastPathComponent == "a.txt")
        #expect(url.deletingLastPathComponent().lastPathComponent.hasPrefix(AppModel.dragRestorePrefix))
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path
            == model.stagingDirectory.resolvingSymlinksInPath().path)
        #expect(try String(contentsOf: url, encoding: .utf8) == "one")

        // A drag restore is not a UI restore: it borrows neither the progress
        // strip nor the run history.
        #expect(model.restoreActivity == nil)
        #expect(model.configuration.runs.allSatisfy { $0.kind == .backup })

        await model.shutdown()
    }

    @Test("restic lists the node of an item named by its path, and a path the backup lacks says so")
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
        await #expect(throws: ResticError.itemNotListed(name: "gone.txt")) {
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
        await waitUntilRestoreFinishes(in: model, within: 60)

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

        // Find Files' index rows: the folder at the newer backup, the deleted
        // file at the older, the newest that holds it — no node, so each
        // one's kind in its backup is read first.
        let rows = [
            RestoreSource(name: source.lastPathComponent, path: source.path, isDirectory: true, snapshotID: backups[1].id, backupTime: backups[1].time, node: nil),
            RestoreSource(name: "b.txt", path: b.path, isDirectory: false, snapshotID: backups[0].id, backupTime: backups[0].time, node: nil),
        ]
        let selection = try #require(RestoreSelection(rows))
        #expect(selection.sources == rows)
        #expect(selection.note == nil)

        func restore(into directories: [URL]) async {
            await model.restore(selection, repositoryID: id, into: directories, overwrite: .keepExisting)
            await waitUntilRestoreFinishes(in: model, within: 60)
        }

        // One chosen folder: the folder exactly as the newer backup holds it,
        // the file beside it.
        let chosen = harness.root.appendingPathComponent("chosen")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        await restore(into: [chosen, chosen])
        let folder = chosen.appendingPathComponent(source.lastPathComponent)
        #expect(try String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8) == "one")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("b.txt").path))
        #expect(try String(contentsOf: chosen.appendingPathComponent("b.txt"), encoding: .utf8) == "two")

        // Original locations, each item into its own parent: the file is back
        // inside the folder.
        await restore(into: [source.deletingLastPathComponent(), source])
        #expect(try String(contentsOf: b, encoding: .utf8) == "two")
        #expect(try String(contentsOf: source.appendingPathComponent("a.txt"), encoding: .utf8) == "one")
        #expect(model.configuration.runs.filter { $0.kind == .restore }.allSatisfy { $0.outcome == .succeeded })

        await model.shutdown()
    }

    @Test("a selection whose item restic no longer lists restores nothing, and a banner says why")
    func restoreSelectionWhoseItemIsNotListed() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let id = harness.repository.id

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let backup = try #require(model.snapshots(for: id, planID: harness.plan.id).first)
        let gone = harness.sourceDirectory.appendingPathComponent("gone.txt").path
        let selection = try #require(RestoreSelection([
            RestoreSource(name: "gone.txt", path: gone, isDirectory: false, snapshotID: backup.id, backupTime: backup.time, node: nil),
        ]))
        let chosen = harness.root.appendingPathComponent("chosen")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)

        await model.restore(selection, repositoryID: id, into: [chosen], overwrite: .keepExisting)
        #expect(!model.isRestoring)
        #expect(model.configuration.runs.allSatisfy { $0.kind != .restore })
        let banner = try #require(model.banners.first { $0.title == "Couldn’t restore “gone.txt”" })
        #expect(banner.isError)
        #expect(banner.message == "“gone.txt” is no longer listed in the chosen backup — refresh and try again.")

        await model.shutdown()
    }

    @Test("an item asked for by path from a backup where it had the other kind restores as that backup holds it")
    func restoreByPathAcrossAKindChange() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let id = harness.repository.id
        let fileManager = FileManager.default
        let x = harness.sourceDirectory.appendingPathComponent("x")
        let y = harness.sourceDirectory.appendingPathComponent("y")

        // x a file, then a folder; y a folder, then a file.
        try "one".write(to: x, atomically: true, encoding: .utf8)
        try fileManager.createDirectory(at: y, withIntermediateDirectories: true)
        try "inner".write(to: y.appendingPathComponent("inner"), atomically: true, encoding: .utf8)
        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        try fileManager.removeItem(at: x)
        try fileManager.createDirectory(at: x, withIntermediateDirectories: true)
        try "g".write(to: x.appendingPathComponent("g"), atomically: true, encoding: .utf8)
        try fileManager.removeItem(at: y)
        try "two".write(to: y, atomically: true, encoding: .utf8)
        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let older = try #require(model.snapshots(for: id, planID: harness.plan.id).min { $0.time < $1.time })
        // Both backups indexed, so each kind comes from the index, not a listing.
        let deadline = Date.now.addingTimeInterval(60)
        while try await !model.indexIsComplete(repositoryID: id), Date.now < deadline {
            await model.tasks.drain()
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(try await model.indexIsComplete(repositoryID: id))
        #expect(try await model.indexedNode(repositoryID: id, snapshotID: older.id, path: x.path)?.isDirectory == false)
        #expect(try await model.indexedNode(repositoryID: id, snapshotID: older.id, path: y.path)?.isDirectory == true)

        func restore(_ item: URL, isDirectory: Bool, into directory: URL) async throws {
            let selection = try #require(RestoreSelection([RestoreSource(
                name: item.lastPathComponent, path: item.path, isDirectory: isDirectory,
                snapshotID: older.id, backupTime: older.time, node: nil
            )]))
            await model.restore(selection, repositoryID: id, into: [directory], overwrite: .keepExisting)
            await waitUntilRestoreFinishes(in: model, within: 60)
        }

        // The folder pane's folder itself, x asked for as a folder: the older
        // backup holds a file there, and the file comes back.
        let fresh = harness.root.appendingPathComponent("fresh")
        try fileManager.createDirectory(at: fresh, withIntermediateDirectories: true)
        try await restore(x, isDirectory: true, into: fresh)
        #expect(try String(contentsOf: fresh.appendingPathComponent("x"), encoding: .utf8) == "one")

        // The file pane's version, y asked for as a file: the older backup
        // holds a folder, restored into the folder already at the landing.
        let held = harness.root.appendingPathComponent("held")
        try fileManager.createDirectory(at: held.appendingPathComponent("y"), withIntermediateDirectories: true)
        try "mine".write(to: held.appendingPathComponent("y/mine"), atomically: true, encoding: .utf8)
        try await restore(y, isDirectory: false, into: held)
        #expect(try String(contentsOf: held.appendingPathComponent("y/inner"), encoding: .utf8) == "inner")
        #expect(try String(contentsOf: held.appendingPathComponent("y/mine"), encoding: .utf8) == "mine")
        #expect(model.configuration.runs.filter { $0.kind == .restore }.map(\.outcome) == [.succeeded, .succeeded])

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
        defer { try? FileManager.default.removeItem(at: model.stagingDirectory) }

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
        #expect(!model.banners.contains { $0.title.hasPrefix("Couldn’t restore") })

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

    @Test("a preview restores one version into its own temporary folder, and nothing is left once it closes or fails")
    func previewCopy() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        defer { try? FileManager.default.removeItem(at: model.stagingDirectory) }

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let snapshot = try #require(
            model.snapshots(for: harness.repository.id, planID: harness.plan.id).first
        )
        func previewFolders() throws -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: model.stagingDirectory.path)) ?? [])
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

        // A restore that fails takes its folder with it.
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
        model.configuration.plans[index].path = "/Volumes/SwiftRestic Test Drive/Documents"

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

        await model.shutdown()
    }

    @Test("a backup whose folder is gone from this Mac fails with a new plan in its repository as the fix, and its repeats are one record")
    func everySourceGoneFromThisMacFails() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let index = try #require(model.configuration.plans.firstIndex { $0.id == harness.plan.id })
        let gone = harness.root.appendingPathComponent("gone").path
        model.configuration.plans[index].path = gone

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.outcome == .failed)
        #expect(record.missingSources == [gone])
        #expect(record.failureMessage
            == "“gone” is not on this Mac — it was moved, renamed or deleted. Put it back, or back it up where it is now with a new plan.")
        #expect(model.fix(for: record) == .newPlan(try #require(harness.plan.repositoryID)))
        #expect(model.currentProblem(for: harness.plan.id) != nil)
        let plan = try #require(model.plan(id: harness.plan.id))
        #expect(plan.lastRunAt != nil, "the slot is stamped, so the plan does not re-fire every tick")

        // The same folders gone again: one record for both runs.
        let count = model.configuration.runs.count
        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        #expect(model.configuration.runs.count == count)
        let standing = try #require(model.configuration.runs.first)
        #expect(standing.outcome == .failed)
        #expect(standing.skipCount == 2)
        #expect(standing.skippedSince == record.startedAt)

        // A drive that is here, the folder gone from it: not an away drive.
        let startup = try #require(
            FileManager.default.contentsOfDirectory(atPath: "/Volumes").first {
                (try? FileManager.default.destinationOfSymbolicLink(atPath: "/Volumes/\($0)")) == "/"
            }
        )
        let onDriveHere = "/Volumes/\(startup)\(harness.root.path)/moved"
        model.configuration.plans[index].path = onDriveHere
        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        #expect(model.configuration.runs.first?.outcome == .failed)
        #expect(model.configuration.runs.first?.missingSources == [onDriveHere])

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
        // a failure, and the fix is finding where it went.
        model.configuration.repositories[index].localPath = harness.root.appendingPathComponent("moved").path
        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let failed = try #require(model.configuration.runs.first)
        #expect(failed.outcome == .failed)
        #expect(failed.exitCode == 10)
        #expect(model.fix(for: failed) == .locate(harness.repository.id))

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
        let away = SnapshotListingOutcome.failed(
            "“SwiftRestic Absent Drive” is not connected. Connect it to read its backups.",
            fix: .locate(id)
        )
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

    @Test("a Back Up Now whose plan is removed before its skip lands posts no banner for the removed plan")
    func removedPlansSkipIsQuiet() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let index = try #require(model.configuration.repositories.firstIndex { $0.id == harness.repository.id })
        model.configuration.repositories[index].localPath = "/Volumes/SwiftRestic Absent Drive/restic"
        model.banners.removeAll()

        model.runBackup(planID: harness.plan.id)
        model.deletePlan(id: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        #expect(model.configuration.runs.contains { $0.planID == harness.plan.id && $0.outcome == .skipped },
                "the skip itself is still recorded")
        #expect(model.banners.isEmpty, "banners were \(model.banners.map(\.title))")

        await model.shutdown()
    }

    @Test("a drive away at every slot leaves one record that counts the runs, and the replaced run's log goes with it")
    func standingSkipIsOneRecord() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let index = try #require(model.configuration.plans.firstIndex { $0.id == harness.plan.id })
        model.configuration.plans[index].path = "/Volumes/SwiftRestic Test Drive/Documents"

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let first = try #require(model.configuration.runs.first)
        #expect(try await model.loadRunLog(first) != nil)
        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)

        let backups = model.configuration.runs.filter { $0.planID == harness.plan.id && $0.kind == .backup }
        #expect(backups.count == 1)
        let standing = try #require(backups.first)
        #expect(standing.id != first.id)
        #expect(standing.skipCount == 2)
        #expect(standing.skippedSince == first.startedAt)
        #expect(try await model.loadRunLog(standing) != nil)
        await model.tasks.drain()
        #expect(try await model.loadRunLog(first) == nil, "the replaced run's log leaves with it")

        await model.shutdown()
    }

    @Test("online-only cloud files are always left out, with restic's own flag")
    func excludeCloudFilesFlag() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let run = try #require(model.configuration.runs.first)
        #expect(run.outcome == .succeeded)
        #expect(try model.runLogs.read(run.id)?.contains("--exclude-cloud-files") == true)

        await model.shutdown()
    }

    @Test("the Skip switches pass restic their rules and markers while on, beside the plan's own patterns, and nothing while off")
    func skipSwitchesReachRestic() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model
        let index = try #require(model.configuration.plans.firstIndex { $0.id == harness.plan.id })

        model.configuration.plans[index].excludePatterns = ["*.iso"]
        model.configuration.plans[index].skipsDeveloperFiles = true
        model.configuration.plans[index].skipsMachines = false
        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let with = try #require(model.configuration.runs.first)
        #expect(with.outcome == .succeeded)
        let on = try #require(try model.runLogs.read(with.id))
        #expect(on.contains("--exclude *.iso"))
        #expect(on.contains("--exclude .DS_Store"))
        // A home rule, tilde expanded, whatever the plan's folder.
        #expect(on.contains("--exclude \(NSHomeDirectory())/.Trash"))
        #expect(on.contains("--exclude \(NSHomeDirectory())/Library/Logs"))
        #expect(on.contains("--exclude-if-present project.assets.json"))
        #expect(on.contains("--exclude-if-present .rustc_info.json"))
        #expect(on.contains("--exclude-caches"))
        #expect(on.contains("--exclude \(NSHomeDirectory())/.android/avd") == false)
        #expect(on.contains("--exclude **/.venv"))
        #expect(on.contains("--exclude **/__pycache__"))
        #expect(on.contains("--exclude **/node_modules"))
        // No marker for a virtualenv: an in-place one's sits beside the
        // user's code.
        #expect(on.contains("pyvenv.cfg") == false)

        model.configuration.plans[index].skipsDeveloperFiles = false
        model.configuration.plans[index].skipsMachines = true
        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)
        let without = try #require(model.configuration.runs.first)
        #expect(without.id != with.id)
        let off = try #require(try model.runLogs.read(without.id))
        // The argument, never the bare pattern: a run's log holds restic's
        // every word, and the run's retention step echoes the snapshots'
        // recorded excludes — the switch-on run's, minutes old, among
        // them.
        #expect(off.contains("--exclude *.iso"))
        #expect(off.contains("--exclude .DS_Store"))
        #expect(off.contains("--exclude-if-present") == false)
        #expect(off.contains("--exclude **/__pycache__") == false)
        #expect(off.contains("--exclude \(NSHomeDirectory())/.android/avd"))

        await model.shutdown()
    }

    @Test("the launch sweep empties its own configuration's staging folder of drag and preview copies, and nothing else")
    @MainActor
    func dragStagingSweep() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftResticSweep-\(UUID().uuidString)")
        let model = AppModel(store: ConfigStore(directory: root), secrets: .inMemory())
        let staging = model.stagingDirectory
        // Another configuration's — another SwiftRestic's, running — and the
        // shared temporary folder's own, which earlier builds staged in.
        let otherStaging = AppModel.stagingDirectory(for: root.appendingPathComponent("other"))
        #expect(otherStaging != staging)
        let temp = FileManager.default.temporaryDirectory
        let stale = staging.appendingPathComponent("\(AppModel.dragRestorePrefix)\(UUID().uuidString)")
        let file = staging.appendingPathComponent("\(AppModel.dragRestorePrefix)\(UUID().uuidString)")
        let preview = staging.appendingPathComponent("\(AppModel.previewPrefix)\(UUID().uuidString)")
        let unrelated = staging.appendingPathComponent("SwiftRestic-Keep-\(UUID().uuidString)")
        let othersPreview = otherStaging.appendingPathComponent("\(AppModel.previewPrefix)\(UUID().uuidString)")
        let sharedPreview = temp.appendingPathComponent("\(AppModel.previewPrefix)\(UUID().uuidString)")
        for folder in [stale, preview, unrelated, othersPreview, sharedPreview] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer {
            for url in [root, staging, otherStaging, sharedPreview] { try? FileManager.default.removeItem(at: url) }
        }

        await model.bootstrap()
        await model.tasks.drain()

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: preview.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: othersPreview.path), "another configuration's preview was deleted")
        #expect(FileManager.default.fileExists(atPath: sharedPreview.path), "the shared temporary folder was swept")
        await model.shutdown()
    }

    @Test("retention runs after the backup and trims the plan's own snapshots")
    func retentionAfterBackup() async throws {
        let harness = try await makeHarness()
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
        // Recommended's rules are the only stored ones; restic 0.19.1 keeps two
        // of three backups made seconds apart under them.
        #expect(model.snapshots(for: harness.repository.id, planID: harness.plan.id).count < 3, "no old backup was removed")

        await model.shutdown()
    }

    @Test("a run against a missing repository is recorded as failed, not silently dropped")
    func failedBackupIsRecorded() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

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
        hook.event = .afterBackup
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
        hook.event = .beforeBackup
        hook.command = "echo 'not today' >&2; exit 1"

        var plan = harness.plan
        plan.hooks = [hook]
        model.upsert(plan: plan)

        model.runBackup(planID: plan.id)
        await model.waitForRun(planID: plan.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.outcome == .failed)
        #expect(record.snapshotID == nil)
        #expect(record.hookMessages.contains { $0.contains("echo") })
        // Hook output must not be filed as a restic warning: that is what gets
        // sent to external notification channels.
        #expect(record.itemErrors.isEmpty)
        // Nothing may have been written to the repository.
        #expect(model.snapshots(for: harness.repository.id, planID: plan.id).isEmpty)
        #expect(model.plan(id: plan.id)?.lastSuccessAt == nil)

        await model.shutdown()
    }

    @Test("a failing after-any hook is recorded but does not undo the backup")
    func failingAfterHookDoesNotFailTheRun() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        var hook = BackupHook()
        hook.event = .afterBackup
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
        #expect(record.hookMessages.contains { $0.contains("exit") && $0.contains("exited 9") })
        #expect(record.itemErrors.isEmpty)
        #expect(model.plan(id: plan.id)?.lastSuccessAt != nil)

        await model.shutdown()
    }

    @Test("quitting during a backup still gets the run onto disk, and records why it stopped")
    func shutdownPersistsInFlightRun() async throws {
        // hang-backup, not hang: after the run ends the model refreshes
        // snapshots and stats, and those must answer instead of running into
        // the refresh timeout.
        let harness = try await makeHarness(stubMode: "hang-backup")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        // The stub backup never finishes on its own, so once its hang shows up
        // in the process table the run is guaranteed still in flight when we
        // quit — no fixed delay to bet on.
        model.runBackup(planID: harness.plan.id)
        let stub = try #require(harness.stub)
        await StubRestic.requireHang(matching: stub.sleepMarker, root: harness.root)

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
        // running into its timeout.
        let harness = try await makeHarness(stubMode: "hang-backup")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        // The cancel must land mid-run, so wait for the stub's sleep child to
        // show up in the process table instead of betting that 300 ms is long
        // enough for a cold first spawn.
        model.runBackup(planID: harness.plan.id)
        let stub = try #require(harness.stub)
        await StubRestic.requireHang(matching: stub.sleepMarker, root: harness.root)
        model.cancelBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.outcome == .cancelled)
        #expect(record.failureMessage == "Stopped")

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

/// One model over a throwaway store: the temp-prefix discipline (never
/// Application Support) lives here, and `directory` goes back so a site
/// that cleans up after itself can.
@MainActor
private func makeModel(
    _ prefix: String,
    secrets: [UUID: (password: String, providerSecret: String?)] = [:]
) -> (model: AppModel, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    return (AppModel(store: ConfigStore(directory: directory), secrets: .inMemory(secrets)), directory)
}

/// The banner queue's contract: an unread error survives the next message,
/// the queue is bounded, and dismissal removes exactly one message.
@Suite("Banner queue")
@MainActor
struct BannerQueueTests {
    @Test("newest first, dismissal by identity")
    func queueSemantics() {
        let model = makeModel("SwiftResticBanners").model
        model.post(Banner(title: "first", message: "", isError: true))
        model.post(Banner(title: "second", message: "", isError: true))
        #expect(model.banners.map(\.title) == ["second", "first"])

        model.dismiss(model.banners[0])
        #expect(model.banners.map(\.title) == ["first"])
    }

    @Test("the queue is bounded so a failure loop cannot stack banners without end")
    func bounded() {
        let model = makeModel("SwiftResticBanners").model
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
        let model = makeModel("SwiftResticBanners").model
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
        let errors = makeModel("SwiftResticBanners").model
        for index in 0 ..< 5 {
            errors.post(Banner(title: "e\(index)", message: "", isError: true))
        }
        #expect(errors.banners.map(\.title) == ["e4", "e3", "e2", "e1"])
    }

    @Test("an error already on screen is not posted again; a changed message is")
    func errorDeduplicates() {
        let model = makeModel("SwiftResticBanners").model
        // A repeatable action failing twice must not stack copies that evict
        // successes — one copy of the same words stays.
        model.post(Banner(title: "same", message: "one", isError: true))
        model.post(Banner(title: "same", message: "one", isError: true))
        #expect(model.banners.map(\.title) == ["same"])
        model.post(Banner(title: "same", message: "two", isError: true))
        #expect(model.banners.count == 2)
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
        let model = makeModel("SwiftResticSnapshotRuns").model
        model.activityHistoryLimit = 20

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
        let (model, directory) = makeModel("SwiftResticListingGenerations")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect((0 ..< 5).map { _ in model.nextListingGeneration() } == [1, 2, 3, 4, 5])
    }
}

/// "The chain's newest backup" for the Files views, read from the listing
/// they show: its first backup of the chain, the listing being newest first.
@Suite("Newest backup of a chain")
@MainActor
struct NewestChainSnapshotTests {
    @Test("the listing's first backup of the chain answers; another chain and another repository have none")
    func newestOfTheChain() throws {
        let model = makeModel("SwiftResticNewestChain").model
        let repositoryID = UUID()
        let plan = namedPlan("Docs", repositoryID: repositoryID)
        let chain = ResticService.planTag(plan.id)
        let older = try snapshotFixture(
            id: String(repeating: "a", count: 64), time: "2026-09-25T18:00:00Z", paths: ["/src"],
            includeShortID: false, hostname: "mac", tags: [chain]
        )
        let newer = try snapshotFixture(
            id: String(repeating: "b", count: 64), time: "2026-09-26T18:00:00Z", paths: ["/src"],
            includeShortID: false, hostname: "mac", tags: [chain]
        )
        model.snapshots[repositoryID] = [newer, older]

        #expect(model.newestSnapshot(inChain: chain, repositoryID: repositoryID)?.id == newer.id)
        #expect(model.newestSnapshot(inChain: "swiftrestic-plan-\(UUID().uuidString)", repositoryID: repositoryID) == nil)
        #expect(model.newestSnapshot(inChain: chain, repositoryID: UUID()) == nil)
    }
}

/// Saving an editor draft must never erase what the model wrote while the
/// sheet was open: the run and maintenance stamps are the scheduler's and the
/// dashboard's ground truth.
@Suite("Editor upsert preserves model-written stamps")
@MainActor
struct UpsertStampTests {
    @Test("a stale plan draft keeps the last-run and last-success stamps")
    func planStampsSurviveStaleUpsert() {
        let model = makeModel("SwiftResticUpsert").model
        var plan = BackupPlan()
        plan.repositoryID = UUID()
        plan.path = "/tmp"

        model.upsert(plan: plan)

        // The model stamps a finished run, the way markPlanRun does.
        let ranAt = Date.now.addingTimeInterval(-600)
        model.configuration.plans[0].lastRunAt = ranAt
        model.configuration.plans[0].lastSuccessAt = ranAt

        // A draft taken before that run is saved with an unrelated edit.
        var staleDraft = plan
        staleDraft.schedule.frequency = .weekly
        model.upsert(plan: staleDraft)

        #expect(model.configuration.plans[0].lastRunAt == ranAt)
        #expect(model.configuration.plans[0].lastSuccessAt == ranAt)
        #expect(model.configuration.plans[0].schedule.frequency == .weekly)
    }

    @Test("a run that wrote a snapshot stamps the last backup; one that wrote nothing stamps only its slot")
    func markPlanRunStampsBackups() {
        let model = makeModel("SwiftResticUpsert").model
        var plan = BackupPlan()
        plan.repositoryID = UUID()
        plan.path = "/Volumes/Archive SSD/Photos"
        model.upsert(plan: plan)

        let whole = Date.now.addingTimeInterval(-3600)
        model.markPlanRun(plan.id, at: whole, wrote: .whole)
        #expect(model.configuration.plans[0].lastRunAt == whole)
        #expect(model.configuration.plans[0].lastSuccessAt == whole)
        let failed = Date.now
        model.markPlanRun(plan.id, at: failed, wrote: .nothing)
        #expect(model.configuration.plans[0].lastRunAt == failed)
        #expect(model.configuration.plans[0].lastSuccessAt == whole)
    }

    @Test("a stale repository draft keeps the check and prune stamps")
    func repositoryStampsSurviveStaleUpsert() async {
        let model = makeModel("SwiftResticUpsert").model
        var repository = Repository()
        repository.kind = .local
        repository.localPath = "/tmp/somewhere"

        await model.upsert(repository: repository, password: nil, providerSecret: nil)

        let checkedAt = Date.now.addingTimeInterval(-3_600)
        model.configuration.repositories[0].maintenance.lastCheckAt = checkedAt
        model.configuration.repositories[0].maintenance.lastPruneAt = checkedAt

        var staleDraft = repository
        staleDraft.uploadLimitKiBps = 512
        await model.upsert(repository: staleDraft, password: nil, providerSecret: nil)

        #expect(model.configuration.repositories[0].maintenance.lastCheckAt == checkedAt)
        #expect(model.configuration.repositories[0].maintenance.lastPruneAt == checkedAt)
        #expect(model.configuration.repositories[0].uploadLimitKiBps == 512)
    }
}

/// The model's pause surface: what the plan menus, the tray and the tick
/// write, and the one hold every display reads.
@Suite("Pausing")
@MainActor
struct PausingTests {
    private func plan(_ name: String) -> BackupPlan {
        var plan = BackupPlan()
        plan.repositoryID = UUID()
        plan.path = "/tmp/" + name
        return plan
    }

    @Test("Pause Backups reaches the model's hold; a lapsed pause clears itself")
    func pauseModelSemantics() {
        let model = makeModel("SwiftResticPausing").model

        #expect(model.scheduleHold == nil)
        model.pauseBackups(for: .untilResumed)
        #expect(model.scheduleHold == .paused(until: nil))
        model.resumeBackups()
        #expect(model.scheduleHold == nil)
        #expect(model.configuration.settings.schedulePause == nil)

        let later = Date.now.addingTimeInterval(7200)
        model.configuration.settings.schedulePause = SchedulePause(until: later.addingTimeInterval(-60))
        model.expireLapsedPauses(now: later)
        #expect(model.configuration.settings.schedulePause == nil)
        // An open-ended pause never lapses.
        model.configuration.settings.schedulePause = SchedulePause(until: nil)
        model.expireLapsedPauses(now: later)
        #expect(model.configuration.settings.schedulePause == SchedulePause(until: nil))
    }

    @Test("a metered network holds only what would use it, and a pause still holds everything")
    func meteredNetworkHoldsNetworkRepositoriesOnly() {
        let model = makeModel("SwiftResticMetered").model
        var disk = Repository()
        disk.kind = .local
        disk.localPath = "/Volumes/Archive SSD/Backups"
        var share = Repository()
        share.kind = .local
        share.localPath = "/Volumes/NAS/Backups"
        var cloud = Repository()
        cloud.kind = .s3
        model.configuration.repositories = [disk, share, cloud]
        model.configuration.settings.networkShares = [NetworkShare(volumeName: "NAS", url: "smb://me@nas.local/NAS")]
        var onDisk = BackupPlan()
        onDisk.repositoryID = disk.id
        onDisk.path = "/Users/someone/Documents"
        model.configuration.plans = [onDisk]

        #expect(model.overallScheduleHold == nil)
        model.isOnMeteredNetwork = true
        #expect(model.scheduleHold == nil, "the tick must still run for a disk on this Mac")
        #expect(model.scheduleHold(repositoryID: disk.id) == nil)
        #expect(model.scheduleHold(repositoryID: share.id) == .onMeteredNetwork)
        #expect(model.scheduleHold(repositoryID: cloud.id) == .onMeteredNetwork)
        // Only the disk has a plan, so nothing the tray could name waits.
        #expect(model.overallScheduleHold == nil)

        var toCloud = onDisk
        toCloud.id = UUID()
        toCloud.repositoryID = cloud.id
        model.configuration.plans = [onDisk, toCloud]
        #expect(model.overallScheduleHold == .onMeteredNetwork)

        model.pauseBackups(for: .untilResumed)
        #expect(model.scheduleHold(repositoryID: disk.id) == .paused(until: nil))
        #expect(model.overallScheduleHold == .paused(until: nil))
    }

}

/// The scheduler lives in the app's process, so a schedule dies with it. What
/// the plan editor and the quit alert say about that, from the model's side.
@Suite("Start at login surfaces")
@MainActor
struct StartAtLoginSurfaceTests {
    private func makeModelWithPlan() -> (model: AppModel, plan: BackupPlan) {
        let model = makeModel("SwiftResticLoginItem").model
        var repository = Repository()
        repository.kind = .local
        repository.localPath = "/Users/someone/NAS"
        var plan = BackupPlan()
        plan.repositoryID = repository.id
        plan.path = "/Users/someone/Documents"
        plan.schedule.frequency = .daily
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan]
        return (model, plan)
    }

    @Test("an idle quit asks only when the user chose it — a quit requested from outside never waits")
    func idleQuitAsksOnlyWhenChosen() throws {
        let (model, plan) = makeModelWithPlan()
        let chosen = try #require(model.quitConfirmation(userChoseQuit: true))
        #expect(!chosen.interruptsWork)
        #expect(chosen.message.contains(model.label(of: plan)))
        #expect(chosen.message.contains("nothing will run until you open it again"))
        // Logout, restart, shutdown, the Dock and AppleScript all arrive as
        // a quit the user did not choose here: an idle app never holds them.
        #expect(model.quitConfirmation(userChoseQuit: false) == nil)

        model.loginItemState = .enabled
        #expect(model.quitConfirmation(userChoseQuit: true) == nil)
        model.loginItemState = .off
        model.configuration.plans[0].schedule.frequency = .manual
        #expect(model.quitConfirmation(userChoseQuit: true) == nil)
    }

    @Test("a scheduled run already overdue is named as due now, not in the past")
    func overdueRunIsDueNow() throws {
        let (model, _) = makeModelWithPlan()
        let now = Date.now
        // Never run: the slot that passed is due, and the pick clamps to now.
        let overdue = try #require(model.quitScheduleNotice(now: now))
        #expect(overdue.hasPrefix("Documents (NAS) is due now."))
        model.configuration.plans[0].lastRunAt = now
        let next = try #require(model.configuration.plans[0].schedule.nextRunDate(after: now, now: now))
        let upcoming = try #require(model.quitScheduleNotice(now: now))
        #expect(upcoming.hasPrefix("Documents (NAS) is next due \(Format.relative(next))."))
        #expect(!upcoming.contains(" ago"))
        // Seconds away is due now too: the relative phrase for it is
        // "just now", and "is next due just now" is no sentence.
        model.configuration.plans[0].schedule.frequency = .hourly
        model.configuration.plans[0].lastRunAt = now.addingTimeInterval(-3600 + 30)
        let imminent = try #require(model.quitScheduleNotice(now: now))
        #expect(imminent.hasPrefix("Documents (NAS) is due now."))
        // A repository called like the plan is not said twice — the tray's
        // rule.
        model.configuration.repositories[0].localPath = "/Users/someone/Backups/Documents"
        let sameName = try #require(model.quitScheduleNotice(now: now))
        #expect(sameName.hasPrefix("Documents is due now."))
    }

    @Test("under a hold the quit sentence names it first, as the tray's line does")
    func quitNoticeNamesTheHold() throws {
        let (model, _) = makeModelWithPlan()
        let now = Date.now
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

        // Only a hold in force at `now` counts.
        model.resumeBackups()
        let clear = try #require(model.quitScheduleNotice(now: now))
        #expect(clear.hasPrefix("Documents (NAS) is due now."))
    }

    @Test("a backup the quit stops has its slot counted as run, as the stop will stamp it")
    func runInFlightIsNotTheMissedRun() throws {
        let (model, plan) = makeModelWithPlan()
        let now = Date.now
        // Due, and running: the quit's cancel stamps the run's start, so
        // this slot is covered and the one missed is the next.
        let startedAt = now.addingTimeInterval(-60)
        model.activity[plan.id] = PlanActivity(of: plan, phase: .backingUp, startedAt: startedAt)
        let next = try #require(model.configuration.plans[0].schedule.nextRunDate(after: startedAt, now: now))
        let running = try #require(model.quitScheduleNotice(now: now))
        #expect(running.hasPrefix("Documents (NAS) is next due \(Format.relative(next))."))
    }
}

/// The login item follows the plans: registered while any plan has a
/// schedule, unregistered once none has, never from outside the
/// Applications folder. The daemon is fake — `SMAppService` would answer
/// for Xcode here.
@Suite("login item")
@MainActor
struct LoginItemSwitchTests {
    /// The fake daemon: each read answers the next scripted state, repeating
    /// the last past the end; each apply is recorded.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var applied: [Bool] = []
        private let states: [LoginItemState]
        private var next = 0

        init(states: [LoginItemState]) {
            self.states = states
        }

        func apply(_ enabled: Bool) throws {
            lock.lock()
            applied.append(enabled)
            lock.unlock()
        }

        func read() -> LoginItemState {
            lock.lock()
            defer { lock.unlock() }
            let answer = states[min(next, states.count - 1)]
            next += 1
            return answer
        }

        var appliedChanges: [Bool] { lock.lock(); defer { lock.unlock() }; return applied }

        /// Wires the fake daemon into the model's seams. On the main actor:
        /// the seams are model state.
        @MainActor
        func install(in model: AppModel) {
            let script = self
            model.loginItemStateReader = { script.read() }
            model.loginItemApplier = { try script.apply($0) }
            // xctest is no app bundle in /Applications; a test that wants the
            // refusal sets the probe back to false.
            model.installableLocationProbe = { true }
        }
    }

    private func scheduledPlan() -> BackupPlan {
        var plan = BackupPlan()
        plan.path = "/tmp/Documents"
        plan.schedule.frequency = .daily
        return plan
    }

    @Test("a scheduled plan registers the login item")
    func registersForScheduledPlan() async {
        let model = makeModel("SwiftResticLoginRegisters").model
        let script = Script(states: [.off, .enabled])
        script.install(in: model)
        model.configuration.plans = [scheduledPlan()]

        await model.reconcileLoginItem()
        #expect(script.appliedChanges == [true])
        #expect(model.loginItemState == .enabled)
        #expect(model.startsAtLogin)
        #expect(model.banners.isEmpty)
    }

    @Test("no scheduled plan unregisters the login item")
    func unregistersWithoutScheduledPlan() async {
        let model = makeModel("SwiftResticLoginUnregisters").model
        let script = Script(states: [.enabled, .off])
        script.install(in: model)

        await model.reconcileLoginItem()
        #expect(script.appliedChanges == [false])
        #expect(model.loginItemState == .off)
        #expect(!model.startsAtLogin)
    }

    @Test("a registration waiting for approval says so")
    func approvalStillOwedIsSaid() async {
        let model = makeModel("SwiftResticLoginApproval").model
        let script = Script(states: [.off, .needsApproval])
        script.install(in: model)
        model.configuration.plans = [scheduledPlan()]

        await model.reconcileLoginItem()
        #expect(script.appliedChanges == [true])
        #expect(model.banners.map(\.title) == ["Approval needed"])
        #expect(model.banners.map(\.message) == [LoginItem.approvalNeeded])
        #expect(model.loginItemState == .needsApproval)
    }

    @Test("outside the Applications folder nothing is registered")
    func neverRegistersOutsideApplications() async {
        let model = makeModel("SwiftResticLoginNotInstalled").model
        let script = Script(states: [.off])
        script.install(in: model)
        model.installableLocationProbe = { false }
        model.configuration.plans = [scheduledPlan()]

        await model.reconcileLoginItem()
        #expect(script.appliedChanges.isEmpty)
        #expect(model.banners.isEmpty)
        #expect(model.loginItemState == .off)
    }

    @Test("a change the daemon refuses posts the banner and still applies the daemon's read")
    func refusedChangeIsSaid() async {
        let model = makeModel("SwiftResticLoginRefused").model
        let script = Script(states: [.enabled])
        script.install(in: model)
        model.loginItemApplier = { _ in throw ResticError.commandFailed(exitCode: 1, message: "daemon refused") }

        await model.reconcileLoginItem()
        #expect(model.banners.map(\.title) == ["Couldn’t change the login item"])
        #expect(model.loginItemState == .enabled)
    }

    @Test("a plan's schedule registers the login item, and the last schedule going unregisters it")
    func followsThePlans() async throws {
        let model = makeModel("SwiftResticLoginFollowsPlans").model
        let script = Script(states: [.off, .enabled, .enabled, .off])
        script.install(in: model)
        // What bootstrap leaves behind: plan edits from here on are the user's.
        model.isLoaded = true

        model.configuration.plans = [scheduledPlan()]
        try #require(await eventually(within: 10) { model.loginItemState == .enabled }, "the schedule never registered")
        #expect(script.appliedChanges == [true])

        model.configuration.plans = []
        try #require(await eventually(within: 10) { model.loginItemState == .off }, "the last schedule never unregistered")
        #expect(script.appliedChanges == [true, false])
    }
}

/// The scheduled check's data rotation: the next slice is moved on by the
/// model's sink alone, wrapping at the slice count, and a repository
/// without a rotation is left alone.
@Suite("check data rotation")
@MainActor
struct CheckDataRotationTests {
    private func makeRotationModel(with policy: MaintenancePolicy) -> (AppModel, UUID) {
        let model = makeModel("SwiftResticRotation").model
        var repository = Repository()
        repository.kind = .local
        repository.maintenance = policy
        model.configuration.repositories = [repository]
        return (model, repository.id)
    }

    private func slice(of model: AppModel, _ id: UUID) -> Int? {
        model.repository(id: id)?.maintenance.nextCheckDataSlice
    }

    @Test("the sink moves the rotation on: 1→2, and 12 wraps to 1")
    func rotationMovesOn() {
        let (local, id) = makeRotationModel(with: MaintenancePolicy())
        #expect(slice(of: local, id) == 1)
        local.advanceCheckDataSlice(repositoryID: id)
        #expect(slice(of: local, id) == 2)

        local.updateRepository(id) { $0.maintenance.nextCheckDataSlice = 12 }
        local.advanceCheckDataSlice(repositoryID: id)
        #expect(slice(of: local, id) == 1)
    }
}

/// A progress hop still in flight when a run unwinds must not write into the
/// next run's strip — the run-identity rule the run tokens give every slot,
/// pinned here at the seam the engines use.
@Suite("Run reporters answer to their own run")
@MainActor
struct RunReporterTokenTests {
    /// Gives a reporter's `Task { @MainActor in … }` the full second to land
    /// before asserting. Not a poll: the hop under test must drop, and an
    /// absence has nothing to poll for, so a wait that ended early could
    /// pass before a wrong write landed.
    private func drainReporterHops() async {
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("a late progress hop from a finished backup never lands in the next run's strip")
    func lateBackupProgressHopDrops() async throws {
        let model = makeModel("SwiftResticRunTokens").model
        let repository = Repository()
        var plan = BackupPlan()
        plan.repositoryID = repository.id
        model.upsert(plan: plan)

        // Run 1: a strip is installed and the engine captures its reporter.
        model.installPlanActivity(plan: plan, repository: repository)
        let reporter = model.progressReporter(planID: plan.id)

        // Run 1 unwinds: token and strip are retired, exactly as the engine
        // task does.
        model.retireRunToken(for: .plan(plan.id))
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
        model.installPlanActivity(plan: plan, repository: repository)
        #expect(model.planProgress[plan.id] == OperationProgress())
        var seed = OperationProgress()
        seed.filesDone = 1
        model.planProgress[plan.id] = seed
        reporter(staleHop)
        await drainReporterHops()
        #expect(model.planProgress[plan.id]?.filesDone == 1)
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
            remove: { _ in },
            loadSharePassword: { _ in nil },
            saveSharePassword: { _, _ in }
        )
        var repository = Repository()
        repository.kind = .local
        repository.localPath = "/tmp/some-repo"

        await #expect(throws: KeychainStore.KeychainError.self) {
            _ = try await AppModel.readContext(for: repository, label: "some-repo", secrets: secrets)
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
            remove: { (_: UUID) in },
            loadSharePassword: { _ in nil },
            saveSharePassword: { _, _ in }
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticKeychainSave-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: ConfigStore(directory: root), secrets: secrets)
        model.isLoaded = true
        model.suppressConfigurationSave = true

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

    @Test("a password the Keychain would not delete with its repository is said, not left behind silently")
    @MainActor
    func failedRemovalIsSaid() async {
        let secrets = SecretStore(
            load: { (_: UUID) in (password: nil, providerSecret: nil) },
            save: { _, _, _ in },
            remove: { (_: UUID) in throw KeychainStore.KeychainError.unexpectedStatus(errSecInteractionNotAllowed) },
            loadSharePassword: { _ in nil },
            saveSharePassword: { _, _ in }
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticKeychainRemove-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: ConfigStore(directory: root), secrets: secrets)
        var repository = Repository()
        repository.kind = .local
        repository.localPath = "/tmp/some-repo"
        model.configuration.repositories = [repository]

        model.deleteRepository(id: repository.id)
        await model.tasks.drain()

        #expect(model.banners.contains { $0.title == "The removed location’s secrets are still in your Keychain" && $0.isError })
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
                var channel = NotificationChannel()
                channel.url = "https://save\(index).invalid"
                model.configuration.settings.notificationChannels = [channel]
                await model.flushSave()
            }
        }
        for save in saves { await save.value }

        let saved = try await ConfigStore(directory: root).load().configuration
        #expect(saved.settings.notificationChannels.map(\.url) == ["https://save3.invalid"])
    }

    @Test("a configuration write that fails is announced, and does not latch the unreadable state")
    func failedSaveIsAnnounced() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticFailedSave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: ConfigStore(directory: root), secrets: .inMemory())
        model.isLoaded = true
        // The store's own directory read-only, so the atomic write fails —
        // the restore defer is registered after the removal defer, so LIFO
        // hands the permissions back before the folder is deleted.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }

        await model.flushSave()
        #expect(model.banners.map(\.title) == ["Couldn’t save your configuration"])
        // Only bootstrap's load failure latches the unreadable state: a
        // failed save leaves the configuration editable and saving armed.
        #expect(!model.isConfigurationUnreadable)
    }
}

extension ConfigurationSaveTests {
    /// The load is held open by its size: a history this long takes the
    /// store far longer to decode than the test takes to edit and flush.
    @Test("an edit made while the configuration is still loading is never saved over it")
    func noSaveBeforeTheLoad() async throws {
        let watchdog = HangWatchdog(seconds: 120, "a load or a flush never returned")
        defer { watchdog.disarm() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticSaveDuringLoad-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var stored = AppConfiguration()
        stored.settings.notifyOnSuccess = true
        stored.runs = (0 ..< 200_000).map { RunRecord(kind: .backup, planName: "Plan \($0)") }
        try await ConfigStore(directory: root).save(stored)

        let model = AppModel(store: ConfigStore(directory: root), secrets: .inMemory())
        let boot = Task { await model.bootstrap() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.configuration.runs.isEmpty, "the load finished before the edit; the test proves nothing")
        model.configuration.settings.notifyOnSuccess = false
        await model.flushSave()
        // Read at once: bootstrap's own saves, if any, are debounced.
        struct Settings: Decodable {
            struct Values: Decodable { let notifyOnSuccess: Bool }
            let settings: Values
        }
        let live = try Data(contentsOf: root.appendingPathComponent("config.json"))
        #expect(try JSONDecoder().decode(Settings.self, from: live).settings.notifyOnSuccess)
        await boot.value
    }
}

@Suite("locating restic")
@MainActor
struct CheckResticTests {
    /// A model whose restic is a script running `body`, in a folder the caller removes.
    private func scriptedModel(running body: String) throws -> (model: AppModel, root: URL) {
        let program = try writeExecutableScript(body, label: "ScriptedBinary", named: "restic")
        let root = program.deletingLastPathComponent()
        return (AppModel(store: ConfigStore(directory: root), secrets: .inMemory(), resticExecutable: program), root)
    }

    private func expectDamaged(_ model: AppModel) {
        #expect(!model.isResticAvailable)
        #expect(model.isResticDamaged)
        #expect(model.resticVersion == "")
        #expect(throws: ResticError.damagedInstall) { try model.service() }
        #expect(ResticError.damagedInstall.localizedDescription == "SwiftRestic is damaged. Install it again.")
    }

    @Test("a bundled restic that is gone is a damaged install, with no search for another")
    func missingHelperIsDamaged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftResticNoHelper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(
            store: ConfigStore(directory: root), secrets: .inMemory(),
            resticExecutable: root.appendingPathComponent("restic")
        )
        await model.checkRestic()
        expectDamaged(model)
    }

    @Test("a bundled restic that cannot answer `restic version` is a damaged install")
    func failedVersionIsDamaged() async throws {
        let (model, root) = try scriptedModel(running: "echo 'not restic' >&2\nexit 1")
        defer { try? FileManager.default.removeItem(at: root) }
        await model.checkRestic()
        expectDamaged(model)
    }

    @Test("an answer that names no restic is a damaged install")
    func unreadableVersionIsDamaged() async throws {
        let (model, root) = try scriptedModel(running: "echo hello")
        defer { try? FileManager.default.removeItem(at: root) }
        await model.checkRestic()
        expectDamaged(model)
    }

    @Test("restic is not in use while its version is asked: the scheduler sees none until it answers")
    func notInUseWhileChecking() async throws {
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftResticSlowVersionGate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: gate) }
        let (model, root) = try scriptedModel(running:
            "while [ ! -e '\(gate.path)' ]; do sleep 0.05; done\necho 'restic 0.19.1 compiled with go1.26.4 on darwin/arm64'")
        defer { try? FileManager.default.removeItem(at: root) }
        let checking = Task { await model.checkRestic() }
        for _ in 0 ..< 40 {
            try await Task.sleep(for: .milliseconds(25))
            #expect(!model.isResticAvailable)
            #expect(!model.isResticDamaged)
        }
        try "".write(to: gate, atomically: true, encoding: .utf8)
        await checking.value
        #expect(model.isResticAvailable)
        #expect(model.resticVersion == "restic 0.19.1 compiled with go1.26.4 on darwin/arm64")
    }

    @Test("a restic path in an old configuration is ignored: nothing on disk can bypass the pinned restic")
    func oldPathOverrideIsIgnored() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticOldOverride-\(UUID().uuidString)-ran")
        let impostor = try writeExecutableScript(
            "touch '\(marker.path)'\necho 'restic 9.9.9 impostor'", label: "OldOverride", named: "restic"
        )
        let root = impostor.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"settings": {"resticPathOverride": "\#(impostor.path)"}}"#
            .write(to: root.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let pinned = try PinnedRestic.binary().url
        let model = AppModel(store: ConfigStore(directory: root), secrets: .inMemory(), resticExecutable: pinned)
        model.loginItemStateReader = { .off }
        await model.bootstrap()
        #expect(model.binary?.url == pinned)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        await model.shutdown()
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
        let (model, root) = makeModel("SwiftResticIndexHome")
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

    private struct Folder {
        var root: URL
        var config: URL
        var repositoryFile: URL
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
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        var configuration = AppConfiguration()
        configuration.repositories = [repository]
        try writeConfiguration(
            configuration, load: load,
            replacing: repository.id.uuidString, with: "not-a-uuid",
            in: config
        )

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

/// The one writer for the three configuration-load states both launch
/// fixtures leave their folder in: which file holds the good copy, what a
/// corrupt live file means, and what a `.substitutedID` replaces — `uuid`
/// and `marker` say, so each suite keeps its own replace rule beside the
/// call.
private func writeConfiguration(
    _ configuration: AppConfiguration,
    load: IndexOrphanSweepLaunchTests.Load?,
    replacing uuid: String,
    with marker: String,
    in config: URL
) throws {
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
        try #require(text.contains(uuid))
        try Data(text.replacingOccurrences(of: uuid, with: marker).utf8).write(to: live)
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
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        func plan(_ name: String, repositoryID: UUID?) -> BackupPlan {
            var plan = BackupPlan()
            plan.repositoryID = repositoryID
            plan.path = root.path
            plan.schedule.frequency = .manual
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
        // The repository's own `id` does not read, so it decodes with a
        // fresh one and the attached plan's id names nothing — the plan
        // the gate exists to keep. The marker targets the `id` field only:
        // a bare replace would also rewrite the plans' copies of it.
        try writeConfiguration(
            configuration, load: load,
            replacing: "\"id\":\"\(repository.id.uuidString)\"", with: "\"id\":\"not-a-uuid\"",
            in: config
        )
        return folder
    }

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
        model.configuration.settings.notifyOnSuccess.toggle()
        await model.flushSave()
        let after = try snapshot()
        #expect(after.names == before.names, "a save changed the configuration files")
        #expect(after.data == before.data, "a save landed over an unreadable configuration's backup copies")
        await model.shutdown()
        let afterShutdown = try snapshot()
        #expect(afterShutdown.names == before.names, "the shutdown flush changed the configuration files")
        #expect(afterShutdown.data == before.data, "the shutdown flush landed over the backup copies")
    }
}

/// The drawer's snapshot link: whether a run's snapshot can still be opened,
/// and why not when it cannot.
@Suite("run snapshot link")
struct RunSnapshotLinkTests {
    private func snapshot(_ id: String) throws -> Snapshot {
        try snapshotFixture(
            id: id, time: "2026-09-25T18:00:00Z", paths: ["/src"], includeShortID: true, hostname: nil, tags: nil
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
        #expect(kept.title == "Restored “Project”")
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
        #expect(replaced.title == "Restored “Project”")
        #expect(replaced.message == "/Users/x/Restored/Project")
        #expect(replaced.revealPaths == ["/Users/x/Restored/Project"])

        // A folder whose every file was already there is still restored:
        // only a single file reads as kept instead.
        let keptFolder = AppModel.restoreBanner(
            itemName: "Project", isDirectory: true, landing: landing,
            summary: summary(restored: 0, skipped: 2), policy: .keepExisting
        )
        #expect(keptFolder.title == "Restored “Project”")
        #expect(keptFolder.message == "/Users/x/Restored/Project\nKept 2 existing files as they were.")

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
        #expect(silent.title == "Restored “a.txt”")
        #expect(silent.message == "/Users/x/Restored/a.txt")
    }

    @Test("the items banner counts what Keep kept, and each item's own folder when there is no shared one")
    func itemsRestoreBannerWording() {
        let landings = [
            URL(fileURLWithPath: "/Users/x/Restored/Project"),
            URL(fileURLWithPath: "/Users/x/Restored/notes.txt"),
        ]
        let directory = URL(fileURLWithPath: "/Users/x/Restored")

        // Everything already there: restic restored nothing, Keep skipped it all.
        let kept = AppModel.itemsRestoreBanner(
            landings: landings, directory: directory,
            summaries: [summary(restored: nil, skipped: 2), summary(restored: nil, skipped: 1)], policy: .keepExisting
        )
        #expect(kept.title == "Kept the existing items")
        #expect(kept.message == "/Users/x/Restored\nThey were already there, so nothing was restored.")
        #expect(kept.revealPaths == landings.map(\.path))
        #expect(!kept.isError)

        // One folder per item — the banner says so instead of naming one.
        let ownFolders = AppModel.itemsRestoreBanner(
            landings: landings, directory: nil,
            summaries: [summary(restored: 1, skipped: nil), summary(restored: 1, skipped: nil)], policy: .keepExisting
        )
        #expect(ownFolders.title == "Restored 2 items")
        #expect(ownFolders.message == "Each item went back to the folder it was backed up from.")
        #expect(ownFolders.revealPaths == landings.map(\.path))

        // A kept file beside the restored ones.
        let mixed = AppModel.itemsRestoreBanner(
            landings: landings, directory: directory,
            summaries: [summary(restored: 1, skipped: 1), summary(restored: nil, skipped: nil)], policy: .keepExisting
        )
        #expect(mixed.title == "Restored 2 items")
        #expect(mixed.message == "/Users/x/Restored\nKept 1 existing file as it was.")

        // Replace: a skipped file already matched the backup, so nothing is said.
        let replaced = AppModel.itemsRestoreBanner(
            landings: [landings[0]], directory: directory,
            summaries: [summary(restored: nil, skipped: 4)], policy: .replaceExisting
        )
        #expect(replaced.title == "Restored 1 item")
        #expect(replaced.message == "/Users/x/Restored")
        #expect(replaced.revealPaths == [landings[0].path])
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
    @Test("a search of all backups names the repository whose index failed, and lists the others' rows")
    func searchAllBackupsNamesTheFailure() async throws {
        let (model, root) = makeModel("SwiftResticSearchAllFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let (home, nas) = (namedRepository("Home"), namedRepository("NAS"))
        model.configuration.repositories = [home, nas]
        await model.indexCoordinator.dropRepository(repositoryID: nas.id)

        let found = await model.searchAllBackups(pattern: "invoice")
        #expect(found.failures.map(\.repositoryID) == [nas.id])
        #expect(found.rows.isEmpty)
        #expect(!found.isWhole)
        await model.shutdown()
    }

    @Test("an index that cannot answer throws, never passes for one still reading")
    func anIndexThatCannotAnswerThrows() async {
        let (model, root) = makeModel("SwiftResticIndexFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = namedRepository("NAS")
        model.configuration.repositories = [repository]
        await model.indexCoordinator.dropRepository(repositoryID: repository.id)
        await #expect(throws: (any Error).self) {
            _ = try await model.indexIsComplete(repositoryID: repository.id)
        }
        await model.shutdown()
    }

    @Test("a listing whose reconcile has not returned is not complete, however complete the index is for the one before")
    func completenessWaitsForTheReconcile() async throws {
        let (model, root) = makeModel("SwiftResticIndexCompleteness")
        defer { try? FileManager.default.removeItem(at: root) }
        // Configured: a reconcile of a repository no longer configured is
        // not counted as taken.
        let repository = namedRepository("NAS")
        model.configuration.repositories = [repository]
        let repositoryID = repository.id

        // The index takes an empty listing: complete for it.
        model.snapshotsGeneration[repositoryID] = 1
        model.indexReconcile(repositoryID: repositoryID, listing: [], generation: 1)
        await model.tasks.drain()
        #expect(try await model.indexIsComplete(repositoryID: repositoryID))

        // A newer listing on screen, its reconcile not yet run.
        model.snapshotsGeneration[repositoryID] = 2
        #expect(try await !model.indexIsComplete(repositoryID: repositoryID))

        model.indexReconcile(repositoryID: repositoryID, listing: [], generation: 2)
        await model.tasks.drain()
        #expect(try await model.indexIsComplete(repositoryID: repositoryID))
        await model.shutdown()
    }

    @Test("Rebuild Search Index: the thrown-away store takes the listing again and is complete once more")
    func rebuildIndexLandsTheListingAgain() async throws {
        let (model, root) = makeModel("SwiftResticRebuild")
        defer { try? FileManager.default.removeItem(at: root) }
        // Configured, as the hatch's own path checks: a reconcile of a
        // repository no longer configured is not counted as taken.
        let repository = namedRepository("NAS")
        model.configuration.repositories = [repository]
        let repositoryID = repository.id

        // The wiring the rebuild rides on: the listing lands, its generation
        // is taken, the index is complete.
        model.snapshotsGeneration[repositoryID] = 5
        model.indexReconcile(repositoryID: repositoryID, listing: [], generation: 5)
        await model.tasks.drain()
        #expect(try await model.indexIsComplete(repositoryID: repositoryID))

        // The state the hatch exists for: the store thrown away, nothing
        // applied since — no listing, so not complete.
        await model.indexCoordinator.resetRepository(repositoryID: repositoryID)
        #expect(try await !model.indexIsComplete(repositoryID: repositoryID))

        model.rebuildIndex(repositoryID: repositoryID)
        await model.tasks.drain()
        #expect(try await model.indexIsComplete(repositoryID: repositoryID), "the rebuilt index never took the listing again")
        #expect(model.indexTakenGeneration[repositoryID] == 5)
        // Rebuilt under the listing's own number: a refresh read before it,
        // whose reconcile lands late, is still refused.
        let staleTaken = await model.indexCoordinator.reconcile(repositoryID: repositoryID, snapshots: [], generation: 4)
        #expect(!staleTaken, "the rebuilt index took a listing older than the one it was rebuilt from")
        await model.shutdown()
    }
}

/// The "Items kept in Activity" cap and what a standing problem still reads:
/// the trim drops the oldest records by count, except the ones a standing
/// surface would lose its problem with.
@Suite("Run history trim")
@MainActor
struct RunHistoryTrimTests {
    private func model() -> AppModel {
        let model = makeModel("SwiftResticTrim").model
        model.activityHistoryLimit = 20
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
        #expect(model.configuration.runs.first?.planID == busy)
        #expect(model.configuration.runs.last?.id == standing.id)

        // Healed, it trims like any other record.
        model.append(record: run(.backup, plan: stuck, .succeeded, hoursAgo: 0))
        model.append(record: run(.backup, plan: busy, .succeeded, hoursAgo: 0))
        #expect(!model.configuration.runs.contains { $0.id == standing.id })
        #expect(model.currentProblem(for: stuck) == nil)
    }
}
