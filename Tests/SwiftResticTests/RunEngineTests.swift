import Foundation
import Testing

/// The run engines' sequencing and outcome mapping, driven through a mock
/// client and a recording sink. restic is mocked; hooks still run as real
/// `/bin/sh` processes. The stub-shell and real-restic suites own everything
/// below the `ResticClient` seam.
@MainActor
@Suite("backup run engine")
struct BackupRunEngineTests {
    /// Records every sink call in order; the ordered log is what the
    /// sequencing assertions read.
    final class RecordingSink: BackupRunEngine.Sink {
        var log: [String] = []
        var deliveredRecords: [RunRecord] = []
        var deliveredTranscripts: [RunTranscript.Contents] = []

        /// Per plan, so a test can tell the engine asked about its own run.
        func cancellationMessage(for planID: UUID) -> String { "cancelled \(planID)" }
        func label(of plan: BackupPlan) -> String { plan.label(among: [plan]) }
        func label(of repository: Repository) -> String { repository.label(among: [repository]) }

        /// What `service()` answers; set by `serving(_:)`.
        var client = MockResticClient()
        func serving(_ client: MockResticClient) -> Self {
            self.client = client
            return self
        }

        func service() throws -> any ResticClient { client }
        func context(for repository: Repository) async throws -> RepositoryContext {
            log.append("context")
            return RepositoryContext(repository: repository, password: "test")
        }

        func setActivityPhase(_ phase: PlanActivity.Phase, for planID: UUID) {
            log.append("phase:\(phase)")
        }

        func progressReporter(planID: UUID) -> @Sendable (OperationProgress) -> Void {
            log.append("reporter-built")
            return { _ in }
        }

        func markPlanRun(_ planID: UUID, at date: Date, wrote stamp: BackupStamp) {
            log.append("mark:\(stamp)")
        }

        func noteAuthFailure(_ error: Error, repositoryID: UUID) {
            log.append("auth-noted")
        }

        func addStartPing(_ event: NotificationEvent) {
            log.append("ping:\(event.stage)")
        }

        /// Per refresh, whether it ran in a cancelled task.
        var refreshCancelled: [Bool] = []
        func refreshSnapshots(repositoryID: UUID) async {
            log.append("refresh")
            refreshCancelled.append(Task.isCancelled)
        }

        func scheduleSnapshotRefresh(repositoryID: UUID) {
            log.append("refresh-scheduled")
            Task { await refreshSnapshots(repositoryID: repositoryID) }
        }

        func noteRepositoryAway(repositoryID: UUID, reason: String) {
            log.append("away:\(reason)")
        }

        func deliver(record: RunRecord, plan: BackupPlan, transcript: RunTranscript.Contents) async {
            log.append("deliver:\(record.outcome)")
            deliveredRecords.append(record)
            deliveredTranscripts.append(transcript)
        }

        /// The notes the engine wrote into the delivered run's transcript.
        var deliveredNotes: [String] {
            deliveredTranscripts.flatMap { $0.entries.filter { $0.kind == .note }.map(\.text) }
        }

        func makeHookRunner() -> HookRunner {
            HookRunner(runner: ResticRunner())
        }

        /// The canned answer to a reconnect; every ask is logged.
        var reconnectAnswer: [ShareReconnect] = []

        func reconnectShares(volumes: [String]) async -> [ShareReconnect] {
            log.append("reconnect:\(volumes.joined(separator: ","))")
            return reconnectAnswer
        }

        /// The canned answer to a server probe; every ask is logged.
        var probeAnswer: ServerProbe.Outcome? = .reachable

        func probeServer(of repository: Repository) async -> ServerProbe.Outcome? {
            log.append("probe")
            return probeAnswer
        }
    }

    private func makePlan(retentionEnabled: Bool = true) -> BackupPlan {
        var plan = BackupPlan()
        plan.repositoryID = Repository().id
        plan.path = "/tmp/engine-source"
        if !retentionEnabled { plan.retention.isEnabled = false }
        return plan
    }

    private func successOutcome(snapshotID: String? = "cafe0000") -> BackupOutcome {
        var summary = ResticSummary()
        summary.snapshotID = snapshotID
        summary.filesNew = 2
        summary.totalBytesProcessed = 1234
        return BackupOutcome(summary: summary, itemErrors: [], exitCode: 0)
    }

    @Test("a clean run pings, backs up, applies retention, refreshes, delivers")
    func cleanRunSequencing() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onBackup(.success(successOutcome()))
        let plan = makePlan()
        await BackupRunEngine.perform(plan: plan, repository: Repository(), sink: sink.serving(client))

        // The ping must precede the backup (a monitor's timer starts at the
        // ping), the success stamp must land before anything later can fail
        // the run, retention must follow a produced snapshot, and the
        // closing refresh must follow retention (lock ordering).
        #expect(sink.log == [
            "context",
            "ping:started",
            "phase:backingUp",
            "reporter-built",
            "mark:whole",
            "phase:applyingRetention",
            "refresh",
            "deliver:succeeded",
        ], "log was \(sink.log)")
        #expect(sink.deliveredRecords.count == 1)
        #expect(sink.deliveredRecords[0].outcome == .succeeded)
        #expect(sink.deliveredRecords[0].snapshotID == "cafe0000")
    }

    @Test("a repository on a network share that is away is reconnected first: out of reach the run is skipped saying why, refused it fails in those words without asking restic")
    func awayRepositoryShareIsReconnected() async throws {
        let volume = "SwiftResticAbsentShare-\(UUID().uuidString)"
        var repository = Repository()
        repository.kind = .local
        repository.localPath = "/Volumes/\(volume)/restic"

        let outOfReach = RecordingSink()
        let unreachable = "the server could not be reached"
        outOfReach.reconnectAnswer = [ShareReconnect(volumeName: volume, url: "smb://me@nas.local/\(volume)", outcome: .unreachable(unreachable))]
        let client = MockResticClient().onBackup(.success(successOutcome()))
        await BackupRunEngine.perform(plan: makePlan(), repository: repository, sink: outOfReach.serving(client))
        // Asked once, before the run is decided.
        #expect(outOfReach.log.filter { $0.hasPrefix("reconnect") } == ["reconnect:\(volume)"], "log was \(outOfReach.log)")
        #expect(try #require(outOfReach.log.firstIndex(of: "reconnect:\(volume)")) < (try #require(outOfReach.log.firstIndex(of: "mark:nothing"))))
        let skipped = try #require(outOfReach.deliveredRecords.first)
        #expect(skipped.outcome == .skipped)
        #expect(skipped.detailText == "“\(volume)” is not connected. Reconnecting “\(volume)” failed: \(unreachable).")
        #expect(skipped.refusedShares == nil)
        #expect(outOfReach.deliveredNotes.contains("Could not reconnect the network share smb://me@nas.local/\(volume): \(unreachable)."))

        let refusing = RecordingSink()
        let refused = "the share did not accept the user name and password"
        refusing.reconnectAnswer = [ShareReconnect(volumeName: volume, url: "smb://me@nas.local/\(volume)", outcome: .refused(refused))]
        let untouched = MockResticClient().onBackup(.success(successOutcome()))
        await BackupRunEngine.perform(plan: makePlan(), repository: repository, sink: refusing.serving(untouched))
        #expect(untouched.callLog.isEmpty)
        #expect(refusing.log.contains("mark:nothing"), "log was \(refusing.log)")
        let failed = try #require(refusing.deliveredRecords.first)
        #expect(failed.outcome == .failed)
        #expect(failed.failureMessage == "“\(volume)” is not connected. Reconnecting “\(volume)” failed: \(refused).")
        #expect(failed.refusedShares == [volume])
    }

    @Test("a share holding the plan's folders that refuses fails the run in those words before restic is asked, naming that share")
    func refusedFolderShareFails() async throws {
        let volume = "SwiftResticAbsentShare-\(UUID().uuidString)"
        let sink = RecordingSink()
        let refused = "the server has no share by that name"
        sink.reconnectAnswer = [ShareReconnect(volumeName: volume, url: "smb://me@nas.local/\(volume)", outcome: .refused(refused))]
        let untouched = MockResticClient().onBackup(.success(successOutcome()))
        var plan = makePlan()
        plan.path = "/Volumes/\(volume)/Projects"
        await BackupRunEngine.perform(plan: plan, repository: Repository(), sink: sink.serving(untouched))
        #expect(untouched.callLog.isEmpty)
        let record = try #require(sink.deliveredRecords.first)
        #expect(record.outcome == .failed)
        #expect(record.failureMessage == "“\(volume)” is not connected. Reconnecting “\(volume)” failed: \(refused).")
        #expect(record.refusedShares == [volume])
    }

    @Test("an away folder's drive is asked about once, and a run with nothing away asks nothing")
    func awaySourcesAskedOnce() async throws {
        let away = "SwiftResticAbsent-\(UUID().uuidString)"
        let sink = RecordingSink()
        sink.reconnectAnswer = [ShareReconnect(volumeName: away, url: "smb://nas.local/\(away)", outcome: .unreachable("the server could not be reached"))]
        let client = MockResticClient().onBackup(.failure(ResticError.commandFailed(exitCode: 1, message: RunRecord.everySourceMissingMessage)))
        var plan = makePlan()
        plan.path = "/Volumes/\(away)/c"
        await BackupRunEngine.perform(plan: plan, repository: Repository(), sink: sink.serving(client))

        #expect(sink.log.filter { $0.hasPrefix("reconnect") } == ["reconnect:\(away)"], "log was \(sink.log)")
        let record = try #require(sink.deliveredRecords.first)
        #expect(record.outcome == .skipped)
        #expect(record.detailText
            == "“\(away)” is not connected. Reconnecting “\(away)” failed: the server could not be reached.")

        let here = RecordingSink()
        await BackupRunEngine.perform(
            plan: makePlan(), repository: Repository(),
            sink: here.serving(MockResticClient().onBackup(.success(successOutcome())))
        )
        #expect(!here.log.contains { $0.hasPrefix("reconnect") }, "log was \(here.log)")
    }

    @Test("a backup that fills its repository's disk fails in plain words, marked for Clean Up Now")
    func repositoryDiskFull() async throws {
        let sink = RecordingSink()
        var repository = Repository()
        repository.kind = .local
        repository.localPath = "/Users/Shared/engine-repo"
        let line = "Fatal: unable to save snapshot: write /Users/Shared/engine-repo/data/52/526d-tmp-1: no space left on device"
        let client = MockResticClient().onBackup(.failure(ResticError.commandFailed(exitCode: 1, message: line)))
        await BackupRunEngine.perform(plan: makePlan(), repository: repository, sink: sink.serving(client))
        let record = try #require(sink.deliveredRecords.first)
        #expect(record.outcome == .failed)
        #expect(record.failureMessage == RunRecord.repositoryFullMessage(resticMessage: line, repository: repository))
        #expect(record.failureMessage?.hasPrefix("This Mac’s disk is full") == true)
        #expect(record.repositoryFull == true)
    }

    @Test("no snapshot written means retention never runs")
    func retentionNeedsASnapshot() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onBackup(.success(successOutcome(snapshotID: nil)))
        let plan = makePlan()
        await BackupRunEngine.perform(plan: plan, repository: Repository(), sink: sink.serving(client))

        #expect(!sink.log.contains { $0.hasPrefix("phase:applyingRetention") })
        // The run itself still succeeded and was delivered.
        #expect(sink.deliveredRecords[0].outcome == .succeeded)
    }

    @Test("a failed backup is marked failed, noted for auth when exit 12, delivered")
    func failedRun() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onBackup(
            .failure(ResticError.commandFailed(exitCode: 12, message: "wrong password"))
        )
        let plan = makePlan()
        await BackupRunEngine.perform(plan: plan, repository: Repository(), sink: sink.serving(client))

        #expect(sink.log.contains("mark:nothing"))
        #expect(sink.log.contains("auth-noted"))
        #expect(sink.deliveredRecords[0].outcome == .failed)
    }

    @Test("cancelling during a before-backup hook reads as cancelled, not a hook failure")
    func cancelDuringBeforeHookIsACancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticEngineCancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let hookStarted = directory.appendingPathComponent("hook-started")
        let failureRan = directory.appendingPathComponent("after-failure-ran")
        var plan = makePlan()
        var gate = BackupHook()
        gate.name = "gate"
        gate.event = .beforeBackup
        gate.command = "touch \(hookStarted.path); sleep 30"
        gate.failureBehaviour = .abortBackup
        var aftermath = BackupHook()
        aftermath.name = "aftermath"
        aftermath.event = .afterFailure
        aftermath.command = "touch \(failureRan.path)"
        plan.hooks = [gate, aftermath]

        let sink = RecordingSink()
        let client = MockResticClient().onBackup(.success(successOutcome()))
        let task = Task {
            await BackupRunEngine.perform(plan: plan, repository: Repository(), sink: sink.serving(client))
        }
        // The hang is what guarantees the cancel lands inside the hook, the
        // window where a cancel must read as a cancellation, not a hook
        // failure.
        // A loaded Mac can stretch a shell's start well past seconds, and a
        // cancel landing before the hook would test another case.
        try #require(
            await eventually(within: 60) { FileManager.default.fileExists(atPath: hookStarted.path) },
            "the hook never started"
        )
        task.cancel()
        await task.value

        let record = try #require(sink.deliveredRecords.first)
        #expect(record.outcome == .cancelled, "outcome was \(record.outcome)")
        // The sink says why, for this plan: Pause and Stop words a stopped
        // run differently from the user's own Stop.
        #expect(record.failureMessage == "cancelled \(plan.id)")
        #expect(record.hookMessages.isEmpty, "messages were \(record.hookMessages)")
        #expect(
            !FileManager.default.fileExists(atPath: failureRan.path),
            "after-failure hooks fired for a user-initiated cancel"
        )
    }

    @Test("a retention failure degrades to warnings, never fails the run")
    func retentionFailureIsADegradation() async throws {
        let sink = RecordingSink()
        let client = MockResticClient()
            .onBackup(.success(successOutcome()))
            .onForget(.failure(ResticError.commandFailed(exitCode: 11, message: "locked")))
        let plan = makePlan()
        await BackupRunEngine.perform(plan: plan, repository: Repository(), sink: sink.serving(client))

        let record = sink.deliveredRecords[0]
        #expect(record.outcome == .completedWithErrors)
        // Lost to a lock — most often another backup of this Mac to the same
        // repository, its own lock live: the line says so, never the stale-
        // lock advice a failed run's exit 11 carries, which would send the
        // user to remove a lock nothing left behind.
        #expect(record.itemErrors == ["Retention skipped: another backup or job held the repository’s lock — retention runs again after the next backup."])
        // The snapshot was written; the run itself stays marked successful.
        #expect(sink.log.contains("mark:whole"))
    }

    @Test("a server out of reach skips the backup within seconds, its slot stamped, restic never asked")
    func unreachableServerSkipsTheBackup() async throws {
        let sink = RecordingSink()
        sink.probeAnswer = .unreachable("connection refused")
        let client = MockResticClient().onBackup(.success(successOutcome()))
        var repository = Repository()
        repository.kind = .rest
        repository.restURL = "http://127.0.0.1:18000/app"
        await BackupRunEngine.perform(plan: makePlan(), repository: repository, sink: sink.serving(client))

        let record = try #require(sink.deliveredRecords.first)
        #expect(record.outcome == .skipped)
        #expect(record.detailText == "“127.0.0.1” cannot be reached (connection refused).")
        #expect(client.callLog.isEmpty)
        // Stamped, as a drive away is, so an hourly plan does not retry
        // every minute; the listing learns why at once; no start ping.
        #expect(sink.log.contains("mark:nothing"))
        #expect(sink.log.contains("away:“127.0.0.1” cannot be reached (connection refused)."))
        #expect(!sink.log.contains { $0.hasPrefix("ping:") })
    }

    @Test("a server that answers is backed up to; a local repository is never probed")
    func reachableServerAndLocalRepository() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onBackup(.success(successOutcome())).onForget(.success(0))
        var repository = Repository()
        repository.kind = .rest
        repository.restURL = "http://127.0.0.1:18000/app"
        await BackupRunEngine.perform(plan: makePlan(), repository: repository, sink: sink.serving(client))
        #expect(sink.log.contains("probe"))
        #expect(client.callLog.first == "backup")

        let localSink = RecordingSink()
        let localClient = MockResticClient().onBackup(.success(successOutcome())).onForget(.success(0))
        await BackupRunEngine.perform(plan: makePlan(), repository: Repository(), sink: localSink.serving(localClient))
        #expect(!localSink.log.contains("probe"))
        #expect(localClient.callLog.first == "backup")
    }

    @Test("a retention the repository refused is a warning that says so, with the count stored for its fix")
    func refusedRetentionIsAWarning() async throws {
        let sink = RecordingSink()
        let client = MockResticClient()
            .onBackup(.success(successOutcome()))
            .onForget(.failure(ResticError.snapshotsNotRemoved(removed: 0, refused: 1, reason: "403 Forbidden")))
        let plan = makePlan()
        await BackupRunEngine.perform(plan: plan, repository: Repository(), sink: sink.serving(client))

        let record = sink.deliveredRecords[0]
        #expect(record.outcome == .completedWithErrors)
        #expect(record.itemErrors == [
            "Retention skipped: The repository refused to delete 1 backup (403 Forbidden) — it may be append-only or locked. "
                + "Thin it where deletions are allowed, or turn retention off.",
        ])
        #expect(record.retentionRefused == 1)
        #expect(sink.log.contains("mark:whole"))
    }

    @Test("stopping a backup during its own retention step reads as cancelled, not a warning")
    func stopDuringRetentionIsACancellation() async throws {
        // The Plan menu's and the tray's "Stop Applying Retention", Pause
        // and Stop, and a quit all reach a backup's forget as a cancelled
        // restic call — the user's stop, never a lock failure to warn about.
        let sink = RecordingSink()
        let client = MockResticClient()
            .onBackup(.success(successOutcome()))
            .onForget(.failure(ResticError.cancelled))
        let plan = makePlan()
        await BackupRunEngine.perform(plan: plan, repository: Repository(), sink: sink.serving(client))

        let record = try #require(sink.deliveredRecords.first)
        #expect(record.outcome == .cancelled, "outcome was \(record.outcome), itemErrors \(record.itemErrors)")
        #expect(record.failureMessage == "cancelled \(plan.id)")
        #expect(!record.itemErrors.contains { $0.hasPrefix(RunRecord.retentionSkippedPrefix) }, "itemErrors were \(record.itemErrors)")
        #expect(sink.deliveredNotes.contains("Retention stopped"), "notes were \(sink.deliveredNotes)")
        // The snapshot was written before the stop: it keeps its record and
        // its success stamp, and nothing stamps the run again as failed.
        #expect(record.snapshotID == "cafe0000")
        #expect(sink.log.filter { $0.hasPrefix("mark:") } == ["mark:whole"], "log was \(sink.log)")
        #expect(!sink.log.contains("auth-noted"))
    }

    @Test("a backup stopped during its retention step still refreshes the listing, outside its cancelled task")
    func stopDuringRetentionStillRefreshes() async throws {
        // The snapshot stands and the forget may have removed some before the
        // stop: the listing must be read again, and a refresh inside the
        // stopped run's task would be killed by its cancel.
        let sink = RecordingSink()
        let client = MockResticClient()
            .onBackup(.success(successOutcome()))
            .onForget(.failure(ResticError.cancelled))
        let run = Task { await BackupRunEngine.perform(plan: makePlan(), repository: Repository(), sink: sink.serving(client)) }
        run.cancel()
        await run.value

        #expect(await eventually(within: 60) { !sink.refreshCancelled.isEmpty })
        #expect(sink.refreshCancelled == [false], "log was \(sink.log)")
    }

    @Test("a retention skip is never summarised as an unreadable item")
    func retentionSkipIsNotAnUnreadableItem() async throws {
        let sink = RecordingSink()
        let client = MockResticClient()
            .onBackup(.success(successOutcome()))
            .onForget(.failure(ResticError.commandFailed(exitCode: 11, message: "locked")))
        await BackupRunEngine.perform(plan: makePlan(), repository: Repository(), sink: sink.serving(client))

        let record = try #require(sink.deliveredRecords.first)
        let summary = PlanStatus.summary(of: record)
        // The engine and the plan row key on the same spelling.
        #expect(summary.message?.hasPrefix(RunRecord.retentionSkippedPrefix) == true, "message was \(String(describing: summary.message))")
        // The message already says it; the row does not repeat it as a fact.
        #expect(summary.facts.isEmpty, "facts were \(summary.facts)")
        #expect(!summary.facts.contains { $0.contains("unreadable") })
        // Standalone (Activity's Detail column builds on this), the skip is
        // named — and still nothing is called unreadable.
        #expect(PlanStatus.facts(for: record) == ["Retention skipped"])
    }

    @Test("item errors from restic read as completed-with-errors")
    func partialReadRun() async throws {
        let sink = RecordingSink()
        let outcome = BackupOutcome(summary: nil, itemErrors: ["/etc/x: permission denied"], exitCode: 3)
        let client = MockResticClient().onBackup(.success(outcome))
        let plan = makePlan()
        await BackupRunEngine.perform(plan: plan, repository: Repository(), sink: sink.serving(client))

        #expect(sink.deliveredRecords[0].outcome == .completedWithErrors)
        #expect(sink.deliveredRecords[0].itemErrors == ["/etc/x: permission denied"])
    }

    @Test("restic's item errors are summarised as unreadable items")
    func partialReadRunSummary() async throws {
        let sink = RecordingSink()
        let outcome = BackupOutcome(summary: nil, itemErrors: ["/etc/x: permission denied"], exitCode: 3)
        let client = MockResticClient().onBackup(.success(outcome))
        await BackupRunEngine.perform(plan: makePlan(), repository: Repository(), sink: sink.serving(client))

        let summary = PlanStatus.summary(of: try #require(sink.deliveredRecords.first))
        #expect(summary.headline == "Backup completed with warnings")
        // The card lists the item itself, with its fixes; no message repeats
        // it, and with every item listed the facts drop the count too.
        #expect(summary.items == ["/etc/x: permission denied"])
        #expect(summary.message == nil)
        #expect(summary.facts.isEmpty)
    }

    @Test("restic's exit 3 is stored, and marks the snapshot it wrote incomplete")
    func exitThreeRecordsAnIncompleteSnapshot() async throws {
        let sink = RecordingSink()
        var outcome = successOutcome()
        outcome.itemErrors = ["/src/a.pdf: permission denied", "/src/Missing does not exist, skipping"]
        outcome.exitCode = 3
        let client = MockResticClient().onBackup(.success(outcome))
        await BackupRunEngine.perform(plan: makePlan(), repository: Repository(), sink: sink.serving(client))

        let record = try #require(sink.deliveredRecords.first)
        #expect(record.exitCode == 3)
        #expect(record.snapshotCompleteness == .incomplete)
        #expect(record.itemErrorCount == 2)
        #expect(Array(record.unreadableItems) == outcome.itemErrors)
    }

    @Test("the unreadable items' paths are stored beside their lines, for the fixes that act on them")
    func unreadablePathsAreStored() async throws {
        let sink = RecordingSink()
        var outcome = successOutcome()
        outcome.itemErrors = ["/src/a.pdf: permission denied", "walk failed"]
        outcome.itemPaths = ["/src/a.pdf: permission denied": "/src/a.pdf"]
        outcome.exitCode = 3
        let client = MockResticClient().onBackup(.success(outcome))
        await BackupRunEngine.perform(plan: makePlan(), repository: Repository(), sink: sink.serving(client))

        let record = try #require(sink.deliveredRecords.first)
        #expect(record.unreadableItemPaths == ["/src/a.pdf: permission denied": "/src/a.pdf"])
        // A record written before the field existed has no paths, not empty ones.
        let old = try JSONDecoder().decode(RunRecord.self, from: Data(#"{"kind":"backup","itemErrors":["/x: permission denied"],"itemErrorCount":1}"#.utf8))
        #expect(old.unreadableItemPaths == nil)
        let roundTrip = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(record))
        #expect(roundTrip.unreadableItemPaths == record.unreadableItemPaths)
    }

    @Test("warnings that leave every file in the snapshot never mark it incomplete")
    func completeSnapshotsStayCompleteThroughWarnings() async throws {
        // A skipped retention step: the snapshot is whole, only the forget
        // after it failed.
        let retention = RecordingSink()
        await BackupRunEngine.perform(
            plan: makePlan(),
            repository: Repository(),
            sink: retention.serving(MockResticClient()
                    .onBackup(.success(successOutcome()))
                    .onForget(.failure(ResticError.commandFailed(exitCode: 11, message: "locked"))))
        )

        // A reporting gap in restic's output: the run must never read clean,
        // but nothing restic read was lost, so nothing is counted unreadable.
        let decoding = RecordingSink()
        var gap = successOutcome()
        gap.decodingWarning = "1 restic message could not be decoded"
        await BackupRunEngine.perform(
            plan: makePlan(),
            repository: Repository(),
            sink: decoding.serving(MockResticClient().onBackup(.success(gap)))
        )

        // A failing after-success hook: the user's script, not the snapshot.
        let hook = RecordingSink()
        var plan = makePlan()
        var failing = BackupHook()
        failing.name = "notify"
        failing.event = .afterSuccess
        failing.command = "exit 1"
        plan.hooks = [failing]
        await BackupRunEngine.perform(
            plan: plan,
            repository: Repository(),
            sink: hook.serving(MockResticClient().onBackup(.success(successOutcome())))
        )

        let retentionRecord = try #require(retention.deliveredRecords.first)
        #expect(retentionRecord.outcome == .completedWithErrors)
        #expect(retentionRecord.itemErrors.contains { $0.hasPrefix("Retention skipped") })

        let decodingRecord = try #require(decoding.deliveredRecords.first)
        #expect(decodingRecord.outcome == .completedWithErrors)
        #expect(decodingRecord.itemErrors == ["1 restic message could not be decoded"])
        #expect(decodingRecord.itemErrorCount == 0)

        let hookRecord = try #require(hook.deliveredRecords.first)
        #expect(hookRecord.outcome == .completedWithErrors)
        #expect(!hookRecord.hookMessages.isEmpty)

        for record in [retentionRecord, decodingRecord, hookRecord] {
            #expect(record.exitCode == 0)
            #expect(record.snapshotCompleteness == .complete, "\(record.itemErrors) \(record.hookMessages)")
        }
    }

    @Test("the unreadable items stop before the decoding and retention lines stored after them")
    func unreadableItemsExcludeTrailingLines() async throws {
        let sink = RecordingSink()
        var outcome = successOutcome()
        outcome.itemErrors = (1 ... 60).map { "/src/file\($0).pdf: permission denied" }
        outcome.decodingWarning = "2 restic messages could not be decoded"
        outcome.exitCode = 3
        let client = MockResticClient()
            .onBackup(.success(outcome))
            .onForget(.failure(ResticError.commandFailed(exitCode: 11, message: "locked")))
        await BackupRunEngine.perform(plan: makePlan(), repository: Repository(), sink: sink.serving(client))

        let record = try #require(sink.deliveredRecords.first)
        #expect(record.itemErrorCount == 60)
        #expect(record.unreadableItems.count == RunRecord.storedItemErrorLimit)
        #expect(record.unreadableItems.count == 50)
        #expect(!record.unreadableItems.contains { $0.contains("Retention skipped") || $0.contains("could not be decoded") })
        // The order the invariant promises: unreadable lines, then the
        // decoding warning, then the retention line — last.
        try #require(record.itemErrors.count == 52, "lines were \(record.itemErrors.suffix(3))")
        #expect(record.itemErrors[50] == "2 restic messages could not be decoded")
        #expect(record.itemErrors[51].hasPrefix("Retention skipped"))
    }

    private func hook(_ name: String, event: BackupHook.Event, command: String) -> BackupHook {
        var hook = BackupHook()
        hook.name = name
        hook.event = event
        hook.command = command
        return hook
    }

    @Test("backup and forget run inside the run's transcript; hooks are noted by verdict")
    func backupAndForgetAreTranscribed() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onBackup(.success(successOutcome()))
        var plan = makePlan()
        plan.hooks = [
            hook("prepare", event: .beforeBackup, command: "true"),
            hook("celebrate", event: .afterSuccess, command: "true"),
        ]
        await BackupRunEngine.perform(plan: plan, repository: Repository(), sink: sink.serving(client))

        #expect(client.transcriptBound["backup"] == true)
        #expect(client.transcriptBound["forget"] == true)
        #expect(sink.deliveredTranscripts.count == 1)
        let notes = sink.deliveredNotes
        #expect(notes.contains("Hook “prepare” succeeded."), "notes were \(notes)")
        #expect(notes.contains("Hook “celebrate” succeeded."), "notes were \(notes)")
        #expect(notes.contains("Retention removed 0 backups"), "notes were \(notes)")
    }

    @Test("a failed forget is noted in the log as a retention skip")
    func failedForgetIsNoted() async throws {
        let sink = RecordingSink()
        let client = MockResticClient()
            .onBackup(.success(successOutcome()))
            .onForget(.failure(ResticError.commandFailed(exitCode: 11, message: "locked")))
        await BackupRunEngine.perform(plan: makePlan(), repository: Repository(), sink: sink.serving(client))

        #expect(sink.deliveredRecords.first?.outcome == .completedWithErrors)
        #expect(sink.deliveredNotes.contains { $0.hasPrefix("Retention skipped:") }, "notes were \(sink.deliveredNotes)")
    }

    @Test("the record's exit code is the first restic exit the transcript saw")
    func recordKeepsTheFirstExitCode() async throws {
        // A partial backup, then a clean forget: the run's code is the
        // backup's own, the first restic exit the transcript saw.
        let partial = RecordingSink()
        var outcome = successOutcome()
        outcome.exitCode = 3
        outcome.itemErrors = ["/src/a: permission denied"]
        await BackupRunEngine.perform(
            plan: makePlan(),
            repository: Repository(),
            sink: partial.serving(MockResticClient().onBackup(.success(outcome)).onExit("backup", 3).onExit("forget", 0))
        )
        #expect(partial.deliveredRecords.first?.exitCode == 3)

        // A failed backup: nothing on the success path set it, and restic's
        // own code must still reach the record.
        let failed = RecordingSink()
        await BackupRunEngine.perform(
            plan: makePlan(),
            repository: Repository(),
            sink: failed.serving(MockResticClient()
                    .onBackup(.failure(ResticError.commandFailed(exitCode: 12, message: "wrong password")))
                    .onExit("backup", 12))
        )
        let failedRecord = try #require(failed.deliveredRecords.first)
        #expect(failedRecord.outcome == .failed)
        #expect(failedRecord.exitCode == 12)

        // A before-hook that aborts: restic never ran, so there is no code.
        let aborted = RecordingSink()
        var plan = makePlan()
        var gate = hook("gate", event: .beforeBackup, command: "exit 1")
        gate.failureBehaviour = .abortBackup
        plan.hooks = [gate]
        await BackupRunEngine.perform(
            plan: plan,
            repository: Repository(),
            sink: aborted.serving(MockResticClient().onExit("backup", 0))
        )
        let abortedRecord = try #require(aborted.deliveredRecords.first)
        #expect(abortedRecord.outcome == .failed)
        #expect(abortedRecord.exitCode == nil)
        #expect(aborted.deliveredNotes == ["Hook “gate” exited 1."])
    }

    @Test("the blocked-item tally counts every error, not the 50 kept")
    func tallyCountsPastTheCap() async throws {
        // A home-folder backup without Full Disk Access easily passes the
        // cap; a tally of the stored sample would say "50 blocked, 0 denied".
        let sink = RecordingSink()
        var outcome = successOutcome()
        outcome.itemErrors = (1 ... 60).map { "/Users/u/Library/F\($0): open /Users/u/Library/F\($0): operation not permitted" }
            + ["/Users/u/locked.txt: open /Users/u/locked.txt: permission denied"]
        outcome.exitCode = 3
        let client = MockResticClient().onBackup(.success(outcome))
        await BackupRunEngine.perform(plan: makePlan(), repository: Repository(), sink: sink.serving(client))

        let record = try #require(sink.deliveredRecords.first)
        // The stored lines themselves: `unreadableItems` slices to 50 on its
        // own, so it could not tell a missing cap from a working one.
        #expect(record.itemErrors.count == 50, "stored \(record.itemErrors.count) lines")
        #expect(record.itemErrorCount == 61)
        #expect(record.itemErrorTally == ItemErrorDiagnosis.Tally(blockedByMacOS: 60, deniedByFilePermissions: 1))
    }
}

@MainActor
@Suite("maintenance run engine")
struct MaintenanceRunEngineTests {
    final class RecordingSink: MaintenanceRunEngine.Sink {
        var log: [String] = []
        var deliveredRecords: [RunRecord] = []
        var deliveredTranscripts: [RunTranscript.Contents] = []
        var cancellationMessage = "cancelled in test"
        func label(of repository: Repository) -> String { repository.label(among: [repository]) }

        /// What `service()` answers; set by `serving(_:)`.
        var client = MockResticClient()
        func serving(_ client: MockResticClient) -> Self {
            self.client = client
            return self
        }

        func service() throws -> any ResticClient { client }
        func context(for repository: Repository) async throws -> RepositoryContext {
            log.append("context")
            return RepositoryContext(repository: repository, password: "test")
        }

        func lineReporter(repositoryID: UUID) -> @Sendable (String) -> Void {
            { [weak self] _ in Task { @MainActor in self?.log.append("prune-line") } }
        }

        func stampMaintenance(repositoryID: UUID, task: MaintenanceTask, at date: Date) {
            log.append("stamp:\(task.rawValue)")
        }

        func markPasswordMissing(repositoryID: UUID) {
            log.append("password-missing")
        }

        func markDriveAway(repositoryID: UUID) {
            log.append("drive-away")
        }

        func markServerAway(repositoryID: UUID) {
            log.append("server-away")
        }

        func advanceCheckDataSlice(repositoryID: UUID) {
            log.append("advance-slice")
        }

        /// The canned answer to a server probe; every ask is logged.
        var probeAnswer: ServerProbe.Outcome? = .reachable

        func probeServer(of repository: Repository) async -> ServerProbe.Outcome? {
            log.append("probe")
            return probeAnswer
        }

        func noteAuthFailure(_ error: Error, repositoryID: UUID) {
            log.append("auth-noted")
        }

        func deliver(record: RunRecord, repository: Repository, transcript: RunTranscript.Contents) async {
            log.append("deliver:\(record.outcome)")
            deliveredRecords.append(record)
            deliveredTranscripts.append(transcript)
        }

        func refreshSnapshots(repositoryID: UUID) async {
            log.append("refresh:cancelled=\(Task.isCancelled)")
        }

        func scheduleSnapshotRefresh(repositoryID: UUID) {
            log.append("refresh-scheduled")
            // The sink's whole job: run the refresh outside the engine's
            // (possibly cancelled) task.
            Task { await refreshSnapshots(repositoryID: repositoryID) }
        }

        func makeHookRunner() -> HookRunner {
            HookRunner(runner: ResticRunner())
        }

        /// The canned answer to a reconnect; every ask is logged.
        var reconnectAnswer: [ShareReconnect] = []

        func reconnectShares(volumes: [String]) async -> [ShareReconnect] {
            log.append("reconnect:\(volumes.joined(separator: ","))")
            return reconnectAnswer
        }
    }

    @Test("a clean check is delivered succeeded with its verdict")
    func cleanCheck() async throws {
        let sink = RecordingSink()
        var summary = ResticSummary()
        summary.numErrors = 0
        let client = MockResticClient().onCheck(.success(summary))
        await MaintenanceRunEngine.perform(
            repository: Repository(),
            task: .check,
            readDataPercentOverride: nil,
            sink: sink.serving(client)
        )
        #expect(sink.deliveredRecords[0].outcome == .succeeded)
        #expect(sink.deliveredRecords[0].detailText == "No errors found.")
        #expect(sink.log.contains("stamp:check"))
    }

    @Test("a scheduled check reads the rotation's next slice, says so and moves it on; one asked for by hand reads what it was asked")
    func checkReadsTheRotation() async throws {
        var repository = Repository()
        repository.maintenance = .forNewRepository(kind: .local)
        repository.maintenance.nextCheckDataSlice = 3
        func check(override: Int?, answer: Result<ResticSummary?, Error> = .success(ResticSummary())) async -> (RecordingSink, MockResticClient) {
            let sink = RecordingSink()
            let client = MockResticClient().onCheck(answer)
            await MaintenanceRunEngine.perform(
                repository: repository, task: .check, readDataPercentOverride: override,
                sink: sink.serving(client)
            )
            return (sink, client)
        }

        let (scheduled, scheduledClient) = await check(override: nil)
        #expect(scheduledClient.checkSubsets == [.slice(3, of: 12)])
        #expect(scheduled.deliveredRecords.first?.checkRead == "part 3 of 12")
        #expect(scheduled.log.contains("advance-slice"))

        // By hand: what was asked, the rotation left where it was.
        let (byHand, byHandClient) = await check(override: 5)
        #expect(byHandClient.checkSubsets == [.percent(5)])
        #expect(byHand.deliveredRecords.first?.checkRead == "5% of the data")
        #expect(!byHand.log.contains("advance-slice"))
        let (structure, structureClient) = await check(override: 0)
        #expect(structureClient.checkSubsets == [nil])
        #expect(structure.deliveredRecords.first?.checkRead == "structure only")

        // A check restic could not finish read nothing: the slice waits.
        let (failed, _) = await check(override: nil, answer: .failure(ResticError.commandFailed(exitCode: 1, message: "Fatal: boom")))
        #expect(failed.deliveredRecords.first?.outcome == .failed)
        #expect(!failed.log.contains("advance-slice"))
    }

    @Test("a check of a server out of reach waits for it: Skipped in its words, restic not asked, nothing stamped")
    func checkWaitsForAnUnreachableServer() async throws {
        let sink = RecordingSink()
        sink.probeAnswer = .unreachable("it did not answer within 10 seconds")
        let client = MockResticClient().onCheck(.success(ResticSummary()))
        var repository = Repository()
        repository.kind = .sftp
        repository.sftpHost = "nas"
        await MaintenanceRunEngine.perform(
            repository: repository,
            task: .check,
            readDataPercentOverride: nil,
            sink: sink.serving(client)
        )
        let record = try #require(sink.deliveredRecords.first)
        #expect(record.outcome == .skipped)
        #expect(record.detailText == "“nas” cannot be reached (it did not answer within 10 seconds).")
        #expect(client.callLog.isEmpty)
        #expect(sink.log.contains("server-away"))
        #expect(!sink.log.contains { $0.hasPrefix("stamp:") })
    }

    @Test("a check whose repository's drive is away waits for it: Skipped in the skip's words, restic not asked, nothing stamped, and the hooks for any end run")
    func checkWaitsForAnAwayDrive() async throws {
        let volume = "SwiftResticAbsentDrive-\(UUID().uuidString)"
        var repository = Repository()
        repository.kind = .local
        repository.localPath = "/Volumes/\(volume)/restic"
        var hook = BackupHook()
        hook.name = "after any"
        hook.event = .afterAnyMaintenance
        hook.command = "exit 3"
        hook.failureBehaviour = .ignore
        repository.hooks = [hook]

        // No share saved for it: the reconnect answers nothing.
        let sink = RecordingSink()
        let untouched = MockResticClient().onCheck(.success(ResticSummary()))
        await MaintenanceRunEngine.perform(
            repository: repository, task: .check, readDataPercentOverride: nil,
            sink: sink.serving(untouched)
        )
        #expect(untouched.callLog.isEmpty)
        let record = try #require(sink.deliveredRecords.first)
        #expect(record.outcome == .skipped)
        #expect(record.detailText == "“\(volume)” is not connected.")
        #expect(record.failureMessage == nil)
        #expect(!sink.log.contains { $0.hasPrefix("stamp") }, "log was \(sink.log)")
        #expect(sink.log.contains("drive-away"), "log was \(sink.log)")
        // The hooks for any end ran, as for a skipped backup.
        #expect(!record.hookMessages.isEmpty)
    }

    @Test("a check on a repository whose network share is away reconnects it first: out of reach it waits unstamped, refused it fails in those words")
    func checkReconnectsItsShare() async throws {
        let volume = "SwiftResticAbsentShare-\(UUID().uuidString)"
        var repository = Repository()
        repository.kind = .local
        repository.localPath = "/Volumes/\(volume)/restic"

        let outOfReach = RecordingSink()
        let unreachable = "the server could not be reached"
        outOfReach.reconnectAnswer = [ShareReconnect(volumeName: volume, url: "smb://me@nas.local/\(volume)", outcome: .unreachable(unreachable))]
        let waiting = MockResticClient().onCheck(.success(ResticSummary()))
        await MaintenanceRunEngine.perform(
            repository: repository, task: .check, readDataPercentOverride: nil,
            sink: outOfReach.serving(waiting)
        )
        #expect(outOfReach.log.filter { $0.hasPrefix("reconnect") } == ["reconnect:\(volume)"], "log was \(outOfReach.log)")
        #expect(waiting.callLog.isEmpty)
        let skipped = try #require(outOfReach.deliveredRecords.first)
        #expect(skipped.outcome == .skipped)
        #expect(skipped.detailText == "“\(volume)” is not connected. Reconnecting “\(volume)” failed: \(unreachable).")
        #expect(!outOfReach.log.contains { $0.hasPrefix("stamp") }, "log was \(outOfReach.log)")
        #expect(outOfReach.log.contains("drive-away"))

        let refusing = RecordingSink()
        let refused = "the share did not accept the user name and password"
        refusing.reconnectAnswer = [ShareReconnect(volumeName: volume, url: "smb://me@nas.local/\(volume)", outcome: .refused(refused))]
        let untouched = MockResticClient().onCheck(.success(ResticSummary()))
        await MaintenanceRunEngine.perform(
            repository: repository, task: .check, readDataPercentOverride: nil,
            sink: refusing.serving(untouched)
        )
        #expect(untouched.callLog.isEmpty)
        let failed = try #require(refusing.deliveredRecords.first)
        #expect(failed.outcome == .failed)
        #expect(failed.failureMessage == "“\(volume)” is not connected. Reconnecting “\(volume)” failed: \(refused).")
        #expect(refusing.log.contains("stamp:check"))
        #expect(!refusing.log.contains("drive-away"))
        #expect(failed.refusedShares == [volume])
    }

    @Test("a cancelled check still refreshes snapshots, outside the cancelled task")
    func cancelledCheckRefreshesOutsideTheCancelledTask() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onCheck(.failure(ResticError.cancelled))
        let task = Task {
            await MaintenanceRunEngine.perform(
                repository: Repository(),
                task: .check,
                readDataPercentOverride: nil,
                sink: sink.serving(client)
            )
        }
        task.cancel()
        await task.value

        #expect(sink.deliveredRecords[0].outcome == .cancelled)
        // The closing refresh must actually run — the user still wants a
        // fresh listing after a prune — and it must not inherit the cancel
        // that stopped the check, or it dies mid-flight and leaves the
        // listing stale. The scheduled task lands asynchronously, so poll
        // for it rather than trusting job ordering.
        #expect(
            await eventually(within: 5) { sink.log.contains("refresh:cancelled=false") },
            "log was \(sink.log)"
        )
    }

    @Test("a check that found errors is a warning, and suggests prune when restic does")
    func checkWithErrors() async throws {
        let sink = RecordingSink()
        var summary = ResticSummary()
        summary.numErrors = 2
        summary.suggestPrune = true
        let client = MockResticClient().onCheck(.success(summary))
        await MaintenanceRunEngine.perform(
            repository: Repository(),
            task: .check,
            readDataPercentOverride: nil,
            sink: sink.serving(client)
        )
        #expect(sink.deliveredRecords[0].outcome == .completedWithErrors)
        // One sentence for the verdict, so the Detail column carries it
        // whole; restic's advice is the second.
        #expect(sink.deliveredRecords[0].detailText
            == "2 errors — restic repair can recover some damage. A cleanup is suggested.")
        #expect(RunRecordPresentation.detail(for: sink.deliveredRecords[0])
            == "2 errors — restic repair can recover some damage")
    }

    @Test("a missing password records nothing and stamps nothing")
    func passwordMissingLeavesNoTrace() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onCheck(.failure(ResticError.passwordMissing(repositoryName: "R")))
        await MaintenanceRunEngine.perform(
            repository: Repository(),
            task: .check,
            readDataPercentOverride: nil,
            sink: sink.serving(client)
        )
        #expect(sink.log == ["context", "password-missing"])
        #expect(sink.deliveredRecords.isEmpty)
    }

    @Test("a successful check whose after-hook failed reads as completed with warnings")
    func failedMaintenanceHookUpgradesTheOutcome() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onCheck(.success(ResticSummary()))
        var repository = Repository()
        var hook = BackupHook()
        hook.name = "notify"
        hook.event = .afterMaintenanceSuccess
        hook.command = "exit 3"
        hook.failureBehaviour = .ignore
        repository.hooks = [hook]
        await MaintenanceRunEngine.perform(
            repository: repository,
            task: .check,
            readDataPercentOverride: nil,
            sink: sink.serving(client)
        )
        // Same rule as the backup engine: the hook's failure is recorded and
        // it turns the record amber — a problem dot, a notifyOnFailure —
        // without ever calling the check itself a failure.
        #expect(sink.deliveredRecords[0].outcome == .completedWithErrors)
        #expect(!sink.deliveredRecords[0].hookMessages.isEmpty)
    }

    @Test("check runs inside the run's transcript and its delivery carries it")
    func checkIsTranscribed() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onCheck(.success(ResticSummary())).onExit("check", 0)
        await MaintenanceRunEngine.perform(
            repository: Repository(),
            task: .check,
            readDataPercentOverride: nil,
            sink: sink.serving(client)
        )
        #expect(client.transcriptBound["check"] == true)
        #expect(sink.deliveredRecords.count == 1)
        #expect(sink.deliveredTranscripts.count == 1)
        #expect(sink.deliveredRecords.first?.exitCode == 0)
        #expect(sink.deliveredTranscripts.first?.firstExitCode == 0)
    }
}

/// Apply Retention Now's run: a forget recorded under the plan, with no
/// hooks, no run stamp and no alert beyond what the sink delivers.
@MainActor
@Suite("retention run engine")
struct RetentionRunEngineTests {
    /// Answers `service()` with the mock itself: this sink has nothing else
    /// to keep apart from the log.
    final class RecordingSink: RetentionRunEngine.Sink {
        let client: MockResticClient
        var log: [String] = []
        var deliveredRecords: [RunRecord] = []
        var deliveredTranscripts: [RunTranscript.Contents] = []
        init(client: MockResticClient) { self.client = client }

        func cancellationMessage(for planID: UUID) -> String { "cancelled \(planID)" }
        func label(of plan: BackupPlan) -> String { plan.label(among: [plan]) }
        func label(of repository: Repository) -> String { repository.label(among: [repository]) }
        func service() throws -> any ResticClient { client }
        func context(for repository: Repository) async throws -> RepositoryContext {
            log.append("context")
            return RepositoryContext(repository: repository, password: "test")
        }
        func noteAuthFailure(_ error: Error, repositoryID: UUID) {
            log.append("auth-noted")
        }
        func deliverRetention(record: RunRecord, plan: BackupPlan, transcript: RunTranscript.Contents) async {
            log.append("deliver:\(record.outcome)")
            deliveredRecords.append(record)
            deliveredTranscripts.append(transcript)
        }
        func scheduleSnapshotRefresh(repositoryID: UUID) {
            log.append("schedule-refresh")
        }

        /// The canned answer to a reconnect; every ask is logged.
        var reconnectAnswer: [ShareReconnect] = []

        func reconnectShares(volumes: [String]) async -> [ShareReconnect] {
            log.append("reconnect:\(volumes.joined(separator: ","))")
            return reconnectAnswer
        }

        /// The canned answer to a server probe; every ask is logged.
        var probeAnswer: ServerProbe.Outcome? = .reachable

        func probeServer(of repository: Repository) async -> ServerProbe.Outcome? {
            log.append("probe")
            return probeAnswer
        }
    }

    private func makePlan() -> BackupPlan {
        var plan = BackupPlan()
        plan.repositoryID = Repository().id
        plan.path = "/tmp/Retention Plan"
        return plan
    }

    @Test("Apply Retention on a repository whose network share is away reconnects it first; a share that stays away fails the run in those words, no forget")
    func retentionReconnectsItsShare() async throws {
        let volume = "SwiftResticAbsentShare-\(UUID().uuidString)"
        var repository = Repository()
        repository.kind = .local
        repository.localPath = "/Volumes/\(volume)/restic"
        let client = MockResticClient().onForget(.success(2))
        let sink = RecordingSink(client: client)
        sink.reconnectAnswer = [ShareReconnect(
            volumeName: volume, url: "smb://me@nas.local/\(volume)",
            outcome: .refused("the share did not accept the user name and password")
        )]
        await RetentionRunEngine.perform(plan: makePlan(), repository: repository, sink: sink)

        #expect(sink.log == ["context", "reconnect:\(volume)", "deliver:failed", "schedule-refresh"], "log was \(sink.log)")
        #expect(client.callLog.isEmpty)
        #expect(sink.deliveredRecords.first?.failureMessage
            == "“\(volume)” is not connected. Reconnecting “\(volume)” failed: the share did not accept the user name and password.")
        #expect(sink.deliveredRecords.first?.refusedShares == [volume])
    }

    @Test("Apply Retention on a drive that is away, with no share saved for it, fails the run in those words, no forget")
    func retentionOnADriveAway() async throws {
        let volume = "SwiftResticAbsentDrive-\(UUID().uuidString)"
        var repository = Repository()
        repository.kind = .local
        repository.localPath = "/Volumes/\(volume)/restic"
        let client = MockResticClient().onForget(.success(2))
        let sink = RecordingSink(client: client)
        await RetentionRunEngine.perform(plan: makePlan(), repository: repository, sink: sink)

        #expect(sink.log == ["context", "reconnect:\(volume)", "deliver:failed", "schedule-refresh"], "log was \(sink.log)")
        #expect(client.callLog.isEmpty)
        #expect(sink.deliveredRecords.first?.failureMessage == "“\(volume)” is not connected.")
        #expect(sink.deliveredRecords.first?.refusedShares == nil)
    }

    @Test("Apply Retention on a network repository whose server is out of reach fails the run in those words, no forget")
    func retentionOnAServerAway() async throws {
        var repository = Repository()
        repository.kind = .rest
        repository.restURL = "https://nas.local:8000/"
        let client = MockResticClient().onForget(.success(2))
        let sink = RecordingSink(client: client)
        sink.probeAnswer = .unreachable("the connection timed out")
        await RetentionRunEngine.perform(plan: makePlan(), repository: repository, sink: sink)

        #expect(sink.log == ["context", "probe", "deliver:failed", "schedule-refresh"], "log was \(sink.log)")
        #expect(client.callLog.isEmpty)
        #expect(sink.deliveredRecords.first?.failureMessage
            == RunRecord.serverUnreachableReason(repositoryName: sink.label(of: repository), why: "the connection timed out"))
    }

    @Test("a clean run records a forget under the plan and refreshes the listing")
    func cleanRunRecordsAForget() async throws {
        let client = MockResticClient().onForget(.success(2)).onExit("forget", 0)
        let sink = RecordingSink(client: client)
        let plan = makePlan()
        await RetentionRunEngine.perform(plan: plan, repository: Repository(), sink: sink)

        let record = try #require(sink.deliveredRecords.first)
        #expect(record.kind == .forget)
        #expect(record.planID == plan.id)
        #expect(record.planName == "Retention Plan")
        #expect(record.outcome == .succeeded)
        #expect(record.detailText == "Removed 2 backups. Their data stays until the next cleanup.")
        #expect(record.exitCode == 0)
        // The sink has no markPlanRun, so no stamp is possible; no hooks run
        // and no backup is asked for.
        #expect(sink.log == ["context", "deliver:succeeded", "schedule-refresh"], "log was \(sink.log)")
        #expect(client.callLog == ["forget"])
        #expect(client.transcriptBound["forget"] == true)
    }

    @Test("a forget the repository refused fails the run in those words, never as a removal")
    func refusedForgetFailsTheRun() async throws {
        let refusal = ResticError.snapshotsNotRemoved(removed: 1, refused: 1, reason: "403 Forbidden")
        let client = MockResticClient().onForget(.failure(refusal)).onExit("forget", 3)
        let sink = RecordingSink(client: client)
        let plan = makePlan()
        await RetentionRunEngine.perform(plan: plan, repository: Repository(), sink: sink)

        let record = try #require(sink.deliveredRecords.first)
        #expect(record.outcome == .failed)
        #expect(record.failureMessage == refusal.errorDescription)
        #expect(record.detailText == nil)
        #expect(record.retentionRefused == 1)
        #expect(record.exitCode == 3)
        #expect(sink.log.last == "schedule-refresh")
    }

    @Test("a locked repository fails the run, and a stop reads cancelled")
    func lockedRepositoryFailsAndCancelReadsCancelled() async throws {
        let locked = MockResticClient().onForget(.failure(
            ResticError.commandFailed(exitCode: 11, message: "repository is already locked")
        ))
        let lockedSink = RecordingSink(client: locked)
        let plan = makePlan()
        await RetentionRunEngine.perform(plan: plan, repository: Repository(), sink: lockedSink)
        let failed = try #require(lockedSink.deliveredRecords.first)
        #expect(failed.outcome == .failed)
        #expect(failed.failureMessage?.contains("locked") == true)
        #expect(lockedSink.log.contains("auth-noted"))
        // A forget that failed may still have removed some snapshots before
        // it did: the listing is refreshed whatever happened.
        #expect(lockedSink.log.last == "schedule-refresh")

        let stopped = MockResticClient().onForget(.failure(CancellationError()))
        let stoppedSink = RecordingSink(client: stopped)
        await RetentionRunEngine.perform(plan: plan, repository: Repository(), sink: stoppedSink)
        let cancelled = try #require(stoppedSink.deliveredRecords.first)
        #expect(cancelled.outcome == .cancelled)
        #expect(cancelled.failureMessage == stoppedSink.cancellationMessage(for: plan.id))
        #expect(stoppedSink.log.last == "schedule-refresh")
    }
}
