import Foundation
import Testing

/// The refresh members differ per engine, so each subclass declares its own.
@MainActor
class EngineRecordingSink {
    var log: [String] = []
    var deliveredRecords: [RunRecord] = []

    var client = MockResticClient()
    func serving(_ client: MockResticClient) -> Self {
        self.client = client
        return self
    }

    func label(of repository: Repository) -> String { repository.label(among: [repository]) }
    func service() throws -> any ResticClient { client }
    func context(for repository: Repository) async throws -> RepositoryContext {
        log.append("context")
        return RepositoryContext(repository: repository, password: "test")
    }

    func noteAuthFailure(_ error: Error, repositoryID: UUID) {
        log.append("auth-noted")
    }

    var reconnectAnswer: [ShareReconnect] = []

    func reconnectShares(volumes: [String]) async -> [ShareReconnect] {
        log.append("reconnect:\(volumes.joined(separator: ","))")
        return reconnectAnswer
    }

    var probeAnswer: ServerProbe.Outcome? = .reachable

    /// Runs inside the probe, in the run's task: a Stop landing while the
    /// server is asked.
    var duringProbe: () -> Void = {}

    func probeServer(of repository: Repository) async -> ServerProbe.Outcome? {
        log.append("probe")
        duringProbe()
        return probeAnswer
    }

    /// The file system's answer: the tests' away drives are /Volumes
    /// folders no Mac mounts.
    func isMounted(volumeOf path: String) async -> Bool? {
        VolumePresence.isMounted(volumeOf: path)
    }
}

/// restic is mocked. The stub-shell and real-restic suites own everything below the
/// `ResticClient` seam.
@MainActor
@Suite("backup run engine")
struct BackupRunEngineTests {
    final class RecordingSink: EngineRecordingSink, BackupRunEngine.Sink {
        var deliveredTranscripts: [RunTranscript.Contents] = []

        /// Per plan, so a test can tell the engine asked about its own run.
        var cancellationMessage: String { "cancelled in test" }
        func label(of plan: BackupPlan) -> String { plan.label(among: [plan]) }

        /// Runs inside each phase write, in the run's task: a Stop landing
        /// as a step begins.
        var duringPhase: (PlanActivity.Phase) -> Void = { _ in }

        func setActivityPhase(_ phase: PlanActivity.Phase, for planID: UUID) {
            log.append("phase:\(phase)")
            duringPhase(phase)
        }

        func endRetentionStep(for planID: UUID) {
            log.append("retention-step-ended")
        }

        func progressReporter(planID: UUID) -> @Sendable (OperationProgress) -> Void {
            log.append("reporter-built")
            return { _ in }
        }

        func markPlanRun(_ planID: UUID, at date: Date, wrote stamp: BackupStamp) {
            log.append("mark:\(stamp)")
        }

        var refreshCancelled: [Bool] = []
        func refreshSnapshots(repositoryID: UUID) async {
            log.append("refresh")
            refreshCancelled.append(Task.isCancelled)
        }

        func scheduleSnapshotRefresh(repositoryID: UUID) {
            log.append("refresh-scheduled")
            Task { await refreshSnapshots(repositoryID: repositoryID) }
        }

        func noteRepositoryAway(repositoryID: UUID, away: ReachabilityGate.Away, reason: String) {
            log.append("away:\(away):\(reason)")
        }

        func deliver(record: RunRecord, transcript: RunTranscript.Contents) async {
            log.append("deliver:\(record.outcome)")
            deliveredRecords.append(record)
            deliveredTranscripts.append(transcript)
        }

        var deliveredNotes: [String] {
            deliveredTranscripts.flatMap { $0.entries.filter { $0.kind == .note }.map(\.text) }
        }
    }

    private func makePlan() -> BackupPlan {
        var plan = BackupPlan()
        plan.repositoryID = Repository().id
        plan.path = "/tmp/engine-source"
        return plan
    }

    private func successOutcome(snapshotID: String? = "cafe0000") -> BackupOutcome {
        var summary = ResticSummary()
        summary.snapshotID = snapshotID
        summary.filesNew = 2
        summary.totalBytesProcessed = 1234
        return BackupOutcome(summary: summary, itemErrors: [], exitCode: 0)
    }

    @Test("a clean run backs up, applies retention, refreshes, delivers")
    func cleanRunSequencing() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onBackup(.success(successOutcome()))
        let plan = makePlan()
        await BackupRunEngine.perform(plan: plan, repository: Repository(), sink: sink.serving(client))

        // The success stamp must land before anything later can fail the
        // run, retention must follow a produced snapshot, and the closing
        // refresh must follow retention (lock ordering).
        #expect(sink.log == [
            "context",
            "phase:backingUp",
            "reporter-built",
            "mark:whole",
            "phase:applyingRetention",
            "retention-step-ended",
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
        let unreachable = "the server couldn’t be reached"
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
        #expect(outOfReach.deliveredNotes.contains("Couldn’t reconnect the network share smb://me@nas.local/\(volume): \(unreachable)."))

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
        sink.reconnectAnswer = [ShareReconnect(volumeName: away, url: "smb://nas.local/\(away)", outcome: .unreachable("the server couldn’t be reached"))]
        let client = MockResticClient().onBackup(.failure(ResticError.commandFailed(exitCode: 1, message: RunRecord.everySourceMissingMessage)))
        var plan = makePlan()
        plan.path = "/Volumes/\(away)/c"
        await BackupRunEngine.perform(plan: plan, repository: Repository(), sink: sink.serving(client))

        #expect(sink.log.filter { $0.hasPrefix("reconnect") } == ["reconnect:\(away)"], "log was \(sink.log)")
        let record = try #require(sink.deliveredRecords.first)
        #expect(record.outcome == .skipped)
        #expect(record.detailText
            == "“\(away)” is not connected. Reconnecting “\(away)” failed: the server couldn’t be reached.")

        let here = RecordingSink()
        await BackupRunEngine.perform(
            plan: makePlan(), repository: Repository(),
            sink: here.serving(MockResticClient().onBackup(.success(successOutcome())))
        )
        #expect(!here.log.contains { $0.hasPrefix("reconnect") }, "log was \(here.log)")
    }

    @Test("a backup that fills its repository's disk fails in plain words, marked for Free Up Space")
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
        #expect(sink.deliveredRecords[0].outcome == .succeeded)
    }

    @Test("a backup the password doesn't open is marked failed, noted for auth, delivered naming the location")
    func failedRun() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onBackup(
            .failure(ResticError.commandFailed(exitCode: 12, message: "wrong password"))
        )
        let plan = makePlan()
        let repository = Repository()
        await BackupRunEngine.perform(plan: plan, repository: repository, sink: sink.serving(client))

        #expect(sink.log.contains("mark:nothing"))
        #expect(sink.log.contains("auth-noted"))
        #expect(sink.deliveredRecords[0].outcome == .failed)
        #expect(sink.deliveredRecords[0].failureMessage == ResticError.wrongPassword(location: sink.label(of: repository)),
                "the failed backup does not name the location its password doesn't open")
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
        #expect(record.itemErrors == ["Retention skipped: the location was busy. They’re removed after the next backup."])
        // The snapshot was written; the run itself stays marked successful.
        #expect(sink.log.contains("mark:whole"))
    }

    @Test("a server out of reach skips the backup within seconds, its slot stamped, restic never asked")
    func unreachableServerSkipsTheBackup() async throws {
        let sink = RecordingSink()
        sink.probeAnswer = .unreachable("connection refused")
        let client = MockResticClient().onBackup(.success(successOutcome()))
        var repository = Repository()
        repository.kind = .sftp
        repository.sftpHost = "127.0.0.1"
        repository.sftpPath = "/app"
        await BackupRunEngine.perform(plan: makePlan(), repository: repository, sink: sink.serving(client))

        let record = try #require(sink.deliveredRecords.first)
        #expect(record.outcome == .skipped)
        #expect(record.detailText == "“127.0.0.1” cannot be reached (connection refused).")
        #expect(client.callLog.isEmpty)
        // Stamped, as a drive away is, so an hourly plan does not retry
        // every minute; the listing learns why at once.
        #expect(sink.log.contains("mark:nothing"))
        #expect(sink.log.contains("away:server:“127.0.0.1” cannot be reached (connection refused)."))
    }

    @Test("a Stop while the server is asked ends the run there: restic never asked, recorded as stopped")
    func stopDuringProbeEndsTheRun() async throws {
        let sink = RecordingSink()
        sink.duringProbe = { withUnsafeCurrentTask { $0?.cancel() } }
        let client = MockResticClient().onBackup(.success(successOutcome()))
        var repository = Repository()
        repository.kind = .sftp
        repository.sftpHost = "127.0.0.1"
        repository.sftpPath = "/app"
        let plan = makePlan()
        // Its own task, as the model gives a run: the cancel is the run's.
        let served = sink.serving(client)
        await Task { await BackupRunEngine.perform(plan: plan, repository: repository, sink: served) }.value

        let record = try #require(sink.deliveredRecords.first)
        #expect(record.outcome == .cancelled, "outcome was \(record.outcome)")
        #expect(record.failureMessage == "cancelled in test")
        #expect(client.callLog.isEmpty, "restic was asked: \(client.callLog)")
        #expect(!sink.log.contains("phase:backingUp"), "log was \(sink.log)")
    }

    @Test("a server that answers is backed up to; a local repository is never probed")
    func reachableServerAndLocalRepository() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onBackup(.success(successOutcome())).onForget(.success(0))
        var repository = Repository()
        repository.kind = .sftp
        repository.sftpHost = "127.0.0.1"
        repository.sftpPath = "/app"
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
            "Retention skipped: This storage doesn’t allow deleting (403 Forbidden), so 1 old backup stays. Allow deletions on the storage.",
        ])
        #expect(sink.log.contains("mark:whole"))
    }

    @Test("stopping a backup during its own retention step reads as cancelled, not a warning")
    func stopDuringRetentionIsACancellation() async throws {
        // The Plan menu's and the tray's "Stop Removing Old Backups", Pause
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
        #expect(record.failureMessage == "cancelled in test")
        #expect(!record.itemErrors.contains { $0.hasPrefix(RunRecord.retentionSkippedPrefix) }, "itemErrors were \(record.itemErrors)")
        #expect(sink.deliveredNotes.contains("Stopped removing old backups"), "notes were \(sink.deliveredNotes)")
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
        sink.duringPhase = { phase in
            if phase == .applyingRetention { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let served = sink.serving(client)
        await Task { await BackupRunEngine.perform(plan: makePlan(), repository: Repository(), sink: served) }.value

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
        #expect(summary.message?.hasPrefix(RunRecord.retentionSkippedOnScreenPrefix) == true, "message was \(String(describing: summary.message))")
        // The message already says it; the row does not repeat it as a fact.
        #expect(summary.facts.isEmpty, "facts were \(summary.facts)")
        #expect(!summary.facts.contains { $0.contains("unreadable") })
        // Standalone (Activity's Detail column builds on this), the skip is
        // named — and still nothing is called unreadable.
        #expect(PlanStatus.facts(for: record) == ["Old backups not removed"])
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
        #expect(summary.headline == "Some files skipped")
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

    @Test("restic's exit 3 with no unreadable item named still reads completed-with-errors")
    func exitThreeAloneIsNotClean() async throws {
        let sink = RecordingSink()
        var outcome = successOutcome()
        outcome.exitCode = 3
        let client = MockResticClient().onBackup(.success(outcome))
        await BackupRunEngine.perform(plan: makePlan(), repository: Repository(), sink: sink.serving(client))

        let record = try #require(sink.deliveredRecords.first)
        #expect(record.outcome == .completedWithErrors, "restic said it skipped files, yet the run read \(record.outcome)")
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
        // A record without the field has no paths, not empty ones.
        let old = try JSONDecoder().decode(RunRecord.self, from: Data(#"{"kind":"backup","itemErrors":["/x: permission denied"],"itemErrorCount":1}"#.utf8))
        #expect(old.unreadableItemPaths == nil)
        let encoded = try JSONEncoder().encode(record)
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""unreadableItemPaths":{"\/src\/a.pdf: permission denied":"\/src\/a.pdf"}"#))
        let roundTrip = try JSONDecoder().decode(RunRecord.self, from: encoded)
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

        let retentionRecord = try #require(retention.deliveredRecords.first)
        #expect(retentionRecord.outcome == .completedWithErrors)
        #expect(retentionRecord.itemErrors.contains { $0.hasPrefix("Retention skipped") })

        let decodingRecord = try #require(decoding.deliveredRecords.first)
        #expect(decodingRecord.outcome == .completedWithErrors)
        #expect(decodingRecord.itemErrors == ["1 restic message could not be decoded"])
        #expect(decodingRecord.itemErrorCount == 0)

        for record in [retentionRecord, decodingRecord] {
            #expect(record.exitCode == 0)
            #expect(record.snapshotCompleteness == .complete, "\(record.itemErrors)")
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

    @Test("backup and forget run inside the run's transcript")
    func backupAndForgetAreTranscribed() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onBackup(.success(successOutcome()))
        await BackupRunEngine.perform(plan: makePlan(), repository: Repository(), sink: sink.serving(client))

        #expect(client.transcriptBound["backup"] == true)
        #expect(client.transcriptBound["forget"] == true)
        #expect(sink.deliveredTranscripts.count == 1)
        let notes = sink.deliveredNotes
        #expect(notes.contains("Removed 0 backups"), "notes were \(notes)")
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
    final class RecordingSink: EngineRecordingSink, MaintenanceRunEngine.Sink {
        var deliveredTranscripts: [RunTranscript.Contents] = []
        var cancellationMessage = "cancelled in test"

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
            sink: sink.serving(client)
        )
        #expect(sink.deliveredRecords[0].outcome == .succeeded)
        #expect(sink.deliveredRecords[0].detailText == "No errors found.")
        #expect(sink.log.contains("stamp:check"))
    }

    @Test("a check removes restic's old caches, and a cleanup failure leaves the check standing")
    func checkCleansTheCache() async throws {
        let cleaned = MockResticClient().onCheck(.success(ResticSummary()))
        await MaintenanceRunEngine.perform(repository: Repository(), task: .check, sink: RecordingSink().serving(cleaned))
        #expect(cleaned.callLog.contains("cleanupCache"))

        let refused = MockResticClient()
            .onCheck(.success(ResticSummary()))
            .onCleanupCache(.failure(ResticError.commandFailed(exitCode: 1, message: "Fatal: boom")))
        let sink = RecordingSink()
        await MaintenanceRunEngine.perform(repository: Repository(), task: .check, sink: sink.serving(refused))
        #expect(sink.deliveredRecords.first?.outcome == .succeeded)
    }

    @Test("a check reads the rotation's next slice and moves it on; where storage bills reads, the structure only")
    func checkReadsTheRotation() async throws {
        var repository = Repository()
        repository.maintenance.nextCheckDataSlice = 3
        func check(_ repository: Repository, answer: Result<ResticSummary?, Error> = .success(ResticSummary())) async -> (RecordingSink, MockResticClient) {
            let sink = RecordingSink()
            let client = MockResticClient().onCheck(answer)
            await MaintenanceRunEngine.perform(repository: repository, task: .check, sink: sink.serving(client))
            return (sink, client)
        }

        let (sliced, slicedClient) = await check(repository)
        #expect(slicedClient.checkSubsets == [.slice(3, of: 12)])
        #expect(sliced.deliveredRecords.first?.outcome == .succeeded)
        #expect(sliced.log.contains("advance-slice"))

        var billed = repository
        billed.kind = .s3
        let (structure, structureClient) = await check(billed)
        #expect(structureClient.checkSubsets == [nil])
        #expect(!structure.log.contains("advance-slice"))

        // A check restic could not finish read nothing: the slice waits.
        let (failed, _) = await check(repository, answer: .failure(ResticError.commandFailed(exitCode: 1, message: "Fatal: boom")))
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
            sink: sink.serving(client)
        )
        let record = try #require(sink.deliveredRecords.first)
        #expect(record.outcome == .skipped)
        #expect(record.detailText == "“nas” cannot be reached (it did not answer within 10 seconds).")
        #expect(client.callLog.isEmpty)
        #expect(sink.log.contains("server-away"))
        #expect(!sink.log.contains { $0.hasPrefix("stamp:") })
    }

    @Test("a check whose repository's drive is away waits for it: Skipped in the skip's words, restic not asked, nothing stamped")
    func checkWaitsForAnAwayDrive() async throws {
        let volume = "SwiftResticAbsentDrive-\(UUID().uuidString)"
        var repository = Repository()
        repository.kind = .local
        repository.localPath = "/Volumes/\(volume)/restic"

        // No share saved for it: the reconnect answers nothing.
        let sink = RecordingSink()
        let untouched = MockResticClient().onCheck(.success(ResticSummary()))
        await MaintenanceRunEngine.perform(
            repository: repository, task: .check,
            sink: sink.serving(untouched)
        )
        #expect(untouched.callLog.isEmpty)
        let record = try #require(sink.deliveredRecords.first)
        #expect(record.outcome == .skipped)
        #expect(record.detailText == "“\(volume)” is not connected.")
        #expect(record.failureMessage == nil)
        #expect(!sink.log.contains { $0.hasPrefix("stamp") }, "log was \(sink.log)")
        #expect(sink.log.contains("drive-away"), "log was \(sink.log)")
    }

    @Test("a check on a repository whose network share is away reconnects it first: out of reach it waits unstamped, refused it fails in those words")
    func checkReconnectsItsShare() async throws {
        let volume = "SwiftResticAbsentShare-\(UUID().uuidString)"
        var repository = Repository()
        repository.kind = .local
        repository.localPath = "/Volumes/\(volume)/restic"

        let outOfReach = RecordingSink()
        let unreachable = "the server couldn’t be reached"
        outOfReach.reconnectAnswer = [ShareReconnect(volumeName: volume, url: "smb://me@nas.local/\(volume)", outcome: .unreachable(unreachable))]
        let waiting = MockResticClient().onCheck(.success(ResticSummary()))
        await MaintenanceRunEngine.perform(
            repository: repository, task: .check,
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
            repository: repository, task: .check,
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
        // One error, the fewest that is still a warning.
        summary.numErrors = 1
        summary.suggestPrune = true
        let client = MockResticClient().onCheck(.success(summary))
        await MaintenanceRunEngine.perform(
            repository: Repository(),
            task: .check,
            sink: sink.serving(client)
        )
        #expect(sink.deliveredRecords[0].outcome == .completedWithErrors)
        // The Result column shows the count; the way to Repair… and restic's
        // advice stay in the drawer.
        #expect(sink.deliveredRecords[0].detailText
            == "1 error found. Click Repair… to fix them. Freeing space is suggested.")
        #expect(RunRecordPresentation.detail(for: sink.deliveredRecords[0]) == "1 error found")
    }

    @Test("a missing password records nothing and stamps nothing")
    func passwordMissingLeavesNoTrace() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onCheck(.failure(ResticError.passwordMissing(repositoryName: "R")))
        await MaintenanceRunEngine.perform(
            repository: Repository(),
            task: .check,
            sink: sink.serving(client)
        )
        #expect(sink.log == ["context", "password-missing"])
        #expect(sink.deliveredRecords.isEmpty)
    }

    @Test("check runs inside the run's transcript and its delivery carries it")
    func checkIsTranscribed() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onCheck(.success(ResticSummary())).onExit("check", 0)
        await MaintenanceRunEngine.perform(
            repository: Repository(),
            task: .check,
            sink: sink.serving(client)
        )
        #expect(client.transcriptBound["check"] == true)
        #expect(sink.deliveredRecords.count == 1)
        #expect(sink.deliveredTranscripts.count == 1)
        #expect(sink.deliveredRecords.first?.exitCode == 0)
        #expect(sink.deliveredTranscripts.first?.firstExitCode == 0)
    }

    @Test("a clean prune is delivered succeeded with what it freed, its lines hopped home, and stamps")
    func cleanPrune() async throws {
        let sink = RecordingSink()
        // restic 0.19.1's summary lines, as a real prune printed them.
        let output = """
        to repack:             0 blobs / 0 B
        this removes:          0 blobs / 0 B
        to delete:            12 blobs / 2.864 MiB
        total prune:          12 blobs / 2.864 MiB
        remaining:            11 blobs / 4.144 KiB
        done
        """
        let client = MockResticClient()
            .onPrune(.success(output), rawLines: ["counting packs", "done"])
            .onExit("prune", 0)
        await MaintenanceRunEngine.perform(
            repository: Repository(),
            task: .prune,
            sink: sink.serving(client)
        )
        let record = try #require(sink.deliveredRecords.first)
        #expect(record.kind == .prune)
        #expect(record.outcome == .succeeded)
        // What it freed is the run's one-line answer, as the check verdict
        // is for a check; restic's own lines stay in the log.
        #expect(record.detailText == "Freed \(Format.bytes(3_003_122)).")
        #expect(client.callLog == ["prune"])
        #expect(client.checkSubsets.isEmpty)
        #expect(!sink.log.contains("advance-slice"))
        #expect(client.transcriptBound["prune"] == true)
        #expect(record.exitCode == 0)
        // A prune stamps, like a check — unlike a drive-away skip.
        #expect(sink.log.contains("stamp:prune"))
        #expect(sink.deliveredTranscripts.count == 1)
        #expect(sink.log.contains("refresh-scheduled"))
    }

    @Test("a prune's freed amount reads restic's binary units, to the byte")
    func pruneFreedBytesUnits() {
        let freed = { (amount: String) in ResticService.pruneFreedBytes(in: "removed 2 of 3 packs\ntotal prune:          3 blobs / \(amount)\nremaining:  1 blobs / 4 KiB") }
        #expect(freed("0 B") == 0)
        #expect(freed("512 B") == 512)
        #expect(freed("4.144 KiB") == 4243, "KiB is 1024 bytes")
        #expect(freed("2.864 MiB") == 3_003_122, "MiB is 1024² bytes, rounded to the nearest byte")
        #expect(freed("1.500 GiB") == 1_610_612_736, "GiB is 1024³ bytes")
        #expect(freed("2.000 TiB") == 2_199_023_255_552, "TiB is 1024⁴ bytes")
    }

    @Test("a prune whose output names no amount, or frees nothing, says nothing about it")
    func pruneWithoutAmount() async throws {
        #expect(ResticService.pruneFreedBytes(in: "removed 2 of 3 packs") == nil)
        #expect(ResticService.pruneFreedBytes(in: "total prune:          3 blobs / 1.5 parsecs") == nil)
        for output in ["removed 2 of 3 packs", "total prune:          0 blobs / 0 B"] {
            let sink = RecordingSink()
            let client = MockResticClient().onPrune(.success(output)).onExit("prune", 0)
            await MaintenanceRunEngine.perform(repository: Repository(), task: .prune, sink: sink.serving(client))
            let record = try #require(sink.deliveredRecords.first)
            #expect(record.outcome == .succeeded)
            #expect(record.detailText == nil, "freed space's Detail says “\(record.detailText ?? "")” for restic's “\(output)”")
            #expect(RunRecordPresentation.detail(for: record) == record.outcomeName)
        }
    }

    @Test("a check the password doesn't open fails naming the location")
    func refusedCheckNamesTheLocation() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onCheck(.failure(ResticError.commandFailed(exitCode: 12, message: "wrong password")))
        let repository = Repository()
        await MaintenanceRunEngine.perform(repository: repository, task: .check, sink: sink.serving(client))
        let record = try #require(sink.deliveredRecords.first)
        #expect(record.outcome == .failed)
        #expect(record.failureMessage == ResticError.wrongPassword(location: sink.label(of: repository)),
                "the failed check does not name the location its password doesn't open")
    }

    @Test("a failed prune is stamped and recorded failed, never unstamped")
    func failedPrune() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onPrune(.failure(ResticError.commandFailed(exitCode: 11, message: "locked")))
        await MaintenanceRunEngine.perform(
            repository: Repository(),
            task: .prune,
            sink: sink.serving(client)
        )
        let record = try #require(sink.deliveredRecords.first)
        #expect(record.outcome == .failed)
        // Stamped whatever happened: unstamped, the scheduler would retry
        // every minute against a repository that is likely still locked.
        #expect(sink.log.contains("stamp:prune"))
        #expect(sink.log.contains("auth-noted"))
        #expect(sink.deliveredRecords.count == 1)
    }
}
