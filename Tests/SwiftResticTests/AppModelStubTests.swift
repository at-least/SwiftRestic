import Foundation
import Network
import Testing

/// Drives `AppModel` against the stub restic binary, so the model-level glue
/// the integration suite cannot reach — restore bookkeeping, refresh error
/// paths, the run-history cap, the console, unlock, deletion, notification
/// wiring — is exercised on every machine, not only where restic is installed.
@MainActor
@Suite("AppModel with stub restic", .serialized)
struct AppModelStubTests {
    private struct Harness {
        var model: AppModel
        var root: URL
        var repository: Repository
        var plan: BackupPlan
        var stub: StubRestic
    }

    /// A model wired to the stub through the same `resticPathOverride` the
    /// Settings screen uses. No repository is ever initialised: the stub
    /// answers whatever the model asks.
    private func makeHarness(
        mode: String,
        password: String? = "test-password",
        maxRunHistory: Int? = nil,
        planHooks: [BackupHook] = [],
        channels: [NotificationChannel] = []
    ) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticStubModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stub = try StubRestic.install(in: root)

        var repository = Repository()
        repository.name = "Stub Repo"
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        repository.extraEnvironment = [
            "SWIFTRESTIC_STUB": mode,
            // Where the stub logs which lines of itself actually ran.
            "SWIFTRESTIC_TRACE": root.appendingPathComponent("stub-trace.log").path,
        ]

        var plan = BackupPlan()
        plan.name = "Stub Plan"
        plan.repositoryID = repository.id
        plan.sources = [root.path]
        // Manual, so only the test decides when a backup happens and the
        // scheduler's 60 s tick cannot inject one mid-assertion.
        plan.schedule.frequency = .manual
        plan.hooks = planHooks

        var configuration = AppConfiguration()
        configuration.repositories = [repository]
        configuration.plans = [plan]
        configuration.settings.resticPathOverride = stub.url.path
        configuration.settings.notificationChannels = channels
        if let maxRunHistory { configuration.settings.maxRunHistory = maxRunHistory }

        let store = ConfigStore(directory: root.appendingPathComponent("config"))
        try await store.save(configuration)

        // No entry in the dictionary is how a repository with no stored
        // password is expressed.
        var secrets: [UUID: (password: String, providerSecret: String?)] = [:]
        if let password { secrets[repository.id] = (password: password, providerSecret: nil) }
        let model = AppModel(store: store, secrets: .inMemory(secrets))
        await model.bootstrap()

        return Harness(model: model, root: root, repository: repository, plan: plan, stub: stub)
    }

    /// `bootstrap()` awaits the first snapshot refresh, so by the time the
    /// harness returns, the repository has settled and any refresh banner is
    /// already up.
    private func bannerTitled(
        _ fragment: String,
        in model: AppModel,
        within seconds: TimeInterval = 10
    ) async -> Banner? {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if let banner = model.banners.first(where: { $0.title.contains(fragment) }) {
                return banner
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return model.banners.first(where: { $0.title.contains(fragment) })
    }

    /// Restores run as detached tasks with no `waitFor` API; watch the flag.
    private func waitUntilRestoreFinishes(in model: AppModel, within seconds: TimeInterval = 10) async {
        let deadline = Date.now.addingTimeInterval(seconds)
        while model.isRestoring, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Restore

    @Test("restoring a file writes the dump, records the run and surfaces a banner")
    func restoringFileSucceeds() async throws {
        let harness = try await makeHarness(mode: "default")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let node = try ResticMessageDecoder.jsonDecoder.decode(
            SnapshotNode.self,
            from: Data(#"{"name":"a.txt","type":"file","path":"/src/a.txt","size":12}"#.utf8)
        )
        let destination = harness.root.appendingPathComponent("restored")
        harness.model.restore(
            repositoryID: harness.repository.id,
            snapshotID: "latest",
            node: node,
            to: destination
        )
        await waitUntilRestoreFinishes(in: harness.model)

        let record = try #require(harness.model.configuration.runs.first)
        #expect(record.kind == .restore)
        #expect(record.outcome == .succeeded)
        #expect(record.bytesProcessed == 12)
        #expect(harness.model.banners.first?.title == "Restored a.txt")
        #expect(
            try String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8)
                .contains("[]"),
            "the dump target did not receive the stub's stdout"
        )

        await harness.model.shutdown()
    }

    @Test("a failing restore is recorded and names the failure in a banner")
    func restoringFailureIsRecorded() async throws {
        let harness = try await makeHarness(mode: "plainfail")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let node = SnapshotNode(name: "a.txt", type: .file, path: "/src/a.txt")
        harness.model.restore(
            repositoryID: harness.repository.id,
            snapshotID: "latest",
            node: node,
            to: harness.root.appendingPathComponent("restored")
        )
        await waitUntilRestoreFinishes(in: harness.model)

        let record = try #require(harness.model.configuration.runs.first)
        #expect(record.kind == .restore)
        #expect(record.outcome == .failed)
        #expect(record.failureMessage != nil)
        #expect(harness.model.banners.first?.title == "Restore failed")

        await harness.model.shutdown()
    }

    @Test("cancelling a restore stops the child and records a user cancellation")
    func cancellingRestoreIsRecorded() async throws {
        // hang-restore hangs only the restore/dump command, so launch-time
        // snapshot refreshes still answer.
        let harness = try await makeHarness(mode: "hang-restore")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let node = SnapshotNode(name: "a.txt", type: .file, path: "/src/a.txt")
        harness.model.restore(
            repositoryID: harness.repository.id,
            snapshotID: "latest",
            node: node,
            to: harness.root.appendingPathComponent("restored")
        )

        // The hang is what guarantees the cancel lands mid-run, so wait for it
        // in the process table rather than betting on a fixed delay.
        let hangDeadline = Date.now.addingTimeInterval(10)
        while Date.now < hangDeadline,
              StubRestic.findProcesses(matching: harness.stub.sleepMarker).isEmpty {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if StubRestic.findProcesses(matching: harness.stub.sleepMarker).isEmpty {
            let trace = (try? String(
                contentsOf: harness.root.appendingPathComponent("stub-trace.log"),
                encoding: .utf8
            )) ?? "no trace"
            Issue.record("the stub never established its hang; trace: [\(trace)]")
        }
        harness.model.cancelRestore()
        await waitUntilRestoreFinishes(in: harness.model)

        let record = try #require(harness.model.configuration.runs.first)
        #expect(record.outcome == .cancelled)
        #expect(record.failureMessage == "Cancelled")
        #expect(
            await StubRestic.processVanishes(matching: harness.stub.sleepMarker, within: 10),
            "the stub process outlived the cancelled restore"
        )

        await harness.model.shutdown()
    }

    // MARK: - Snapshot refresh error paths

    @Test("a repository with no password is flagged, and supplying one clears it")
    func missingPasswordIsFlagged() async throws {
        let harness = try await makeHarness(mode: "default", password: nil)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        // Expected before the first password exists, so no banner — but the
        // sidebar must know the repository is not set up yet.
        #expect(harness.model.repositoriesMissingPassword == [harness.repository.id])
        #expect(harness.model.snapshots(for: harness.repository.id).isEmpty)
        #expect(harness.model.banners.isEmpty)

        await harness.model.upsert(
            repository: harness.repository,
            password: "new-password",
            providerSecret: nil
        )
        #expect(harness.model.repositoriesMissingPassword.isEmpty)

        await harness.model.shutdown()
    }

    @Test("an uninitialised repository reads as empty, without an error banner")
    func uninitialisedRepositoryIsQuiet() async throws {
        let harness = try await makeHarness(mode: "missing")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        // Exit code 10 is restic saying "nothing here yet" — a normal state
        // between adding a repository and its first init, not a failure.
        #expect(harness.model.snapshots(for: harness.repository.id).isEmpty)
        #expect(harness.model.banners.isEmpty)
        #expect(harness.model.repositoriesMissingPassword.isEmpty)

        await harness.model.shutdown()
    }

    @Test("an unexpected refresh failure surfaces a banner naming the repository")
    func refreshFailureSurfacesBanner() async throws {
        let harness = try await makeHarness(mode: "plainfail")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let banner = try #require(harness.model.banners.first, "a broken repository must surface a banner")
        #expect(banner.isError)
        #expect(banner.title.contains("Could not read"))
        #expect(banner.title.contains("Stub Repo"))
        #expect(harness.model.snapshots(for: harness.repository.id).isEmpty)

        await harness.model.shutdown()
    }

    // MARK: - Snapshot listing states

    @Test("a successful refresh settles the listing as loaded and stamps freshness")
    func successfulRefreshSettlesLoaded() async throws {
        let harness = try await makeHarness(mode: "snaprows")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        #expect(harness.model.snapshotListingOutcome(for: harness.repository.id) == .loaded)
        #expect(harness.model.snapshotsLoadedAt(for: harness.repository.id) != nil)
        #expect(harness.model.snapshots(for: harness.repository.id).count == 1)

        await harness.model.shutdown()
    }

    @Test("a missing password settles the listing as failed, without a banner")
    func missingPasswordSettlesFailed() async throws {
        let harness = try await makeHarness(mode: "snaprows", password: nil)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        guard case let .failed(message) = harness.model.snapshotListingOutcome(for: harness.repository.id) else {
            Issue.record("expected a failed listing outcome, got \(harness.model.snapshotListingOutcome(for: harness.repository.id))")
            return
        }
        #expect(message.contains("password"))
        #expect(harness.model.banners.isEmpty, "a missing password is a normal state, not an error banner")
        #expect(harness.model.snapshotsLoadedAt(for: harness.repository.id) == nil)

        await harness.model.shutdown()
    }

    @Test("an uninitialised repository settles as loaded and empty")
    func uninitialisedSettlesLoadedEmpty() async throws {
        let harness = try await makeHarness(mode: "missing")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        #expect(harness.model.snapshotListingOutcome(for: harness.repository.id) == .loaded)
        #expect(harness.model.snapshots(for: harness.repository.id).isEmpty)
        #expect(harness.model.banners.isEmpty)

        await harness.model.shutdown()
    }

    @Test("a failed refresh keeps the last successful listing and its freshness stamp")
    func failedRefreshKeepsStaleListing() async throws {
        let harness = try await makeHarness(mode: "snaprows")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let loadedAt = try #require(harness.model.snapshotsLoadedAt(for: harness.repository.id))
        #expect(harness.model.snapshots(for: harness.repository.id).count == 1)

        // Flip the stub to failing and refresh again through the same path a
        // Retry button takes.
        var broken = harness.repository
        broken.extraEnvironment["SWIFTRESTIC_STUB"] = "plainfail"
        await harness.model.upsert(repository: broken, password: nil, providerSecret: nil)
        await harness.model.refreshSnapshots(repositoryID: harness.repository.id)

        guard case let .failed(message) = harness.model.snapshotListingOutcome(for: harness.repository.id) else {
            Issue.record("expected a failed outcome after the broken refresh")
            return
        }
        #expect(message.contains("config file"))
        #expect(harness.model.snapshots(for: harness.repository.id).count == 1, "stale rows must survive a failed refresh")
        #expect(harness.model.snapshotsLoadedAt(for: harness.repository.id) == loadedAt, "freshness is the last success, not the last attempt")

        await harness.model.shutdown()
    }

    @Test("a repository that vanishes after listing fails instead of reading as empty")
    func vanishedRepositoryKeepsStaleListing() async throws {
        let harness = try await makeHarness(mode: "snaprows")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        #expect(harness.model.snapshots(for: harness.repository.id).count == 1)
        let loadedAt = try #require(harness.model.snapshotsLoadedAt(for: harness.repository.id))

        // restic's exit 10 ("does not exist") against a repository that has
        // listed before: an unmounted volume or moved folder, not an empty
        // repository.
        var vanished = harness.repository
        vanished.extraEnvironment["SWIFTRESTIC_STUB"] = "missing"
        await harness.model.upsert(repository: vanished, password: nil, providerSecret: nil)
        await harness.model.refreshSnapshots(repositoryID: harness.repository.id)

        guard case let .failed(message) = harness.model.snapshotListingOutcome(for: harness.repository.id) else {
            Issue.record("expected a failed outcome for a vanished repository, got \(harness.model.snapshotListingOutcome(for: harness.repository.id))")
            return
        }
        #expect(message.contains("missing"))
        #expect(harness.model.snapshots(for: harness.repository.id).count == 1, "stale rows must survive")
        #expect(harness.model.snapshotsLoadedAt(for: harness.repository.id) == loadedAt)

        await harness.model.shutdown()
    }

    @Test("a refresh that outlives its repository settles nothing")
    func refreshAfterDeletionSettlesNothing() async throws {
        // "missing" answers exit 10 quickly, but the refresh can still race a
        // deletion: whichever way the command lands, the removed repository
        // must come back with no rows, no outcome and no banner.
        let harness = try await makeHarness(mode: "missing")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.model.deleteRepository(id: harness.repository.id)
        await harness.model.refreshSnapshots(repositoryID: harness.repository.id)

        #expect(harness.model.snapshots(for: harness.repository.id).isEmpty)
        #expect(harness.model.snapshotListingOutcome(for: harness.repository.id) == .idle)
        #expect(harness.model.banners.isEmpty)

        await harness.model.shutdown()
    }

    @Test("deleting a repository clears its listing state")
    func deletingRepositoryClearsListingState() async throws {
        let harness = try await makeHarness(mode: "snaprows")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.model.deleteRepository(id: harness.repository.id)

        #expect(harness.model.snapshotListingOutcome(for: harness.repository.id) == .idle)
        #expect(harness.model.snapshotsLoadedAt(for: harness.repository.id) == nil)

        await harness.model.shutdown()
    }

    // MARK: - Run history

    @Test("the run history is capped at twenty even when every run succeeds")
    func runHistoryIsCapped() async throws {
        // maxRunHistory only raises the floor of 20, so 5 is still capped at 20.
        let harness = try await makeHarness(mode: "default", maxRunHistory: 5)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        for _ in 0 ..< 22 {
            harness.model.runBackup(planID: harness.plan.id)
            await harness.model.waitForRun(planID: harness.plan.id)
        }

        #expect(harness.model.configuration.runs.count == 20)
        #expect(harness.model.configuration.runs.allSatisfy { $0.outcome == .succeeded })

        await harness.model.shutdown()
    }

    // MARK: - Quit confirmation and run banners

    @Test("a backup in flight is a reason to confirm quitting; an idle model has none")
    func runningBackupAsksForQuitConfirmation() async throws {
        let harness = try await makeHarness(mode: "hang-backup")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        #expect(harness.model.quitInterruptions.isEmpty)
        harness.model.runBackup(planID: harness.plan.id)
        #expect(harness.model.isRunning(planID: harness.plan.id))
        #expect(harness.model.quitInterruptions == ["A backup is running"])

        harness.model.cancelBackup(planID: harness.plan.id)
        await harness.model.waitForRun(planID: harness.plan.id)
        #expect(harness.model.quitInterruptions.isEmpty)

        await harness.model.shutdown()
    }

    @Test("a finished backup announces its outcome in the banner queue")
    func finishedBackupAnnouncesItself() async throws {
        let harness = try await makeHarness(mode: "default")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.model.runBackup(planID: harness.plan.id)
        await harness.model.waitForRun(planID: harness.plan.id)

        let banner = try #require(harness.model.banners.first)
        #expect(!banner.isError)
        #expect(banner.title.contains("Stub Plan"))
        #expect(banner.message.contains("Backed up"))
        // A settled run is not a reason to interject on quit.
        #expect(harness.model.quitInterruptions.isEmpty)

        await harness.model.shutdown()
    }

    @Test("a backup with unreadable items surfaces them without calling the run a failure")
    func backupWithWarningsSurfacesThem() async throws {
        let harness = try await makeHarness(mode: "warn")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.model.runBackup(planID: harness.plan.id)
        await harness.model.waitForRun(planID: harness.plan.id)

        let record = try #require(harness.model.configuration.runs.first)
        #expect(record.outcome == .completedWithErrors)
        let banner = try #require(harness.model.banners.first)
        #expect(banner.isError)
        #expect(banner.title.contains("finished with warnings"))
        #expect(banner.message.contains("unreadable item"))

        await harness.model.shutdown()
    }

    @Test("a failed backup names the failure in a banner")
    func failedBackupNamesTheFailure() async throws {
        let harness = try await makeHarness(mode: "plainfail")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.model.runBackup(planID: harness.plan.id)
        await harness.model.waitForRun(planID: harness.plan.id)

        let record = try #require(harness.model.configuration.runs.first)
        #expect(record.outcome == .failed)
        let banner = try #require(harness.model.banners.first)
        #expect(banner.isError)
        #expect(banner.title.contains("failed"))
        #expect(banner.message.contains(record.failureMessage ?? ""))

        await harness.model.shutdown()
    }

    // MARK: - Console

    @Test("the console returns restic's own output, or explains there is nothing")
    func consoleOutput() async throws {
        let harness = try await makeHarness(mode: "default")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let output = await harness.model.runConsoleCommand(
            repositoryID: harness.repository.id,
            arguments: ["snapshots", "--compact"]
        )
        #expect(output == "[]")

        let unknown = await harness.model.runConsoleCommand(
            repositoryID: UUID(),
            arguments: ["snapshots"]
        )
        #expect(unknown == "No such repository.")

        await harness.model.shutdown()
    }

    @Test("a console command that fails still shows restic's words and its exit code")
    func consoleFailureShowsExitCode() async throws {
        let harness = try await makeHarness(mode: "plainfail")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        // The console never throws: whatever restic said, the user reads.
        let output = await harness.model.runConsoleCommand(
            repositoryID: harness.repository.id,
            arguments: ["snapshots"]
        )
        #expect(output.contains("unable to open config file"))
        #expect(output.contains("[exit 17]"))

        await harness.model.shutdown()
    }

    // MARK: - Unlock

    @Test("unlocking a repository confirms with a banner")
    func unlockSuccess() async throws {
        let harness = try await makeHarness(mode: "default")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.model.unlockRepository(id: harness.repository.id)
        let banner = await bannerTitled("Removed stale locks", in: harness.model)
        #expect(banner?.title.contains("Removed stale locks") == true, "banner was: \(banner?.title ?? "none")")

        await harness.model.shutdown()
    }

    @Test("a failed unlock says so instead of staying silent")
    func unlockFailure() async throws {
        let harness = try await makeHarness(mode: "plainfail")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.model.unlockRepository(id: harness.repository.id)
        let banner = await bannerTitled("Unlock failed", in: harness.model)
        #expect(banner?.title.contains("Unlock failed") == true, "banner was: \(banner?.title ?? "none")")
        #expect(banner?.isError == true)

        await harness.model.shutdown()
    }

    // MARK: - Deletion

    @Test("deleting a repository detaches and disables its plans")
    func deletingRepositoryDisablesPlans() async throws {
        let harness = try await makeHarness(mode: "default")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.model.deleteRepository(id: harness.repository.id)

        #expect(harness.model.configuration.repositories.isEmpty)
        // The plan survives but must never run against a repository the app no
        // longer knows.
        let plan = try #require(harness.model.plan(id: harness.plan.id))
        #expect(plan.repositoryID == nil)
        #expect(!plan.isEnabled)
        #expect(harness.model.snapshots(for: harness.repository.id).isEmpty)

        await harness.model.shutdown()
    }

    @Test("deleting a running plan cancels the run and keeps the record")
    func deletingRunningPlanCancelsAndRecords() async throws {
        let harness = try await makeHarness(mode: "hang-backup")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        // runBackup registers the activity synchronously before returning, so
        // the run is guaranteed in flight against the never-finishing stub.
        harness.model.runBackup(planID: harness.plan.id)
        #expect(harness.model.isRunning(planID: harness.plan.id))
        harness.model.deletePlan(id: harness.plan.id)
        await harness.model.waitForRun(planID: harness.plan.id)

        #expect(harness.model.plan(id: harness.plan.id) == nil)
        // The history keeps what already happened: a cancelled run, not a
        // disappearance.
        let record = try #require(harness.model.configuration.runs.first)
        #expect(record.outcome == .cancelled)
        #expect(record.failureMessage == "Cancelled")

        await harness.model.shutdown()
    }

    // MARK: - Notification wiring

    @Test("the webhook gets restic's warnings and never a hook's output")
    func broadcastWiring() async throws {
        // One-shot loopback HTTP server: whatever actually leaves the app
        // lands here, so the guarantee can be asserted against the wire.
        let server = try #require(HTTPCaptureServer(), "could not start the capture listener")
        defer { server.stop() }
        server.start()
        // The port only exists once the listener is ready; poll for it.
        let readyDeadline = Date.now.addingTimeInterval(5)
        while server.port == 0, Date.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let port = server.port
        #expect(port != 0, "the capture listener never became ready")

        var leaky = BackupHook()
        leaky.name = "leaky"
        leaky.event = .afterAny
        leaky.command = "echo 'Authorization: Bearer hook-secret-token' >&2; exit 1"

        var good = NotificationChannel()
        good.name = "Capture"
        good.kind = .webhook
        good.url = "http://127.0.0.1:\(port)/hook"
        // A second channel nothing is listening on: its failure must surface
        // without disturbing the delivered payload.
        var dead = NotificationChannel()
        dead.name = "Dead"
        dead.kind = .webhook
        dead.url = "http://127.0.0.1:1/hook"

        let harness = try await makeHarness(mode: "warn", planHooks: [leaky], channels: [good, dead])
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.model.runBackup(planID: harness.plan.id)
        await harness.model.waitForRun(planID: harness.plan.id)

        var bodies: [String] = []
        let bodyDeadline = Date.now.addingTimeInterval(5)
        while bodies.isEmpty, Date.now < bodyDeadline {
            bodies = server.captured
            if bodies.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        }
        let body = try #require(bodies.first, "no webhook payload ever arrived")

        // The precondition that makes the negative assertions below mean
        // anything: the hook really ran and its output really was captured
        // in-process. Without this, a regression that stopped running afterAny
        // hooks would make the token vanish everywhere and the assertions
        // would pass vacuously.
        let record = try #require(harness.model.configuration.runs.first)
        #expect(
            record.hookMessages.contains { $0.contains("hook-secret-token") },
            "the afterAny hook never ran: \(record.hookMessages)"
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
            "payload was not the webhook's JSON object: \(body)"
        )
        #expect(object["stage"] as? String == "warned")
        #expect(object["plan"] as? String == "Stub Plan")
        let warnings = object["warnings"] as? [String] ?? []
        #expect(
            warnings.contains { $0.contains("/etc/secret-target") },
            "restic's own warning did not reach the channel: \(warnings)"
        )
        // The security half of the guarantee: the hook's stderr — including the
        // fake credential it printed — must not leave the machine.
        #expect(!body.contains("hook-secret-token"), "hook output reached the webhook: \(body)")
        #expect(!body.contains("leaky"), "the hook's name reached the webhook: \(body)")

        // The unreachable channel must be reported, not dropped on the floor.
        // This reads the final banner: it names broadcast's failure only
        // because finish() broadcasts after the refresh step (whose own
        // "Could not read" banner this stub mode also sets) and waitForRun
        // awaited all of it — reordering those steps changes what lands here.
        #expect(
            harness.model.banners.contains { $0.title.contains("Could not send") } == true,
            "banners were: \(harness.model.banners.map(\.title))"
        )

        await harness.model.shutdown()
    }
}

/// Captures HTTP request bodies on the loopback interface.
///
/// Built for one small POST per test: it answers `200` with an empty body and
/// closes the connection, collecting whatever arrived.
private final class HTTPCaptureServer: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SwiftResticTests.http-capture")

    /// Nil until the listener is ready — poll `port` instead of reading early.
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    var captured: [String] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }

    init?() {
        let parameters = NWParameters.tcp
        // Pin the loopback IPv4 address so 127.0.0.1 is always the thing
        // listening, whatever the host's interface configuration.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            // A connection receives nothing until it is started on a queue.
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let (bodyStart, contentLength) = Self.requestBounds(accumulated),
               accumulated.count >= bodyStart + contentLength {
                let body = String(data: accumulated.suffix(contentLength), encoding: .utf8) ?? ""
                self?.lock.lock()
                self?.bodies.append(body)
                self?.lock.unlock()
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }

            if error == nil, !isComplete {
                self?.receive(on: connection, buffer: accumulated)
            } else {
                connection.cancel()
            }
        }
    }

    /// Locates where the body starts and how long the headers say it is.
    private static func requestBounds(_ data: Data) -> (bodyStart: Int, contentLength: Int)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headers = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        let length = headers
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { line -> Int? in
                guard let value = line.split(separator: ":").last else { return nil }
                return Int(value.trimmingCharacters(in: .whitespaces))
            } ?? 0
        return (headerEnd.upperBound - data.startIndex, length)
    }
}
