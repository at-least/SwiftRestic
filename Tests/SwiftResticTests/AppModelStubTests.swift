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
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticStubModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Same canonical root the real-restic harness resolves to: paths here
        // reach the configuration as-is, and `/tmp` is a symlink to
        // `/private/tmp` — an unresolved root would spell every path
        // differently from what the model itself resolves, for no reason the
        // stub needs.
        let root = base.resolvingSymlinksInPath()
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
            to: destination,
            overwrite: .replaceExisting
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

    @Test("a restored file with no known size records the bytes actually written")
    func restoredFileWithoutSizeRecordsWrittenBytes() async throws {
        let harness = try await makeHarness(mode: "default")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        // The shape the Restore pane's search hits build: the index knows a
        // path and a kind, never a size.
        let node = try ResticMessageDecoder.jsonDecoder.decode(
            SnapshotNode.self,
            from: Data(#"{"name":"a.txt","type":"file","path":"/src/a.txt"}"#.utf8)
        )
        #expect(node.size == nil)
        harness.model.restore(
            repositoryID: harness.repository.id,
            snapshotID: "latest",
            node: node,
            to: harness.root.appendingPathComponent("restored"),
            overwrite: .replaceExisting
        )
        await waitUntilRestoreFinishes(in: harness.model)

        let record = try #require(harness.model.configuration.runs.first)
        #expect(record.outcome == .succeeded)
        // The default arm's dump writes "[]\n": three bytes landed.
        #expect(record.bytesProcessed == 3)

        await harness.model.shutdown()
    }

    @Test("a keep-existing restore asks restic for --overwrite never and says what it kept")
    func keepExistingRestoreSaysWhatItKept() async throws {
        let harness = try await makeHarness(mode: "restoreskip")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        // The stub calls itself 0.0.0, which predates --overwrite (0.17); the
        // flag under test is the one a current restic gets.
        harness.model.resticVersion = "restic 0.19.1 compiled with go1.26.5 on darwin/arm64"

        let node = SnapshotNode(name: "Project", type: .dir, path: "/src/Project")
        let destination = harness.root.appendingPathComponent("restored")
        harness.model.restore(
            repositoryID: harness.repository.id,
            snapshotID: "latest",
            node: node,
            to: destination,
            overwrite: .keepExisting
        )
        await waitUntilRestoreFinishes(in: harness.model)

        let trace = try String(
            contentsOf: harness.root.appendingPathComponent("stub-trace.log"),
            encoding: .utf8
        )
        // The repository travels in the environment, so `restore` can be the
        // first argument, right after the bracket.
        let restoreStart = trace.split(separator: "\n").first { line in
            line.hasPrefix("start args=[") && line.replacingOccurrences(of: "[", with: " ").contains(" restore ")
        }
        #expect(restoreStart?.contains("--overwrite never") == true, "restore started as: \(restoreStart ?? "nothing")")

        let landing = destination.appendingPathComponent("Project")
        let banner = try #require(harness.model.banners.first)
        #expect(banner.title == "Restored Project")
        #expect(banner.message.contains("Kept 3 existing files as they were."), "banner said: \(banner.message)")
        #expect(banner.revealPath == landing.path)
        let record = try #require(harness.model.configuration.runs.first)
        #expect(record.filesSkipped == 3)

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
            to: harness.root.appendingPathComponent("restored"),
            overwrite: .replaceExisting
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
            to: harness.root.appendingPathComponent("restored"),
            overwrite: .replaceExisting
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
        // The strip vanishing is not the whole story: a settled, non-error
        // banner says the restore stopped and nothing is still running.
        let cancelledBanner = await bannerTitled("Restore cancelled", in: harness.model)
        #expect(
            cancelledBanner?.isError == false,
            "banners were: \(harness.model.banners.map(\.title))"
        )
        #expect(
            await StubRestic.processVanishes(matching: harness.stub.sleepMarker, within: 10),
            "the stub process outlived the cancelled restore"
        )

        await harness.model.shutdown()
    }

    @Test("a late restore-progress hop after the run unwound is dropped")
    func lateRestoreProgressHopIsDropped() async throws {
        // hang-restore hangs only the restore/dump command, so launch-time
        // snapshot refreshes still answer.
        let harness = try await makeHarness(mode: "hang-restore")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let node = SnapshotNode(name: "a.txt", type: .file, path: "/src/a.txt")
        harness.model.restore(
            repositoryID: harness.repository.id,
            snapshotID: "latest",
            node: node,
            to: harness.root.appendingPathComponent("restored"),
            overwrite: .replaceExisting
        )
        #expect(
            await StubRestic.waitForHang(matching: harness.stub.sleepMarker, within: 10),
            "the stub never established its hang"
        )

        // The reporter this run built, captured while the run is still live.
        let runReporter = harness.model.restoreProgressReporter()

        harness.model.cancelRestore()
        await waitUntilRestoreFinishes(in: harness.model)
        #expect(!harness.model.isRestoring)

        // The hop that was in flight when the unwind ran must not resurrect
        // the strip — a resurrected restoreActivity sticks forever: nothing
        // else clears it, quit always claims a restore is running, and the
        // restore buttons stay disabled.
        runReporter(OperationProgress())
        let settle = Date.now.addingTimeInterval(1)
        while Date.now < settle { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(!harness.model.isRestoring, "a late hop resurrected the restore strip")

        // Positive control: a reporter built after the unwind — for whatever
        // run comes next — still writes.
        let freshReporter = harness.model.restoreProgressReporter()
        freshReporter(OperationProgress())
        let wrote = Date.now.addingTimeInterval(2)
        while Date.now < wrote, !harness.model.isRestoring {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(harness.model.isRestoring)
        // Slot-less tidy: no restore is actually running; leave the model
        // clean for shutdown.
        harness.model.restoreActivity = nil

        await harness.model.shutdown()
    }

    // MARK: - Snapshot refresh error paths

    @Test("a refresh asked while another is running runs after it, not never")
    func refreshAskedMidFlightRunsAfterward() async throws {
        let harness = try await makeHarness(mode: "default")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        // The first listing after this flip hangs; every later call answers.
        // This is the shape of a backup's closing refresh arriving while a
        // launch or manual refresh is still in flight.
        var hanging = harness.repository
        hanging.extraEnvironment["SWIFTRESTIC_STUB"] = "hang-once"
        await harness.model.upsert(repository: hanging, password: nil, providerSecret: nil)
        let loadedAtStart = try #require(harness.model.snapshotsLoadedAt(for: harness.repository.id))

        let firstRefresh = Task {
            await harness.model.refreshSnapshots(repositoryID: harness.repository.id)
        }
        #expect(
            await StubRestic.waitForHang(matching: harness.stub.sleepMarker, within: 10),
            "the stub never established its hang"
        )

        // Arrives while the first refresh holds the in-flight slot; returns
        // immediately — but the just-finished backup's snapshot must not be
        // invisible until some unrelated later refresh.
        await harness.model.refreshSnapshots(repositoryID: harness.repository.id)

        firstRefresh.cancel()
        await firstRefresh.value

        // The remembered request runs to completion after the in-flight one
        // unwinds: the listing answers (the hang is spent) and freshness
        // advances past the bootstrap stamp.
        let rerun = Date.now.addingTimeInterval(10)
        while Date.now < rerun,
              harness.model.snapshotsLoadedAt(for: harness.repository.id) == loadedAtStart {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(
            harness.model.snapshotsLoadedAt(for: harness.repository.id) != loadedAtStart,
            "the refresh requested mid-flight never ran"
        )
        #expect(harness.model.snapshotListingOutcome(for: harness.repository.id) == .loaded)

        await harness.model.shutdown()
    }

    @Test("the notification event carries the full warning count, not the five-item sample")
    func notificationEventCountsAllWarnings() async throws {
        let harness = try await makeHarness(mode: "default")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        var record = RunRecord(kind: .backup, planName: "Docs", repositoryID: harness.repository.id)
        record.outcome = .completedWithErrors
        record.itemErrorCount = 500
        record.itemErrors = (1...5).map { "unreadable file \($0)" }

        let event = AppModel.notificationEvent(for: record, repositoryName: "Stub Repo")
        #expect(event.stage == .warned)
        #expect(event.warningCount == 500)
        #expect(event.warnings.count == 5, "the sample stays for the excerpt")
        #expect(event.summary.contains("500 warning(s)"), "summary was: \(event.summary)")

        await harness.model.shutdown()
    }

    @Test("quitting while a remembered refresh waits spawns no work past shutdown")
    func quitWithPendingRefreshSpawnsNoWork() async throws {
        let harness = try await makeHarness(mode: "default")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        // The in-flight refresh is one the app itself would own — the
        // maintenance engine's closing refresh, on the registry's background
        // lane — not a bare task shutdown never promised to await.
        var hanging = harness.repository
        hanging.extraEnvironment["SWIFTRESTIC_STUB"] = "hang-once"
        await harness.model.upsert(repository: hanging, password: nil, providerSecret: nil)

        func traceLineCount() -> Int {
            let trace = (try? String(
                contentsOf: harness.root.appendingPathComponent("stub-trace.log"),
                encoding: .utf8
            )) ?? ""
            return trace.components(separatedBy: "\n").filter { $0.hasPrefix("start ") }.count
        }

        harness.model.scheduleSnapshotRefresh(repositoryID: harness.repository.id)
        #expect(
            await StubRestic.waitForHang(matching: harness.stub.sleepMarker, within: 10),
            "the stub never established its hang"
        )
        // Arrives while the first still holds the in-flight slot: remembered.
        await harness.model.refreshSnapshots(repositoryID: harness.repository.id)

        await harness.model.shutdown()
        let linesAtReturn = traceLineCount()

        // The remembered rerun must not run past the shutdown drain,
        // unregistered, after terminateAll.
        let settle = Date.now.addingTimeInterval(2)
        while Date.now < settle { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(
            traceLineCount() == linesAtReturn,
            "the stub was invoked \(traceLineCount() - linesAtReturn) time(s) after shutdown returned"
        )
    }

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

    @Test("a cancelled stats read keeps the last size and reports nothing")
    func cancelledStatsIsQuiet() async throws {
        let harness = try await makeHarness(mode: "snaprows")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        // Bootstrap's stats read succeeded, so there is a size to lose: a
        // cancelled read must neither announce a failure nor blank it.
        let statsAfterBootstrap = try #require(harness.model.repositoryStats[harness.repository.id])
        #expect(harness.model.banners.isEmpty)

        // Flip the stub into a mode that hangs only `stats`, through the same
        // upsert path the repository editor takes.
        var hanging = harness.repository
        hanging.extraEnvironment["SWIFTRESTIC_STUB"] = "hang-stats"
        await harness.model.upsert(repository: hanging, password: nil, providerSecret: nil)

        let refreshTask = Task {
            await harness.model.refreshSnapshots(repositoryID: harness.repository.id)
        }
        // The listing answers fast; the hang (detectable only as the live
        // sleep process — the trace line fires for the fast calls too) is
        // what guarantees the cancel lands inside the stats read, where a
        // cancel used to surface the "could not read the size" banner and
        // blank the size.
        #expect(
            await StubRestic.waitForHang(matching: harness.stub.sleepMarker, within: 10),
            "the stub never established its stats hang"
        )

        refreshTask.cancel()
        await refreshTask.value

        #expect(
            harness.model.banners.isEmpty,
            "banners were \(harness.model.banners.map(\.title))"
        )
        #expect(harness.model.repositoryStats[harness.repository.id] == statsAfterBootstrap)
        #expect(harness.model.snapshotListingOutcome(for: harness.repository.id) == .loaded)

        await harness.model.shutdown()
    }

    @Test("a cancelled listing read does not report the repository unreadable")
    func cancelledListingIsQuiet() async throws {
        let harness = try await makeHarness(mode: "default")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let bannersAfterBootstrap = harness.model.banners

        // Hang only `snapshots`: this is the window-close-during-launch shape
        // — the refresh task itself is cancelled mid-listing, with no engine
        // involved to hand the refresh off uncancelled.
        harness.model.configuration.repositories[0].extraEnvironment["SWIFTRESTIC_STUB"] = "hang-listing"

        let refreshTask = Task {
            await harness.model.refreshSnapshots(repositoryID: harness.repository.id)
        }
        #expect(
            await StubRestic.waitForHang(matching: harness.stub.sleepMarker, within: 10),
            "the stub never established its listing hang"
        )

        refreshTask.cancel()
        await refreshTask.value

        let newBanners = harness.model.banners.filter { !bannersAfterBootstrap.contains($0) }
        #expect(
            newBanners.isEmpty,
            "the cancelled listing read posted: \(newBanners.map(\.title))"
        )
        // The bootstrap listing stands; a stopped refresh never overwrites it
        // with a failure state for a repository that was never read wrong.
        #expect(harness.model.snapshotListingOutcome(for: harness.repository.id) == .loaded)

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
        // Work in flight asks on every quit path, a logout's too, in the
        // words the alert has always used.
        let inFlight = harness.model.quitConfirmation(userChoseQuit: false)
        #expect(inFlight?.interruptsWork == true)
        #expect(inFlight?.message
            == "A backup is running\nQuitting stops the work in progress; the run history records the interruption.")

        harness.model.cancelBackup(planID: harness.plan.id)
        await harness.model.waitForRun(planID: harness.plan.id)
        #expect(harness.model.quitInterruptions.isEmpty)
        // The harness plan is manual: nothing scheduled, nothing to say.
        #expect(harness.model.quitConfirmation(userChoseQuit: false) == nil)
        #expect(harness.model.quitConfirmation(userChoseQuit: true) == nil)

        await harness.model.shutdown()
    }

    @Test("quitting during a scheduled backup names the next slot, not the one the running backup covers")
    func quitDuringScheduledRunNamesTheNextSlot() async throws {
        let harness = try await makeHarness(mode: "hang-backup")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        // Scheduled and never run, so its slot is due — the state the
        // scheduler starts a run in. Twelve hours off the clock, so the
        // next slot is never seconds away. Set and started in one turn:
        // the tick cannot start the plan in between.
        let hour = (Calendar.current.component(.hour, from: .now) + 12) % 24
        harness.model.configuration.plans[0].schedule.frequency = .daily
        harness.model.configuration.plans[0].schedule.hour = hour
        harness.model.configuration.plans[0].lastRunAt = nil
        harness.model.runBackup(planID: harness.plan.id)
        #expect(harness.model.isRunning(planID: harness.plan.id))

        let message = try #require(harness.model.quitConfirmation(userChoseQuit: true)?.message)
        #expect(message.hasPrefix(
            "A backup is running\nQuitting stops the work in progress; the run history records the interruption.\n"
        ))
        #expect(message.contains("Stub Plan is next due "))
        #expect(!message.contains("is due now"))

        // Why: the quit's cancel stamps the slot as run, so after it the
        // same sentence names the same next slot.
        harness.model.cancelBackup(planID: harness.plan.id)
        await harness.model.waitForRun(planID: harness.plan.id)
        #expect(harness.model.configuration.plans[0].lastRunAt != nil)
        let after = try #require(harness.model.quitScheduleNotice())
        #expect(after.hasPrefix("Stub Plan is next due "))

        await harness.model.shutdown()
    }

    @Test("quitting while a backup hangs mid-stream unwinds, records, and leaves no child")
    func shutdownDrainsAHungStreamingRun() async throws {
        let harness = try await makeHarness(mode: "hang-backup")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.model.runBackup(planID: harness.plan.id)
        // The hang is what guarantees the quit lands mid-run — with the
        // streaming command's idle-watchdog poll task live, which shutdown
        // must also unwind rather than wait out.
        let hangEstablished = await StubRestic.waitForHang(
            matching: harness.stub.sleepMarker, within: 10
        )
        if !hangEstablished {
            let trace = (try? String(
                contentsOf: harness.root.appendingPathComponent("stub-trace.log"), encoding: .utf8
            )) ?? "no trace"
            Issue.record("the stub never established its hang within 10 s; trace: [\(trace)]")
        }
        #expect(!harness.model.quitInterruptions.isEmpty)

        // Bounded on purpose: a regression here hangs the quit path, and the
        // test must fail instead of hanging CI.
        let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await harness.model.shutdown(); return true }
            group.addTask { try? await Task.sleep(for: .seconds(30)); return false }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        #expect(finished, "shutdown did not finish within 30 s of a hung backup")

        let record = try #require(harness.model.configuration.runs.first)
        #expect(record.outcome == .cancelled)
        #expect(
            await StubRestic.processVanishes(matching: harness.stub.sleepMarker, within: 10),
            "the stub restic process outlived the quit"
        )
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

    @Test("a backup restic finished with exit 3 marks its snapshot incomplete, counting the one unread item")
    func stubExitThreeMarksTheSnapshotIncomplete() async throws {
        let harness = try await makeHarness(mode: "warn")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.model.runBackup(planID: harness.plan.id)
        await harness.model.waitForRun(planID: harness.plan.id)

        // The warn arm answers `forget` with exit 3 and no JSON too, so the
        // record also carries a "Retention skipped" line — stored after the
        // unreadable item and never counted as one.
        let run = try #require(harness.model.backupRun(forSnapshot: "feedface00000000"))
        #expect(run.exitCode == 3)
        #expect(run.snapshotCompleteness == .incomplete)
        #expect(Format.snapshotCompleteness(run) == "Incomplete: 1 item could not be read")
        #expect(Array(run.unreadableItems) == ["/etc/secret-target: permission denied"])
        #expect(run.itemErrors.last?.hasPrefix("Retention skipped") == true, "lines were \(run.itemErrors)")

        await harness.model.shutdown()
    }

    @Test("the warning banner counts restic's unreadable items, never the stored lines")
    func warningBannerCountsItemErrorCount() async throws {
        let harness = try await makeHarness(mode: "default")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        // One unreadable item, then the retention line stored after it.
        var record = RunRecord(kind: .backup, planID: harness.plan.id, planName: "Stub Plan", repositoryID: harness.repository.id)
        record.outcome = .completedWithErrors
        record.itemErrors = ["/a: open /a: permission denied", RunRecord.retentionSkippedPrefix + "locked"]
        record.itemErrorCount = 1
        await harness.model.deliver(record: record, plan: harness.plan, transcript: RunTranscript.Contents())
        let counted = try #require(harness.model.banners.first { $0.title.contains("finished with warnings") })
        #expect(counted.message.hasPrefix("/a: open /a: permission denied — 1 unreadable item in total."), "message was \(counted.message)")

        // A retention skip alone is its own explanation, never an item.
        harness.model.banners.removeAll()
        var retentionOnly = RunRecord(kind: .backup, planID: harness.plan.id, planName: "Stub Plan", repositoryID: harness.repository.id)
        retentionOnly.outcome = .completedWithErrors
        retentionOnly.itemErrors = [RunRecord.retentionSkippedPrefix + "locked"]
        retentionOnly.itemErrorCount = 0
        await harness.model.deliver(record: retentionOnly, plan: harness.plan, transcript: RunTranscript.Contents())
        let retention = try #require(harness.model.banners.first { $0.title.contains("finished with warnings") })
        #expect(retention.message == RunRecord.retentionSkippedPrefix + "locked", "message was \(retention.message)")

        await harness.model.shutdown()
    }

    @Test("a run macOS blocked is stamped with the access state and says so in the banner and webhook")
    func tccBlockedRunNamesTheFix() async throws {
        let server = try #require(HTTPCaptureServer(), "could not start the capture listener")
        defer { server.stop() }
        server.start()
        let readyDeadline = Date.now.addingTimeInterval(5)
        while server.port == 0, Date.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(server.port != 0, "the capture listener never became ready")

        var capture = NotificationChannel()
        capture.name = "Capture"
        capture.kind = .webhook
        capture.url = "http://127.0.0.1:\(server.port)/hook"
        var leaky = BackupHook()
        leaky.name = "leaky"
        leaky.event = .afterAny
        leaky.command = "echo 'Authorization: Bearer hook-secret-token' >&2; exit 1"

        let harness = try await makeHarness(mode: "tccblocked", planHooks: [leaky], channels: [capture])
        defer { try? FileManager.default.removeItem(at: harness.root) }
        // Injected: the real probe answers for whatever launched the tests.
        harness.model.fullDiskAccessProbe = { .notGranted }

        harness.model.runBackup(planID: harness.plan.id)
        await harness.model.waitForRun(planID: harness.plan.id)

        let record = try #require(harness.model.configuration.runs.first)
        #expect(try String(contentsOf: harness.root.appendingPathComponent("stub-trace.log"), encoding: .utf8)
            .contains("tccblocked-arm"))
        // restic's scan and archival events for the one folder are one item
        // (09's dedupe) — a regression check here, red only at compile time.
        #expect(record.itemErrors.count == 2, "lines were \(record.itemErrors)")
        #expect(record.itemErrorTally == ItemErrorDiagnosis.Tally(blockedByMacOS: 1, deniedByFilePermissions: 1))
        #expect(record.fullDiskAccessAtRun == .notGranted)

        let banner = try #require(harness.model.banners.first { $0.title.contains("finished with warnings") })
        #expect(banner.message.contains("SwiftRestic needs Full Disk Access"), "message was \(banner.message)")

        var bodies: [String] = []
        let bodyDeadline = Date.now.addingTimeInterval(5)
        while bodies.isEmpty, Date.now < bodyDeadline {
            bodies = server.captured
            if bodies.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        }
        let body = try #require(bodies.first, "no webhook payload ever arrived")
        let object = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect((object["hint"] as? String)?.contains("Full Disk Access") == true, "payload was \(body)")
        #expect(record.hookMessages.contains { $0.contains("hook-secret-token") }, "the afterAny hook never ran")
        #expect(!body.contains("hook-secret-token"), "hook output reached the webhook: \(body)")

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

    // MARK: - Maintenance

    @Test("a check against a repository with no password records nothing at all")
    func missingPasswordMaintenanceRecordsNothing() async throws {
        let harness = try await makeHarness(mode: "default", password: nil)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.model.runMaintenance(id: harness.repository.id, task: .check, readDataPercent: 0)
        await harness.model.waitForMaintenance(repositoryID: harness.repository.id)

        // Not finished being set up: no run record and no "last checked" stamp.
        // Either would claim a check happened — and a stamped failure would
        // hide the repository from the scheduler for a full interval.
        #expect(harness.model.configuration.runs.isEmpty)
        #expect(harness.model.repository(id: harness.repository.id)?.maintenance.lastCheckAt == nil)
        #expect(harness.model.banners.isEmpty)

        await harness.model.shutdown()
    }

    @Test("cancelling a check still stamps the schedule and records the cancellation")
    func cancellingCheckStampsAndRecords() async throws {
        // hang-check hangs only the check command, so launch-time snapshot
        // refreshes still answer.
        let harness = try await makeHarness(mode: "hang-check")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.model.runMaintenance(id: harness.repository.id, task: .check, readDataPercent: 0)
        #expect(
            await StubRestic.waitForHang(matching: harness.stub.sleepMarker, within: 10),
            "the stub never established its hang"
        )

        harness.model.cancelMaintenance(repositoryID: harness.repository.id)
        await harness.model.waitForMaintenance(repositoryID: harness.repository.id)

        let record = try #require(harness.model.configuration.runs.first)
        #expect(harness.model.configuration.runs.count == 1)
        #expect(record.kind == .check)
        #expect(record.outcome == .cancelled)
        #expect(record.failureMessage == "Cancelled")
        // A cancelled check still counts as "checked": without the stamp the
        // scheduler would re-arm upkeep against this repository every minute.
        #expect(harness.model.repository(id: harness.repository.id)?.maintenance.lastCheckAt != nil)
        #expect(
            await StubRestic.processVanishes(matching: harness.stub.sleepMarker, within: 10),
            "the stub process outlived the cancelled check"
        )

        await harness.model.shutdown()
    }

    @Test("cancelling a check does not report the repository unreadable")
    func cancellingCheckPostsNoFailureBanner() async throws {
        let harness = try await makeHarness(mode: "hang-check")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        // The stub's catch-all answers `[]` for stats, which does not decode —
        // bootstrap posts one "size" banner for that. The subject here is what
        // the cancelled run posts, so only banners beyond bootstrap's count.
        let bannersAfterBootstrap = harness.model.banners

        // The stub's trace counts the fast answers the launch refresh got;
        // growth after the cancel proves the closing refresh actually ran.
        func answerCount() -> Int {
            let trace = (try? String(
                contentsOf: harness.root.appendingPathComponent("stub-trace.log"),
                encoding: .utf8
            )) ?? ""
            return trace.components(separatedBy: "\n").filter { $0.contains("answer-empty") }.count
        }
        let answersBeforeCancel = answerCount()

        harness.model.runMaintenance(id: harness.repository.id, task: .check, readDataPercent: 0)
        #expect(
            await StubRestic.waitForHang(matching: harness.stub.sleepMarker, within: 10),
            "the stub never established its hang"
        )
        harness.model.cancelMaintenance(repositoryID: harness.repository.id)
        await harness.model.waitForMaintenance(repositoryID: harness.repository.id)

        // The closing refresh the cancelled run still performs must neither
        // die with the cancel nor report the healthy repository unreadable:
        // the user stopped one run, the repository itself is fine.
        let settled = Date.now.addingTimeInterval(5)
        while Date.now < settled, answerCount() <= answersBeforeCancel {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(
            answerCount() > answersBeforeCancel,
            "the closing refresh never ran after the cancel"
        )
        let newBanners = harness.model.banners.filter { !bannersAfterBootstrap.contains($0) }
        #expect(
            newBanners.isEmpty,
            "the cancelled check posted: \(newBanners.map(\.title))"
        )
        #expect(harness.model.snapshotListingOutcome(for: harness.repository.id) == .loaded)

        await harness.model.shutdown()
    }

    @Test("quitting during a cancelled check spawns no work past shutdown")
    func quitDuringCancelledCheckSpawnsNoWork() async throws {
        let harness = try await makeHarness(mode: "hang-check")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.model.runMaintenance(id: harness.repository.id, task: .check, readDataPercent: 0)
        #expect(
            await StubRestic.waitForHang(matching: harness.stub.sleepMarker, within: 10),
            "the stub never established its hang"
        )

        // Counted after the hung check's own start line: the baseline for
        // "nothing ran after shutdown returned".
        func traceLineCount() -> Int {
            let trace = (try? String(
                contentsOf: harness.root.appendingPathComponent("stub-trace.log"),
                encoding: .utf8
            )) ?? ""
            return trace.components(separatedBy: "\n").filter { $0.hasPrefix("start ") }.count
        }
        let linesAtQuit = traceLineCount()

        // Quit cancels the hung check, waits for the run to unwind, and
        // flushes — the run's closing refresh must neither spawn restic work
        // past that point nor outlive the drain.
        await harness.model.shutdown()

        let settle = Date.now.addingTimeInterval(2)
        while Date.now < settle { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(
            traceLineCount() == linesAtQuit,
            "the stub was invoked \(traceLineCount() - linesAtQuit) time(s) after shutdown returned"
        )
        #expect(
            await StubRestic.processVanishes(matching: harness.stub.sleepMarker, within: 5),
            "the stub process outlived the quit"
        )
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
        #expect(harness.model.planProgress[harness.plan.id] != nil)
        harness.model.deletePlan(id: harness.plan.id)
        await harness.model.waitForRun(planID: harness.plan.id)

        #expect(harness.model.plan(id: harness.plan.id) == nil)
        // The history keeps what already happened: a cancelled run, not a
        // disappearance.
        let record = try #require(harness.model.configuration.runs.first)
        #expect(record.outcome == .cancelled)
        #expect(record.failureMessage == "Cancelled")
        // Deletion retires the progress entry with the phase strip — the pair
        // is installed and cleared together everywhere.
        #expect(harness.model.planProgress[harness.plan.id] == nil)

        await harness.model.shutdown()
    }

    @Test("Pause and Stop leaves the stopped slot due and says why; a later plain Stop stamps as before")
    func pauseAndStopKeepsSlotDue() async throws {
        let harness = try await makeHarness(mode: "hang-backup")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let planID = harness.plan.id
        // Whole seconds, two hours back: the slot the stopped run was filling.
        let earlier = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 - 7200).rounded(.down))
        harness.model.configuration.plans[0].lastRunAt = earlier

        harness.model.runBackup(planID: planID)
        #expect(await StubRestic.waitForHang(matching: harness.stub.sleepMarker, within: 10))
        harness.model.pauseBackups(for: .oneHour, stoppingRunningBackups: true)
        await harness.model.waitForRun(planID: planID)

        // restic cannot resume a backup, so the stopped one must run again
        // once the pause ends: the slot stays unstamped.
        #expect(harness.model.plan(id: planID)?.lastRunAt == earlier)
        let stopped = try #require(harness.model.configuration.runs.first)
        #expect(stopped.outcome == .cancelled)
        #expect(stopped.failureMessage == "Stopped by Pause Backups")
        if case .paused = harness.model.scheduleHold {} else {
            Issue.record("the hold was \(String(describing: harness.model.scheduleHold))")
        }

        // The mark belongs to that one run: a later plain Stop stamps.
        harness.model.resumeBackups()
        #expect(await StubRestic.processVanishes(matching: harness.stub.sleepMarker, within: 10))
        harness.model.runBackup(planID: planID)
        #expect(await StubRestic.waitForHang(matching: harness.stub.sleepMarker, within: 10))
        harness.model.cancelBackup(planID: planID)
        await harness.model.waitForRun(planID: planID)
        let stamped = try #require(harness.model.plan(id: planID)?.lastRunAt)
        #expect(stamped > earlier)
        #expect(harness.model.configuration.runs.first?.failureMessage == "Cancelled")

        await harness.model.shutdown()
    }

    @Test("plain Pause Backups lets a running backup finish")
    func pauseLeavesRunningBackupAlone() async throws {
        let harness = try await makeHarness(mode: "hang-backup")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let planID = harness.plan.id

        harness.model.runBackup(planID: planID)
        #expect(await StubRestic.waitForHang(matching: harness.stub.sleepMarker, within: 10))
        harness.model.pauseBackups(for: .oneHour)
        // Checked at once: a stopped run stays in `activity`, cancelling,
        // until its task unwinds, so the wait below alone would pass a
        // pause that stopped it whenever the unwind outlasted the wait.
        let phase = harness.model.activity[planID]?.phase
        #expect(phase != nil && phase != .cancelling, "phase was \(String(describing: phase))")
        #expect(!harness.model.pauseStoppedPlanIDs.contains(planID))
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.model.isRunning(planID: planID))
        #expect(harness.model.configuration.runs.isEmpty)

        harness.model.cancelBackup(planID: planID)
        await harness.model.waitForRun(planID: planID)
        await harness.model.shutdown()
    }

    @Test("deleting a repository cancels the backup running against it")
    func deletingRepositoryCancelsRunningBackup() async throws {
        let harness = try await makeHarness(mode: "hang-backup")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.model.runBackup(planID: harness.plan.id)
        #expect(harness.model.isRunning(planID: harness.plan.id))

        harness.model.deleteRepository(id: harness.repository.id)
        await harness.model.waitForRun(planID: harness.plan.id)

        // The repository is gone…
        #expect(harness.model.configuration.repositories.isEmpty)
        #expect(harness.model.isRunning(planID: harness.plan.id) == false)
        // …and the interrupted run is recorded as what it was — a cancelled
        // run — rather than completing silently against a repository the app
        // no longer lists.
        let record = try #require(harness.model.configuration.runs.first)
        #expect(record.outcome == .cancelled)
        #expect(record.failureMessage == "Cancelled")

        await harness.model.shutdown()
    }

    @Test("deleting a repository cancels the restore reading from it")
    func deletingRepositoryCancelsRunningRestore() async throws {
        let harness = try await makeHarness(mode: "hang-restore")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let node = SnapshotNode(name: "a.txt", type: .file, path: "/src/a.txt")
        harness.model.restore(
            repositoryID: harness.repository.id,
            snapshotID: "latest",
            node: node,
            to: harness.root.appendingPathComponent("restored"),
            overwrite: .replaceExisting
        )
        // Same guarantee as the backup case: the hang proves the restore is
        // genuinely in flight before the deletion lands.
        let hangDeadline = Date.now.addingTimeInterval(10)
        while Date.now < hangDeadline,
              StubRestic.findProcesses(matching: harness.stub.sleepMarker).isEmpty {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(StubRestic.findProcesses(matching: harness.stub.sleepMarker).isEmpty == false)

        harness.model.deleteRepository(id: harness.repository.id)
        await waitUntilRestoreFinishes(in: harness.model)

        #expect(harness.model.isRestoring == false)
        let record = try #require(harness.model.configuration.runs.first)
        #expect(record.kind == .restore)
        #expect(record.outcome == .cancelled)
        // The removal may not cancel silently: the user learns their restore
        // stopped from a banner, not from a progress strip that never returns.
        let cancelledBanner = await bannerTitled("Restore cancelled", in: harness.model)
        #expect(
            cancelledBanner?.isError == false,
            "banners were: \(harness.model.banners.map(\.title))"
        )

        await harness.model.shutdown()
    }

    // MARK: - Removal disclosure and wrong-password copy

    @Test("removing a repository discloses the restore its removal will cancel")
    func removalDisclosesRunningRestore() async throws {
        let harness = try await makeHarness(mode: "hang-restore")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        // Idle: the removal dialog's base sentence only, no restore clause.
        let idle = harness.model.removalConsequences(for: harness.repository.id)
        #expect(idle.contains("The backup data itself is not deleted."))
        #expect(!idle.contains("restore"))

        let node = SnapshotNode(name: "a.txt", type: .file, path: "/src/a.txt")
        harness.model.restore(
            repositoryID: harness.repository.id,
            snapshotID: "latest",
            node: node,
            to: harness.root.appendingPathComponent("restored"),
            overwrite: .replaceExisting
        )
        #expect(
            await StubRestic.waitForHang(matching: harness.stub.sleepMarker, within: 10),
            "the stub never established its hang"
        )

        let consequences = harness.model.removalConsequences(for: harness.repository.id)
        #expect(consequences.contains("The backup data itself is not deleted."))
        #expect(consequences.contains("A restore from this repository is running"))
        #expect(consequences.contains("cancelled"))

        // Settled again: the disclosure returns to the base sentence.
        harness.model.cancelRestore()
        await waitUntilRestoreFinishes(in: harness.model)
        #expect(!harness.model.removalConsequences(for: harness.repository.id).contains("restore"))

        await harness.model.shutdown()
    }

    @Test("a wrong password names the fix instead of restic's raw diagnosis")
    func wrongPasswordNamesTheFix() async throws {
        let harness = try await makeHarness(mode: "wrongpassword")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        guard case let .failed(message) = harness.model.snapshotListingOutcome(for: harness.repository.id) else {
            Issue.record(
                "expected a failed listing outcome, got \(harness.model.snapshotListingOutcome(for: harness.repository.id))"
            )
            return
        }
        #expect(message.contains("doesn't open this repository"))
        #expect(message.contains("check it in the repository settings"))
        // The failure is not a quiet state like a missing password: the user
        // saved credentials that do not work, so the banner says so.
        let banner = try #require(harness.model.banners.first, "a wrong password must surface a banner")
        #expect(banner.isError)
        #expect(banner.message.contains("doesn't open this repository"))

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

    // MARK: - Browse caches

    /// AppModel's index coordinator resolves its directory at init through
    /// `SWIFTRESTIC_CONFIG_DIR`; pinned into scratch space for the test's
    /// lifetime, browse-cache writes never land in real Application Support.
    private func withScratchIndexDirectory(
        _ body: () async throws -> Void
    ) async rethrows {
        let indexRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticBrowseIndex-\(UUID().uuidString)")
        setenv("SWIFTRESTIC_CONFIG_DIR", indexRoot.path, 1)
        defer {
            unsetenv("SWIFTRESTIC_CONFIG_DIR")
            try? FileManager.default.removeItem(at: indexRoot)
        }
        try await body()
    }

    /// The stub logs one `start args=[…]` line per invocation; count the
    /// runs of one subcommand. `ls`/`diff` are what a browse pays for —
    /// the bootstrap refresh's `snapshots`/`stats` runs never match.
    private func stubRuns(_ subcommand: String, in harness: Harness) throws -> Int {
        let trace = try String(
            contentsOf: harness.root.appendingPathComponent("stub-trace.log"),
            encoding: .utf8
        )
        return trace.components(separatedBy: "\n").filter { line in
            line.contains("args=[\(subcommand) ")
        }.count
    }

    @Test("a repeat folder browse answers from the cache without spawning restic")
    func repeatBrowseHitsCache() async throws {
        try await withScratchIndexDirectory {
            let harness = try await makeHarness(mode: "browserows")
            defer { try? FileManager.default.removeItem(at: harness.root) }

            let first = try await harness.model.children(
                repositoryID: harness.repository.id,
                snapshotID: "feedface00000000",
                path: "/src"
            )
            // listDirectory drops the directory's own node — the listing is
            // its children only.
            #expect(first.map(\.path) == ["/src/notes.txt"])
            let notes = try #require(first.first)
            #expect(notes.size == 42)

            let second = try await harness.model.children(
                repositoryID: harness.repository.id,
                snapshotID: "feedface00000000",
                path: "/src/"
            )
            #expect(second == first)
            #expect(try stubRuns("ls", in: harness) == 1)

            await harness.model.shutdown()
        }
    }

    @Test("a repeat record switch reads the cached diff instead of re-walking")
    func repeatDiffHitsCache() async throws {
        try await withScratchIndexDirectory {
            let harness = try await makeHarness(mode: "browserows")
            defer { try? FileManager.default.removeItem(at: harness.root) }

            let changes = await harness.model.snapshotChanges(
                repositoryID: harness.repository.id,
                olderID: "0000000000000000",
                newerID: "feedface00000000"
            )
            #expect(changes.changes["/src/new.txt"]?.category == .added)
            #expect(changes.changes["/src/gone.txt"]?.category == .removed)
            #expect(changes.failure == nil)

            let again = await harness.model.snapshotChanges(
                repositoryID: harness.repository.id,
                olderID: "0000000000000000",
                newerID: "feedface00000000"
            )
            // A cache hit is a complete comparison, not a partial one.
            #expect(again == changes)
            #expect(again.failure == nil)
            #expect(try stubRuns("diff", in: harness) == 1)

            await harness.model.shutdown()
        }
    }

    @Test("a diff that fails partway says so, keeps what streamed, and caches nothing")
    func failedDiffIsReported() async throws {
        try await withScratchIndexDirectory {
            let harness = try await makeHarness(mode: "difffail")
            defer { try? FileManager.default.removeItem(at: harness.root) }

            let marks = await harness.model.snapshotChanges(
                repositoryID: harness.repository.id,
                olderID: "0000000000000000",
                newerID: "feedface00000000"
            )
            // The change that streamed before restic died is still true.
            #expect(marks.changes["/src/new.txt"]?.category == .added)
            #expect(marks.failure?.contains("no matching ID found") == true, "failure was \(String(describing: marks.failure))")

            // Nothing was cached: the same switch asks restic again.
            let again = await harness.model.snapshotChanges(
                repositoryID: harness.repository.id,
                olderID: "0000000000000000",
                newerID: "feedface00000000"
            )
            #expect(again.failure != nil)
            #expect(try stubRuns("diff", in: harness) == 2)

            await harness.model.shutdown()
        }
    }

    @Test("a diff with no password to run it reports why instead of marking nothing")
    func diffWithoutPasswordIsReported() async throws {
        try await withScratchIndexDirectory {
            let harness = try await makeHarness(mode: "difffail", password: nil)
            defer { try? FileManager.default.removeItem(at: harness.root) }

            let marks = await harness.model.snapshotChanges(
                repositoryID: harness.repository.id,
                olderID: "0000000000000000",
                newerID: "feedface00000000"
            )
            #expect(marks.changes.isEmpty)
            #expect(marks.failure?.contains("password") == true, "failure was \(String(describing: marks.failure))")
            #expect(((try? stubRuns("diff", in: harness)) ?? 0) == 0)

            await harness.model.shutdown()
        }
    }

    // MARK: - Run logs

    private func logsDirectory(_ harness: Harness) -> URL {
        harness.root.appendingPathComponent("config").appendingPathComponent("Logs")
    }

    private func logText(for record: RunRecord, in harness: Harness) throws -> String {
        try String(
            contentsOf: logsDirectory(harness).appendingPathComponent("\(record.id.uuidString).log"),
            encoding: .utf8
        )
    }

    private func logNames(in directory: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".log") })
    }

    @Test("a finished backup leaves its log beside the configuration")
    func finishedBackupLeavesItsLog() async throws {
        let harness = try await makeHarness(mode: "warn")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.model.runBackup(planID: harness.plan.id)
        await harness.model.waitForRun(planID: harness.plan.id)

        let record = try #require(harness.model.configuration.runs.first)
        #expect(record.hasLog)
        #expect(record.exitCode == 3)
        #expect(record.resticVersion == "restic 0.0.0-stub compiled with sh on darwin")

        let log = try logText(for: record, in: harness)
        #expect(log.hasPrefix("SwiftRestic"), "log began \(log.prefix(80))")
        #expect(log.contains("$    restic backup --json"))
        #expect(log.contains("permission denied"))
        // The warn arm answers forget with exit 3 too: both exits are logged,
        // and the run's own code is the backup's.
        #expect(log.components(separatedBy: "exit 3").count - 1 == 2, "log was \(log)")
        #expect(log.contains("$    restic forget --json"))
        #expect(log.contains("note Retention skipped: "))
        #expect(log.contains("Completed with errors"))
        // The password and the repository's environment travel beside the
        // command line, never in it.
        #expect(!log.contains("test-password"))
        #expect(!log.contains("stub-trace.log"))

        await harness.model.shutdown()
    }

    @Test("a log that cannot be written leaves the run recorded, with hasLog false")
    func unwritableLogLeavesHasLogFalse() async throws {
        let harness = try await makeHarness(mode: "default")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        // A plain file where the Logs folder belongs: creating the folder
        // throws, as a full disk or a read-only volume would.
        let logs = logsDirectory(harness)
        try Data("not a folder".utf8).write(to: logs)

        harness.model.runBackup(planID: harness.plan.id)
        await harness.model.waitForRun(planID: harness.plan.id)

        let record = try #require(harness.model.configuration.runs.first)
        #expect(record.kind == .backup)
        #expect(record.outcome == .succeeded)
        // Show Log… reads this: a true here would offer a log that is not there.
        #expect(record.hasLog == false)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: logs.path, isDirectory: &isDirectory) && !isDirectory.boolValue)

        await harness.model.shutdown()
    }

    @Test("a missing source folder is named in the log although restic sends no error event")
    func missingSourceIsNamedInTheLog() async throws {
        let harness = try await makeHarness(mode: "missingsource")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.model.runBackup(planID: harness.plan.id)
        await harness.model.waitForRun(planID: harness.plan.id)

        let record = try #require(harness.model.configuration.runs.first)
        #expect(record.outcome == .completedWithErrors)
        #expect(record.itemErrors == ["/src/gone does not exist, skipping"])
        #expect(record.exitCode == 3)
        #expect(RunRecordPresentation.detail(for: record) == "1 unreadable item")
        let log = try logText(for: record, in: harness)
        #expect(log.contains("err  /src/gone does not exist, skipping"), "log was \(log)")
        #expect(log.contains("note Retention removed 0 snapshots"))

        await harness.model.shutdown()
    }

    @Test("a restore record says which backup, which item and where it went")
    func restoreRecordNamesItsBackupAndLanding() async throws {
        let harness = try await makeHarness(mode: "default")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let node = try ResticMessageDecoder.jsonDecoder.decode(
            SnapshotNode.self,
            from: Data(#"{"name":"a.txt","type":"file","path":"/src/a.txt","size":12}"#.utf8)
        )
        let destination = harness.root.appendingPathComponent("restored")
        harness.model.restore(repositoryID: harness.repository.id, snapshotID: "latest", node: node, to: destination, overwrite: .replaceExisting)
        await waitUntilRestoreFinishes(in: harness.model)

        let record = try #require(harness.model.configuration.runs.first)
        #expect(record.kind == .restore)
        #expect(record.snapshotID == "latest")
        #expect(record.sourcePath == "/src/a.txt")
        #expect(record.destinationPath == destination.appendingPathComponent("a.txt").path)
        #expect(record.filesRestored == 1)
        #expect(record.filesSkipped == 0)
        #expect(record.bytesProcessed == 12)
        #expect(record.exitCode == 0)
        #expect(record.hasLog)
        let log = try logText(for: record, in: harness)
        #expect(log.contains("$    restic dump latest /src/a.txt"), "log was \(log)")
        #expect(log.contains("exit 0"))
        #expect(log.contains("Restored to \(destination.appendingPathComponent("a.txt").path)"))
        // A restore is never the run that wrote a snapshot.
        #expect(harness.model.backupRun(forSnapshot: "latest") == nil)

        await harness.model.shutdown()
    }

    @Test("a whole-backup restore records the folder it restored into")
    func wholeRestoreRecordNamesItsTarget() async throws {
        let harness = try await makeHarness(mode: "default")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let destination = harness.root.appendingPathComponent("whole")
        harness.model.restoreWholeSnapshot(repositoryID: harness.repository.id, snapshotID: "latest", to: destination, overwrite: .replaceExisting)
        await waitUntilRestoreFinishes(in: harness.model)

        let record = try #require(harness.model.configuration.runs.first)
        #expect(record.kind == .restore)
        #expect(record.snapshotID == "latest")
        #expect(record.sourcePath == nil)
        #expect(record.destinationPath == destination.path)
        #expect(record.hasLog)

        await harness.model.shutdown()
    }

    @Test("trimming the history deletes the trimmed runs' logs")
    func trimmedRunsLoseTheirLogs() async throws {
        // maxRunHistory only raises the floor of 20, so 5 is still capped at 20.
        let harness = try await makeHarness(mode: "default", maxRunHistory: 5)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        for _ in 0 ..< 22 {
            harness.model.runBackup(planID: harness.plan.id)
            await harness.model.waitForRun(planID: harness.plan.id)
        }
        let kept = harness.model.configuration.runs
        #expect(kept.count == 20)
        #expect(kept.allSatisfy { $0.hasLog })
        // Shutdown drains the background lane the removals run on.
        await harness.model.shutdown()

        #expect(logNames(in: logsDirectory(harness)) == Set(kept.map { "\($0.id.uuidString).log" }))
    }

    @Test("clearing the history deletes its logs")
    func clearedHistoryLosesItsLogs() async throws {
        let harness = try await makeHarness(mode: "default")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        for _ in 0 ..< 2 {
            harness.model.runBackup(planID: harness.plan.id)
            await harness.model.waitForRun(planID: harness.plan.id)
        }
        #expect(logNames(in: logsDirectory(harness)).count == 2)
        harness.model.clearRunHistory()
        await harness.model.shutdown()

        #expect(logNames(in: logsDirectory(harness)).isEmpty)
    }

    /// A configuration directory for the launch-sweep tests, bootstrapped
    /// against the stub so nothing reaches for a real restic.
    private func sweepFixture() throws -> (root: URL, config: URL, logs: URL, stub: StubRestic) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticLogSweep-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let config = root.appendingPathComponent("config")
        let logs = config.appendingPathComponent("Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return (root, config, logs, try StubRestic.install(in: root))
    }

    @Test("launch sweeps orphan logs only from a readable configuration, only old ones, only <UUID>.log")
    func launchSweepsOrphanLogs() async throws {
        let fixture = try sweepFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var run = RunRecord(kind: .backup, planName: "Kept")
        run.hasLog = true
        var configuration = AppConfiguration()
        configuration.runs = [run]
        configuration.settings.resticPathOverride = fixture.stub.url.path
        try await ConfigStore(directory: fixture.config).save(configuration)

        let old = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01
        let known = fixture.logs.appendingPathComponent("\(run.id.uuidString).log")
        let orphan = fixture.logs.appendingPathComponent("\(UUID().uuidString).log")
        let fresh = fixture.logs.appendingPathComponent("\(UUID().uuidString).log")
        let notes = fixture.logs.appendingPathComponent("notes.txt")
        for url in [known, orphan, fresh, notes] {
            try "log".write(to: url, atomically: true, encoding: .utf8)
        }
        for url in [known, orphan, notes] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        // Written after launch: a run finishing while the sweep walks.
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(3600)],
            ofItemAtPath: fresh.path
        )

        let model = AppModel(store: ConfigStore(directory: fixture.config), secrets: .inMemory())
        await model.bootstrap()
        await model.shutdown()

        #expect(FileManager.default.fileExists(atPath: known.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path), "an orphan log from before launch survived")
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: notes.path))
    }

    @Test("an unreadable configuration sweeps no logs")
    func unreadableConfigurationSweepsNothing() async throws {
        let fixture = try sweepFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // No generation reads, so the history is unknown — not empty.
        try Data("{ not json".utf8).write(to: fixture.config.appendingPathComponent("config.json"))
        let log = fixture.logs.appendingPathComponent("\(UUID().uuidString).log")
        try "log".write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_577_836_800)],
            ofItemAtPath: log.path
        )

        let model = AppModel(store: ConfigStore(directory: fixture.config), secrets: .inMemory())
        await model.bootstrap()
        await model.shutdown()

        #expect(model.isConfigurationUnreadable)
        #expect(FileManager.default.fileExists(atPath: log.path))
    }

    @Test("bootstrapping does not schedule a save over what it just loaded")
    func bootstrapLeavesTheStoreUnwritten() async throws {
        let harness = try await makeHarness(mode: "default")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        // `isLoaded` is already true while bootstrap assigns the loaded
        // configuration, so the didSet used to schedule a save 400 ms after
        // every launch — committing any tolerant-decode substitutions before
        // the banner naming them could be read. No save task may exist after
        // bootstrap: loading is not a user edit.
        #expect(harness.model.saveTask == nil)
        #expect(harness.model.isConfigurationUnreadable == false)
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
