import Foundation

/// Records one hook run's verdicts: failed, non-cancelled hooks surface in
/// the record's hook messages, and every hook's log line goes to the
/// transcript.
private func note(
    _ outcomes: [HookRunner.Outcome],
    into record: inout RunRecord,
    transcript: RunTranscript
) {
    record.hookMessages.append(
        contentsOf: outcomes.filter { !$0.succeeded && !$0.cancelled }.map(\.summary)
    )
    for outcome in outcomes { transcript.note(outcome.logLine) }
}

/// The after-hooks loop both engines' `finish` shares. A cancel landing
/// mid-after-hooks stops the remaining events, and a cancelled run runs
/// none of them — firing an "after failure" script then would surprise the
/// user who asked for the stop. A failing hook never undoes the run:
/// success whose hook failed reads as completed-with-errors, which arms the
/// problem dot and notifyOnFailure, and `finishedAt` is re-stamped so the
/// record includes the hooks.
private func runAfterHooks(
    _ allHooks: [BackupHook],
    events: [BackupHook.Event],
    context: HookRunner.Context,
    hooks: HookRunner,
    record: inout RunRecord,
    transcript: RunTranscript
) async {
    guard record.outcome != .cancelled, allHooks.contains(where: \.isRunnable) else { return }
    for event in events {
        let result = await hooks.runHooks(allHooks, event: event, context: context)
        note(result.outcomes, into: &record, transcript: transcript)
        if result.cancelled { break }
    }
    if !record.hookMessages.isEmpty, record.outcome == .succeeded {
        record.outcome = .completedWithErrors
    }
    record.finishedAt = .now
}

/// The away volumes among `paths`, each once, handed to `reconnect` — an
/// engine's sink, `AppModel.reconnectShares` — and nothing asked when none
/// is away. Each answer goes to the run's log; the shares that stayed away
/// come back, for the run's words (`reasonsByVolume`) and whether one
/// refused (`isRefusal`).
@MainActor
private func reconnectAwayShares(
    of paths: [String],
    transcript: RunTranscript,
    reconnect: ([String]) async -> [ShareReconnect]
) async -> [ShareReconnect] {
    var away: [String] = []
    for path in paths where VolumePresence.isMounted(volumeOf: path) == false {
        if let volume = VolumePresence.volumeName(of: path), !away.contains(volume) { away.append(volume) }
    }
    guard !away.isEmpty else { return [] }
    let answers = await reconnect(away)
    for answer in answers { transcript.note(answer.logLine) }
    return answers.filter { $0.failureReason != nil }
}

/// One backup run's lifecycle, so the sequencing — hooks → start ping →
/// backup → retention → closing refresh → record — is unit-testable against
/// a mock engine.
///
/// The engine owns what happens in what order; everything observable
/// (activity phases, run stamps, banners, records, notifications) is written
/// through the sink, which `AppModel` implements. `AppModel.runBackup` and
/// friends remain the facade the views and the scheduler call — this type is
/// not reachable from outside the model layer.
/// What a finished backup left for the plan's stamps: nothing (a failure, a
/// cancel, a skip around every folder), a snapshot of the folders not on an
/// away drive, or a snapshot of every folder
/// (`BackupPlan.lastSuccessAt` / `lastCompleteBackupAt`).
enum BackupStamp: Equatable, Sendable {
    case nothing, partial, whole
}

@MainActor
enum BackupRunEngine {
    /// The model surface a backup run drives. `AppModel` conforms; tests
    /// record the calls instead.
    @MainActor
    protocol Sink: AnyObject {
        /// Why this plan's run was cancelled, for its record: the user's
        /// Stop, Pause and Stop, or the app quitting.
        func cancellationMessage(for planID: UUID) -> String
        func service() throws -> any ResticClient
        func context(for repository: Repository) async throws -> RepositoryContext
        /// Nil-anchored like the activity entry itself: a phase for a plan
        /// whose run has already unwound is dropped, never resurrected.
        func setActivityPhase(_ phase: PlanActivity.Phase, for planID: UUID)
        /// The run's progress reporter, hopping to the sink's own actor —
        /// built by the sink because only it knows its concrete isolation.
        /// Sink-built is load-bearing: @Sendable captures a concrete
        /// main-actor class, not an existential or a generic parameter.
        func progressReporter(planID: UUID) -> @Sendable (OperationProgress) -> Void
        func markPlanRun(_ planID: UUID, at date: Date, wrote stamp: BackupStamp)
        func noteAuthFailure(_ error: Error, repositoryID: UUID)
        /// A start ping in flight must not be lost to a quit mid-backup. The
        /// channels are read at send time, not capture time — a channel
        /// edited mid-run applies from this ping on.
        func addStartPing(_ event: NotificationEvent)
        /// The closing refresh also feeds the snapshot index, and it must
        /// stay after retention: it reads the listing the forget left, which
        /// the index then takes.
        func refreshSnapshots(repositoryID: UUID) async
        /// The listing of a repository whose drive the run found away, in
        /// the run's words — its share's reconnect already tried, and not
        /// tried again by a refresh.
        func noteRepositoryAway(repositoryID: UUID, reason: String)
        /// Stores and announces a finished run: its log, run history,
        /// banner, user notification, external channels.
        func deliver(record: RunRecord, plan: BackupPlan, transcript: RunTranscript.Contents) async
        /// Runs the plan's shell hooks around the run.
        func makeHookRunner() -> HookRunner
        /// Mounts the saved network shares among `volumes` — volumes this
        /// run needs that are away (`AppModel.reconnectShares`).
        func reconnectShares(volumes: [String]) async -> [ShareReconnect]
        /// One connection attempt to a network repository's server
        /// (`ServerProbe`); nil when there is nothing to ask first.
        func probeServer(of repository: Repository) async -> ServerProbe.Outcome?
    }

    static func perform(plan: BackupPlan, repository: Repository, sink: Sink) async {
        let startedAt = Date.now
        var record = RunRecord(
            kind: .backup,
            planID: plan.id,
            planName: plan.name,
            repositoryID: repository.id,
            startedAt: startedAt
        )
        let hooks = sink.makeHookRunner()
        // What restic said, for the run's log: bound around the restic
        // service calls only — hooks shield themselves, and the closing
        // refresh is not part of the run.
        let transcript = RunTranscript()
        var hookContext = HookRunner.Context(
            event: .beforeBackup,
            planName: plan.name,
            planID: plan.id.uuidString,
            repositoryName: repository.name,
            repositoryID: repository.id.uuidString,
            outcome: "starting"
        )
        // Why each away share this run needed could not be reconnected, by
        // volume name, for the skip's words.
        var reconnectFailures: [String: String] = [:]

        do {
            let service = try sink.service()
            let context = try await sink.context(for: repository)

            if plan.hooks.contains(where: { $0.event == .beforeBackup && $0.isRunnable }) {
                sink.setActivityPhase(.runningHooks, for: plan.id)
                let result = await hooks.runHooks(plan.hooks, event: .beforeBackup, context: hookContext)
                note(result.outcomes, into: &record, transcript: transcript)
                if result.cancelled {
                    // The user stopped the run while a hook was still going:
                    // a cancellation, never a hook verdict, so the aborted-run
                    // machinery below must not fire.
                    throw ResticError.cancelled
                }
                if result.shouldAbort {
                    record.outcome = .failed
                    record.failureMessage =
                        "A before-backup hook failed and is set to cancel the backup."
                    sink.markPlanRun(plan.id, at: startedAt, wrote: .nothing)
                    await finish(
                        record: &record, plan: plan, hooks: hooks, context: hookContext,
                        transcript: transcript, sink: sink
                    )
                    return
                }
            }

            // Network shares this run needs that are away — the repository's
            // folder, the plan's — mounted with their saved passwords before
            // the checks below read them as drives that are away. After the
            // hooks, which may have mounted them.
            let neededPaths = (repository.kind == .local ? [repository.resolvedLocalPath] : [])
                + plan.sources.map(ResticService.expandTilde)
            let shareFailures = await reconnectAwayShares(
                of: neededPaths,
                transcript: transcript,
                reconnect: { await sink.reconnectShares(volumes: $0) }
            )
            reconnectFailures = shareFailures.reasonsByVolume

            // A share that refused — its password, its name, access, a
            // leftover folder, the Keychain — comes back only when the user
            // acts, so the run fails in the skip's words, without asking
            // restic: a problem like any failure, with the editor that holds
            // the share's password as its fix (`refusedShares`). One out of
            // reach is a drive that is away: the checks below skip the run.
            let refused = shareFailures.filter(\.isRefusal)
            if !refused.isEmpty {
                let volumes = refused.map(\.volumeName)
                record.outcome = .failed
                record.refusedShares = volumes
                record.failureMessage = RunRecord.skippedReason(
                    sources: neededPaths.filter { VolumePresence.volumeName(of: $0).map(volumes.contains) == true },
                    reconnectFailures: refused.reasonsByVolume
                )
                sink.markPlanRun(plan.id, at: startedAt, wrote: .nothing)
                await finish(
                    record: &record, plan: plan, hooks: hooks, context: hookContext,
                    transcript: transcript, sink: sink
                )
                return
            }

            // The repository's drive away (after the hooks, which may mount
            // it): skipped as for the folders' drive, never asking restic,
            // whose "does not exist" could not tell it from a moved folder.
            if repository.kind == .local, VolumePresence.isMounted(volumeOf: repository.resolvedLocalPath) == false {
                let reason = RunRecord.skippedReason(
                    sources: [repository.resolvedLocalPath], reconnectFailures: reconnectFailures
                )
                record.outcome = .skipped
                record.detailText = reason
                sink.markPlanRun(plan.id, at: startedAt, wrote: .nothing)
                // The listing learns it now, not at the next launch, and
                // why: a refresh would reconnect the share again.
                sink.noteRepositoryAway(repositoryID: repository.id, reason: reason)
                await finish(
                    record: &record, plan: plan, hooks: hooks, context: hookContext,
                    transcript: transcript, sink: sink
                )
                return
            }

            // A network repository's server out of reach (after the hooks,
            // which may bring up the way to it): skipped as a drive that is
            // away is, within seconds, never asking restic — which retries
            // such a server for about a quarter of an hour, then fails.
            if repository.kind != .local, case let .unreachable(why)? = await sink.probeServer(of: repository) {
                let reason = RunRecord.serverUnreachableReason(repositoryName: repository.name, why: why)
                record.outcome = .skipped
                record.detailText = reason
                sink.markPlanRun(plan.id, at: startedAt, wrote: .nothing)
                sink.noteRepositoryAway(repositoryID: repository.id, reason: reason)
                await finish(
                    record: &record, plan: plan, hooks: hooks, context: hookContext,
                    transcript: transcript, sink: sink
                )
                return
            }

            // Healthchecks measures the run against this ping, so it has to go out
            // before the backup starts — but concurrently, so a slow endpoint
            // cannot delay the backup itself.
            let startEvent = NotificationEvent(
                stage: .started,
                planName: plan.name,
                repositoryName: repository.name
            )
            sink.addStartPing(startEvent)

            sink.setActivityPhase(.backingUp, for: plan.id)
            var outcome = try await RunTranscript.$current.withValue(transcript) {
                try await service.backup(
                    context,
                    plan: plan,
                    onProgress: sink.progressReporter(planID: plan.id)
                )
            }

            // Folders on a drive that is away, when they are all restic
            // could not read: the rest is backed up, and the run reads as
            // skipped for the drive, as when every folder is on it.
            let awaySources = outcome.setAsideAwaySources { VolumePresence.isMounted(volumeOf: $0) == false }

            record.snapshotID = outcome.summary?.snapshotID
            record.filesNew = outcome.summary?.filesNew ?? 0
            record.filesChanged = outcome.summary?.filesChanged ?? 0
            record.filesUnmodified = outcome.summary?.filesUnmodified ?? 0
            record.bytesProcessed = outcome.summary?.totalBytesProcessed ?? 0
            record.dataAdded = outcome.summary?.dataAdded ?? 0
            record.exitCode = outcome.exitCode
            // The unreadable items first, then the decoding gap, then (below)
            // any retention line — `RunRecord.unreadableItems` slices this
            // order, and only the unreadable items are counted.
            record.itemErrorCount = outcome.itemErrors.count
            // By cause, over every item before the cap: the stored sample
            // would under-count a home folder macOS blocked in bulk.
            record.itemErrorTally = ItemErrorDiagnosis.tally(outcome.itemErrors)
            record.itemErrors.append(contentsOf: outcome.itemErrors.prefix(RunRecord.storedItemErrorLimit))
            // The stored lines' paths only, keyed as stored.
            let storedLines = Set(record.itemErrors.map(RunRecord.storedItemError))
            record.unreadableItemPaths = outcome.itemPaths.filter { storedLines.contains(RunRecord.storedItemError($0.key)) }
            if let decodingWarning = outcome.decodingWarning {
                record.itemErrors.append(decodingWarning)
            }
            if awaySources.isEmpty {
                record.outcome = record.itemErrors.isEmpty && !outcome.completedWithErrors
                    ? .succeeded
                    : .completedWithErrors
            } else {
                record.outcome = .skipped
                record.detailText = RunRecord.partlySkippedReason(sources: awaySources, reconnectFailures: reconnectFailures)
            }

            // The snapshot exists from here on. Mark the run before doing anything
            // else, so nothing that follows can make a good backup look like a
            // failed one.
            sink.markPlanRun(plan.id, at: startedAt, wrote: awaySources.isEmpty ? .whole : .partial)

            // Retention runs only after a backup that actually produced a
            // snapshot, so a failed run can never trigger a forget against stale
            // data.
            if plan.retention.isSafeToRun, record.snapshotID != nil {
                sink.setActivityPhase(.applyingRetention, for: plan.id)
                do {
                    let removed = try await RunTranscript.$current.withValue(transcript) {
                        try await service.forget(context, plan: plan)
                    }
                    transcript.note("Retention removed \(Format.plural(removed, "snapshot"))")
                } catch where ResticError.isCancellation(error) {
                    // The user's stop — "Stop Applying Retention" in the Plan
                    // menu or the tray, Pause and Stop, or a quit — recorded
                    // as every stop is, never as the lock failure below. The
                    // snapshot stands and is already stamped, so nothing
                    // stamps the run again.
                    record.setOutcome(from: error, cancellationMessage: sink.cancellationMessage(for: plan.id))
                    transcript.note("Retention stopped")
                } catch {
                    // `forget` needs an exclusive repository lock while `backup`
                    // takes a shared one, so a second plan backing up to the
                    // same repository fails this with exit code 11. The data
                    // is safe; warn instead of failing the whole backup.
                    record.outcome = .completedWithErrors
                    // Not exit 11's own words, whose stale-lock advice fits a
                    // run that failed: here the lock is most often that other
                    // backup's, live, and the next backup's retention runs
                    // again by itself.
                    let reason = if case ResticError.commandFailed(exitCode: 11, _) = error {
                        "another backup or job held the repository's lock — retention runs again after the next backup."
                    } else {
                        error.localizedDescription
                    }
                    if case let ResticError.snapshotsNotRemoved(_, refused, _) = error { record.retentionRefused = refused }
                    let line = RunRecord.retentionSkippedPrefix + reason
                    record.itemErrors.append(line)
                    transcript.note(line)
                }
            }

            // A cache must never delay, and never fail, the run that feeds it.
            await sink.refreshSnapshots(repositoryID: repository.id)
        } catch let ResticError.commandFailed(_, message) where message.hasPrefix(RunRecord.everySourceMissingMessage) {
            // Every folder missing: restic wrote nothing and said so. On
            // drives that are away the run is skipped — a mount brings it
            // back sooner (`catchUpAfterMount`). Missing from this Mac — its
            // startup disk, or a drive that is here — nothing brings it
            // back, so the run fails and the plan's editor is the fix. The
            // slot is stamped either way, so an hourly plan does not try
            // again every tick.
            if plan.sources.allSatisfy({ VolumePresence.isMounted(volumeOf: ResticService.expandTilde($0)) == false }) {
                record.outcome = .skipped
                record.detailText = RunRecord.skippedReason(sources: plan.sources, reconnectFailures: reconnectFailures)
            } else {
                record.outcome = .failed
                record.missingSources = plan.sources
                record.failureMessage = RunRecord.folderGoneMessage(sources: plan.sources)
            }
            sink.markPlanRun(plan.id, at: startedAt, wrote: .nothing)
        } catch {
            record.setOutcome(from: error, cancellationMessage: sink.cancellationMessage(for: plan.id))
            // The repository's disk full: said plainly, with what the run left
            // behind — restic's line, naming a pack file by its hash, stays in
            // the log — and Prune Now… as its fix (`repositoryFull`).
            if case let ResticError.commandFailed(_, message) = error,
               let full = RunRecord.repositoryFullMessage(resticMessage: message, repository: repository)
            {
                record.failureMessage = full
                record.repositoryFull = true
            }
            sink.noteAuthFailure(error, repositoryID: repository.id)
            sink.markPlanRun(plan.id, at: startedAt, wrote: .nothing)
        }

        hookContext.snapshotID = record.snapshotID
        hookContext.filesNew = record.filesNew
        hookContext.filesChanged = record.filesChanged
        hookContext.bytesProcessed = record.bytesProcessed
        hookContext.dataAdded = record.dataAdded
        await finish(
            record: &record, plan: plan, hooks: hooks, context: hookContext,
            transcript: transcript, sink: sink
        )
    }

    /// Runs the after-backup hooks (`runAfterHooks`), then hands the finished
    /// run to the sink for storage and announcement.
    private static func finish(
        record: inout RunRecord,
        plan: BackupPlan,
        hooks: HookRunner,
        context: HookRunner.Context,
        transcript: RunTranscript,
        sink: Sink
    ) async {
        record.finishedAt = .now

        var hookContext = context
        hookContext.outcome = record.outcome.rawValue
        hookContext.errorMessage = record.failureMessage
        hookContext.durationSeconds = record.duration
        let events: [BackupHook.Event] = switch record.outcome {
        case .succeeded: [.afterSuccess, .afterAny]
        case .completedWithErrors: [.afterWarning, .afterAny]
        case .failed: [.afterFailure, .afterAny]
        // A drive away, nothing failed: only the hooks for any end.
        case .skipped: [.afterAny]
        case .cancelled: []
        }
        await runAfterHooks(
            plan.hooks, events: events, context: hookContext,
            hooks: hooks, record: &record, transcript: transcript
        )

        // The success path took the backup's own code; anything that threw
        // gets the first exit restic reached, and nil when it reached none.
        let contents = transcript.contents
        if record.exitCode == nil { record.exitCode = contents.firstExitCode }
        await sink.deliver(record: record, plan: plan, transcript: contents)
    }
}

/// One repository-maintenance run's lifecycle (`check` or `prune`), extracted
/// for the same reasons as `BackupRunEngine` — the sequencing is testable
/// against a mock engine, the model remains the facade.
@MainActor
enum MaintenanceRunEngine {
    @MainActor
    protocol Sink: AnyObject {
        var cancellationMessage: String { get }
        func service() throws -> any ResticClient
        func context(for repository: Repository) async throws -> RepositoryContext
        /// Prune's live narration, hopped home by the sink itself (only it
        /// knows its concrete isolation); dropped if the run has already
        /// unwound, like the activity entry itself.
        func lineReporter(repositoryID: UUID) -> @Sendable (String) -> Void
        func stampMaintenance(repositoryID: UUID, task: MaintenanceTask, at date: Date)
        /// Not-yet-configured repositories record nothing and stamp nothing.
        func markPasswordMissing(repositoryID: UUID)
        /// The repository's drive is away: its upkeep, unstamped, waits for
        /// the drive (`AppModel.upkeepAwaitingDrive`).
        func markDriveAway(repositoryID: UUID)
        /// The repository's server is out of reach: its upkeep, unstamped,
        /// waits for it (`AppModel.upkeepAwaitingServer`).
        func markServerAway(repositoryID: UUID)
        /// One connection attempt to a network repository's server
        /// (`ServerProbe`); nil when there is nothing to ask first.
        func probeServer(of repository: Repository) async -> ServerProbe.Outcome?
        func noteAuthFailure(_ error: Error, repositoryID: UUID)
        func deliver(record: RunRecord, repository: Repository, transcript: RunTranscript.Contents) async
        func makeHookRunner() -> HookRunner
        /// The closing snapshot refresh, scheduled by the sink so it runs
        /// outside this task — a cancelled run leaves its task cancelled, and
        /// an inline refresh would die with it — and inside whatever
        /// bookkeeping keeps work from outliving a quit.
        func scheduleSnapshotRefresh(repositoryID: UUID)
        /// Mounts the saved network shares among `volumes`, as for a backup
        /// (`AppModel.reconnectShares`).
        func reconnectShares(volumes: [String]) async -> [ShareReconnect]
    }

    static func perform(
        repository: Repository,
        task: MaintenanceTask,
        readDataPercentOverride: Int?,
        sink: Sink
    ) async {
        let startedAt = Date.now
        var record = RunRecord(
            kind: task == .prune ? .prune : .check,
            planName: repository.name,
            repositoryID: repository.id,
            startedAt: startedAt
        )
        let hooks = sink.makeHookRunner()
        // The backup engine's rule: restic's words for the log, bound around
        // the service call only.
        let transcript = RunTranscript()
        let hookContext = HookRunner.Context(
            event: .beforeMaintenance,
            repositoryName: repository.name,
            repositoryID: repository.id.uuidString,
            maintenanceTask: task.rawValue,
            outcome: "starting"
        )

        do {
            let service = try sink.service()
            let context = try await sink.context(for: repository)

            if repository.hooks.contains(where: { $0.event == .beforeMaintenance && $0.isRunnable }) {
                let result = await hooks.runHooks(
                    repository.hooks,
                    event: .beforeMaintenance,
                    context: hookContext
                )
                note(result.outcomes, into: &record, transcript: transcript)
                if result.cancelled {
                    // Same rule as the backup engine: the user's cancel is a
                    // cancellation, never a hook verdict.
                    throw ResticError.cancelled
                }
                if result.shouldAbort {
                    record.outcome = .failed
                    record.failureMessage =
                        "A before-maintenance hook failed and is set to cancel the \(task.displayName.lowercased())."
                    // Stamped like any other failure: a hook that always says no
                    // must not have the scheduler asking again every minute.
                    sink.stampMaintenance(repositoryID: repository.id, task: task, at: startedAt)
                    await finish(
                        record: &record, repository: repository, hooks: hooks, context: hookContext,
                        transcript: transcript, sink: sink
                    )
                    return
                }
            }

            // The repository's network share, away and saved: mounted with
            // its saved password before restic is asked, as for a backup.
            // A share that refused fails the run in those words rather than
            // restic's "repository does not exist". Its drive still away —
            // no share saved, or one out of reach — the run waits for it,
            // as a backup does: Skipped, unstamped, so the task stays due,
            // and the scheduler leaves it alone until the drive is back
            // (`markDriveAway`). After the hooks, which may mount it.
            if repository.kind == .local {
                let failures = await reconnectAwayShares(
                    of: [repository.resolvedLocalPath],
                    transcript: transcript,
                    reconnect: { await sink.reconnectShares(volumes: $0) }
                )
                if failures.contains(where: \.isRefusal) {
                    record.outcome = .failed
                    record.refusedShares = failures.filter(\.isRefusal).map(\.volumeName)
                    record.failureMessage = RunRecord.skippedReason(
                        sources: [repository.resolvedLocalPath], reconnectFailures: failures.reasonsByVolume
                    )
                    sink.stampMaintenance(repositoryID: repository.id, task: task, at: startedAt)
                    await finish(
                        record: &record, repository: repository, hooks: hooks, context: hookContext,
                        transcript: transcript, sink: sink
                    )
                    return
                }
                if VolumePresence.isMounted(volumeOf: repository.resolvedLocalPath) == false {
                    record.outcome = .skipped
                    record.detailText = RunRecord.skippedReason(
                        sources: [repository.resolvedLocalPath], reconnectFailures: failures.reasonsByVolume
                    )
                    sink.markDriveAway(repositoryID: repository.id)
                    await finish(
                        record: &record, repository: repository, hooks: hooks, context: hookContext,
                        transcript: transcript, sink: sink
                    )
                    return
                }
            } else if case let .unreachable(why)? = await sink.probeServer(of: repository) {
                // Its server out of reach: the task waits for it as for a
                // drive — Skipped, unstamped, left alone until the network
                // changes or a listing reads the repository again.
                record.outcome = .skipped
                record.detailText = RunRecord.serverUnreachableReason(repositoryName: repository.name, why: why)
                sink.markServerAway(repositoryID: repository.id)
                await finish(
                    record: &record, repository: repository, hooks: hooks, context: hookContext,
                    transcript: transcript, sink: sink
                )
                return
            }

            switch task {
            case .check:
                let percent = readDataPercentOverride ?? repository.maintenance.checkReadDataPercent
                let summary = try await RunTranscript.$current.withValue(transcript) {
                    try await service.check(context, readDataSubsetPercent: percent)
                }
                let errors = summary?.numErrors ?? 0
                record.outcome = errors == 0 ? .succeeded : .completedWithErrors
                // One sentence — a dash, not a period, before the command —
                // so Format.firstSentence carries the whole verdict to the
                // Detail column, the Recent problems row and the Maintenance
                // card; restic's prune advice stays a second sentence.
                record.detailText = errors == 0
                    ? "No errors found."
                    : "\(Format.plural(errors, "error")) — `restic repair` can recover some damage."
                if summary?.suggestPrune == true {
                    record.detailText? += " restic suggests running prune."
                }
            case .prune:
                // Prune narrates its progress line by line; surfacing the
                // newest line is the difference between "working" and "hung"
                // across a prune that can run for hours. (Restic's lines are
                // \n-terminated when stdout is a pipe, arriving as they
                // print — no \r in-place updates to split around.)
                record.detailText = try await RunTranscript.$current.withValue(transcript) {
                    try await service.prune(
                        context,
                        dryRun: false,
                        onRawLine: sink.lineReporter(repositoryID: repository.id)
                    )
                }
                record.outcome = .succeeded
            }
        } catch ResticError.passwordMissing {
            // Not finished being set up. Record nothing and stamp nothing: the
            // scheduler skips this repository until a password exists, and the
            // repository screen must not claim a check happened.
            sink.markPasswordMissing(repositoryID: repository.id)
            return
        } catch {
            record.setOutcome(from: error, cancellationMessage: sink.cancellationMessage)
            sink.noteAuthFailure(error, repositoryID: repository.id)
        }

        // Stamp the timestamp whatever happened. Leaving it unset on failure would
        // make the scheduler retry every minute against a repository that is very
        // likely still unreachable.
        sink.stampMaintenance(repositoryID: repository.id, task: task, at: startedAt)
        await finish(
            record: &record, repository: repository, hooks: hooks, context: hookContext,
            transcript: transcript, sink: sink
        )
    }

    /// Runs the after-maintenance hooks (`runAfterHooks`), then hands the
    /// finished run to the sink.
    ///
    /// A check that found errors counts as a failure here: that is the outcome
    /// a repository hook exists to report.
    private static func finish(
        record: inout RunRecord,
        repository: Repository,
        hooks: HookRunner,
        context: HookRunner.Context,
        transcript: RunTranscript,
        sink: Sink
    ) async {
        record.finishedAt = .now
        var hookContext = context
        hookContext.outcome = record.outcome.rawValue
        hookContext.errorMessage = record.failureMessage ?? record.detailText.flatMap {
            record.outcome == .completedWithErrors ? $0 : nil
        }
        hookContext.durationSeconds = record.duration
        let events: [BackupHook.Event] = switch record.outcome {
        case .succeeded: [.afterMaintenanceSuccess, .afterAnyMaintenance]
        case .completedWithErrors, .failed: [.afterMaintenanceFailure, .afterAnyMaintenance]
        // The drive away, nothing failed: only the hooks for any end, as
        // for a skipped backup.
        case .skipped: [.afterAnyMaintenance]
        case .cancelled: []
        }
        await runAfterHooks(
            repository.hooks, events: events, context: hookContext,
            hooks: hooks, record: &record, transcript: transcript
        )

        let contents = transcript.contents
        if record.exitCode == nil { record.exitCode = contents.firstExitCode }
        await sink.deliver(record: record, repository: repository, transcript: contents)
        // Scheduled by the sink, not awaited here: a cancelled run leaves
        // this task cancelled, and an inherited cancel would kill the refresh
        // mid-call and leave the listing stale. (A cancel landing inside the
        // refresh itself is answered quietly by the sink.)
        sink.scheduleSnapshotRefresh(repositoryID: repository.id)
    }
}

/// Apply Retention Now…'s run: the plan's `forget`, outside a backup. It
/// runs in the plan's own slot — so Stop, the sidebar's spinner, quitting
/// and the busy repository all work as for a backup — but it is not one:
/// no hooks (README: `forget` has none of its own), no run stamp, and
/// nothing past the in-app banner and the Activity record. A manual,
/// attended run needs no alert, and a "succeeded" ping would reset a
/// Healthchecks dead-man's switch for a run that backed nothing up.
@MainActor
enum RetentionRunEngine {
    /// The backup engine's sink, minus everything a backup has and this run
    /// does not. Delivery has its own name: AppModel's `deliver(record:
    /// plan:transcript:)` notifies and broadcasts, which this run must not.
    @MainActor
    protocol Sink: AnyObject {
        func cancellationMessage(for planID: UUID) -> String
        func service() throws -> any ResticClient
        func context(for repository: Repository) async throws -> RepositoryContext
        func noteAuthFailure(_ error: Error, repositoryID: UUID)
        /// Stores the run and announces it in the window only.
        func deliverRetention(record: RunRecord, plan: BackupPlan, transcript: RunTranscript.Contents) async
        /// The maintenance engine's closing refresh, scheduled outside this
        /// (possibly cancelled) task.
        func scheduleSnapshotRefresh(repositoryID: UUID)
        /// Mounts the saved network shares among `volumes`, as for a backup
        /// (`AppModel.reconnectShares`).
        func reconnectShares(volumes: [String]) async -> [ShareReconnect]
    }

    static func perform(plan: BackupPlan, repository: Repository, sink: Sink) async {
        var record = RunRecord(
            kind: .forget,
            planID: plan.id,
            planName: plan.name,
            repositoryID: repository.id,
            startedAt: .now
        )
        // The backup engine's rule: restic's words for the log, bound
        // around the service call only.
        let transcript = RunTranscript()
        do {
            let service = try sink.service()
            let context = try await sink.context(for: repository)
            // The maintenance engine's rule for the repository's network
            // share: reconnected first; still away, no forget, and the run
            // says why.
            let failures = repository.kind == .local
                ? await reconnectAwayShares(
                    of: [repository.resolvedLocalPath],
                    transcript: transcript,
                    reconnect: { await sink.reconnectShares(volumes: $0) }
                )
                : []
            if failures.isEmpty {
                let removed = try await RunTranscript.$current.withValue(transcript) {
                    try await service.forget(context, plan: plan)
                }
                record.outcome = .succeeded
                record.detailText = RetentionPreview.appliedSummary(removed: removed, pruned: plan.retention.runPrune)
            } else {
                record.outcome = .failed
                let refused = failures.filter(\.isRefusal).map(\.volumeName)
                if !refused.isEmpty { record.refusedShares = refused }
                record.failureMessage = RunRecord.skippedReason(
                    sources: [repository.resolvedLocalPath], reconnectFailures: failures.reasonsByVolume
                )
            }
        } catch {
            record.setOutcome(from: error, cancellationMessage: sink.cancellationMessage(for: plan.id))
            if case let ResticError.snapshotsNotRemoved(_, refused, _) = error { record.retentionRefused = refused }
            sink.noteAuthFailure(error, repositoryID: repository.id)
        }
        record.finishedAt = .now
        let contents = transcript.contents
        if record.exitCode == nil { record.exitCode = contents.firstExitCode }
        await sink.deliverRetention(record: record, plan: plan, transcript: contents)
        // Whatever happened: a forget stopped or failed partway may already
        // have removed snapshots, and the refresh must not inherit a cancel.
        sink.scheduleSnapshotRefresh(repositoryID: repository.id)
    }
}
