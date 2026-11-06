import Foundation

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

@MainActor
private func reconnectAwayShares(
    of paths: [String],
    transcript: RunTranscript,
    sink: some RunEngineSink
) async -> [ShareReconnect] {
    var away: [String] = []
    for path in paths {
        guard await sink.isMounted(volumeOf: path) == false,
              let volume = VolumePresence.volumeName(of: path), !away.contains(volume)
        else { continue }
        away.append(volume)
    }
    guard !away.isEmpty else { return [] }
    let answers = await sink.reconnectShares(volumes: away)
    for answer in answers { transcript.note(answer.logLine) }
    return answers.filter { $0.failureReason != nil }
}

/// What a finished backup left for the plan's stamps: nothing (a failure, a
/// cancel, a skip), or a snapshot of the plan's path
/// (`BackupPlan.lastSuccessAt`).
enum BackupStamp: Equatable, Sendable {
    case nothing, whole
}

@MainActor
protocol RunEngineSink: AnyObject {
    /// What every surface calls the repository (`AppModel.label(of:)`): the
    /// run's record and hooks say it.
    func label(of repository: Repository) -> String
    func service() throws -> any ResticClient
    func context(for repository: Repository) async throws -> RepositoryContext
    func noteAuthFailure(_ error: Error, repositoryID: UUID)
    /// The closing snapshot refresh, scheduled by the sink so it runs
    /// outside this task — a cancelled run leaves its task cancelled, and
    /// an inline refresh would die with it — and inside whatever
    /// bookkeeping keeps work from outliving a quit.
    func scheduleSnapshotRefresh(repositoryID: UUID)
    func reconnectShares(volumes: [String]) async -> [ShareReconnect]
    /// One connection attempt to a network repository's server
    /// (`ServerProbe`); nil when there is nothing to ask first.
    func probeServer(of repository: Repository) async -> ServerProbe.Outcome?
    /// Whether the volume holding `path` is mounted; nil for a path on the
    /// startup disk. Off the main actor (`VolumeProbe`).
    func isMounted(volumeOf path: String) async -> Bool?
}

extension RunEngineSink {
    /// A local repository whose drive is not mounted. False for every other
    /// kind, and while the mount cannot be told.
    func isDriveAway(_ repository: Repository) async -> Bool {
        guard repository.kind == .local else { return false }
        return await isMounted(volumeOf: repository.resolvedLocalPath) == false
    }
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
@MainActor
enum BackupRunEngine {
    @MainActor
    protocol Sink: RunEngineSink {
        /// Why a run was cancelled, for its record: the user's Stop or the
        /// app quitting.
        var cancellationMessage: String { get }
        /// What every surface calls the plan (`AppModel.label(of:)`): the
        /// run's record, hooks and notifications say it.
        func label(of plan: BackupPlan) -> String
        /// Nil-anchored like the activity entry itself: a phase for a plan
        /// whose run has already unwound is dropped, never resurrected.
        func setActivityPhase(_ phase: PlanActivity.Phase, for planID: UUID)
        /// The forget has returned: its restic child is gone, so the
        /// repository's other backups may start. Leaves the phase alone, so
        /// a Stop's `.cancelling` stays.
        func endRetentionStep(for planID: UUID)
        /// The run's progress reporter, hopping to the sink's own actor —
        /// built by the sink because only it knows its concrete isolation.
        /// Sink-built is load-bearing: @Sendable captures a concrete
        /// main-actor class, not an existential or a generic parameter.
        func progressReporter(planID: UUID) -> @Sendable (OperationProgress) -> Void
        func markPlanRun(_ planID: UUID, at date: Date, wrote stamp: BackupStamp)
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
        func makeHookRunner() -> HookRunner
    }

    static func perform(plan: BackupPlan, repository: Repository, sink: Sink) async {
        let startedAt = Date.now
        let planLabel = sink.label(of: plan)
        var record = RunRecord(
            kind: .backup,
            planID: plan.id,
            planName: planLabel,
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
            planName: planLabel,
            planID: plan.id.uuidString,
            repositoryName: sink.label(of: repository),
            repositoryID: repository.id.uuidString,
            outcome: "starting"
        )
        // Why each away share this run needed could not be reconnected, by
        // volume name, for the skip's words.
        var reconnectFailures: [String: String] = [:]

        // Every exit but a missing password leaves through the tail below
        // (`break run`), so the after-hooks and delivery run once.
        run: do {
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
                        "The backup didn’t run because a hook that runs before it failed."
                    // Stamped although nothing ran: a hook that always refuses
                    // would otherwise be retried every minute.
                    sink.markPlanRun(plan.id, at: startedAt, wrote: .nothing)
                    break run
                }
            }

            // Network shares this run needs that are away — the repository's
            // folder, the plan's — mounted with their saved passwords before
            // the checks below read them as drives that are away. After the
            // hooks, which may have mounted them.
            let neededPaths = (repository.kind == .local ? [repository.resolvedLocalPath] : [])
                + [plan.resolvedPath]
            let shareFailures = await reconnectAwayShares(
                of: neededPaths,
                transcript: transcript,
                sink: sink
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
                break run
            }

            // The repository's drive away (after the hooks, which may mount
            // it): skipped as for the folders' drive, never asking restic,
            // whose "does not exist" could not tell it from a moved folder
            // (both exit 10, "Fatal: repository does not exist: unable to
            // open config file", restic 0.19.1).
            if await sink.isDriveAway(repository) {
                let reason = RunRecord.skippedReason(
                    sources: [repository.resolvedLocalPath], reconnectFailures: reconnectFailures
                )
                record.outcome = .skipped
                record.detailText = reason
                sink.markPlanRun(plan.id, at: startedAt, wrote: .nothing)
                // The listing learns it now, not at the next launch, and
                // why: a refresh would reconnect the share again.
                sink.noteRepositoryAway(repositoryID: repository.id, reason: reason)
                break run
            }

            // A network repository's server out of reach (after the hooks,
            // which may bring up the way to it): skipped as a drive that is
            // away is, within seconds, never asking restic — which retries
            // such a server for about a quarter of an hour, then fails.
            if repository.kind != .local, case let .unreachable(why)? = await sink.probeServer(of: repository) {
                let reason = RunRecord.serverUnreachableReason(repositoryName: sink.label(of: repository), why: why)
                record.outcome = .skipped
                record.detailText = reason
                sink.markPlanRun(plan.id, at: startedAt, wrote: .nothing)
                sink.noteRepositoryAway(repositoryID: repository.id, reason: reason)
                break run
            }

            // A Stop during the checks above, which do not answer a cancel:
            // ended here, before a start ping for a run that will not run.
            if Task.isCancelled { throw ResticError.cancelled }

            // Healthchecks measures the run against this ping, so it has to go out
            // before the backup starts — but concurrently, so a slow endpoint
            // cannot delay the backup itself.
            let startEvent = NotificationEvent(
                stage: .started,
                planName: planLabel,
                repositoryName: sink.label(of: repository),
                kind: .backup
            )
            sink.addStartPing(startEvent)

            sink.setActivityPhase(.backingUp, for: plan.id)
            let outcome = try await RunTranscript.$current.withValue(transcript) {
                try await service.backup(
                    context,
                    plan: plan,
                    onProgress: sink.progressReporter(planID: plan.id)
                )
            }

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
            let storedLines = Set(record.itemErrors.map { PathKey(RunRecord.storedItemError($0)) })
            record.unreadableItemPaths = outcome.itemPaths.filter { storedLines.contains(PathKey(RunRecord.storedItemError($0.key.path))) }
            if let decodingWarning = outcome.decodingWarning {
                record.itemErrors.append(decodingWarning)
            }
            record.outcome = record.itemErrors.isEmpty && !outcome.completedWithErrors
                ? .succeeded
                : .completedWithErrors

            // The snapshot exists from here on. Mark the run before doing anything
            // else, so nothing that follows can make a good backup look like a
            // failed one.
            sink.markPlanRun(plan.id, at: startedAt, wrote: .whole)

            // Retention runs only after a backup that actually produced a
            // snapshot, so a failed run can never trigger a forget against stale
            // data.
            if plan.retention.isSafeToRun, record.snapshotID != nil {
                sink.setActivityPhase(.applyingRetention, for: plan.id)
                do {
                    let removed = try await RunTranscript.$current.withValue(transcript) {
                        try await service.forget(context, plan: plan)
                    }
                    transcript.note("Retention removed \(Format.plural(removed, "backup"))")
                } catch where ResticError.isCancellation(error) {
                    // The user's stop, "Stop Applying Retention" in the Plan
                    // menu or the tray, or a quit: recorded
                    // as every stop is, never as the lock failure below. The
                    // snapshot stands and is already stamped, so nothing
                    // stamps the run again.
                    record.setOutcome(from: error, cancellationMessage: sink.cancellationMessage)
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
                        "another backup or job held the repository’s lock — retention runs again after the next backup."
                    } else {
                        error.localizedDescription
                    }
                    if case let ResticError.snapshotsNotRemoved(_, refused, _) = error { record.retentionRefused = refused }
                    let line = RunRecord.retentionSkippedPrefix + reason
                    record.itemErrors.append(line)
                    transcript.note(line)
                }
                sink.endRetentionStep(for: plan.id)
            }

            // A cache must never delay, and never fail, the run that feeds it.
            // A stop during retention — or one landing just after restic
            // returned — leaves this task cancelled, which would kill an
            // inline refresh.
            if record.outcome == .cancelled || Task.isCancelled {
                sink.scheduleSnapshotRefresh(repositoryID: repository.id)
            } else {
                await sink.refreshSnapshots(repositoryID: repository.id)
            }
        } catch let ResticError.commandFailed(_, message) where message.hasPrefix(RunRecord.everySourceMissingMessage) {
            // The plan's folder missing: restic wrote nothing and said so.
            // On a drive that is away the run is skipped — a mount brings it
            // back sooner (`catchUpAfterMount`). Missing from this Mac — its
            // startup disk, or a drive that is here — nothing brings it
            // back, so the run fails, a new plan for where the folder is now
            // its fix. The slot is stamped either way, so an hourly plan
            // does not try again every tick.
            if await sink.isMounted(volumeOf: plan.resolvedPath) == false {
                record.outcome = .skipped
                record.detailText = RunRecord.skippedReason(sources: [plan.path], reconnectFailures: reconnectFailures)
            } else {
                record.outcome = .failed
                record.missingSources = [plan.path]
                record.failureMessage = RunRecord.folderGoneMessage(path: plan.path)
            }
            sink.markPlanRun(plan.id, at: startedAt, wrote: .nothing)
        } catch {
            record.setOutcome(from: error, cancellationMessage: sink.cancellationMessage)
            // The repository's disk full: said plainly, with what the run left
            // behind — restic's line, naming a pack file by its hash, stays in
            // the log — and Clean Up Now as its fix (`repositoryFull`): on a
            // 40 MB disk image a 57 MB backup failed with 35 MB left behind,
            // which `restic prune` freed (2026-10-16). A full disk elsewhere
            // (restic's cache on this Mac) keeps restic's own words.
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
    protocol Sink: RunEngineSink {
        var cancellationMessage: String { get }
        /// Prune's live narration, hopped home by the sink itself (only it
        /// knows its concrete isolation); dropped if the run has already
        /// unwound, like the activity entry itself.
        func lineReporter(repositoryID: UUID) -> @Sendable (String) -> Void
        func stampMaintenance(repositoryID: UUID, task: MaintenanceTask, at date: Date)
        /// Not-yet-configured repositories record nothing and stamp nothing.
        func markPasswordMissing(repositoryID: UUID)
        /// The repository's drive is away: its upkeep, unstamped, waits for
        /// the drive (`AppModel.maintenanceAwaitingDrive`).
        func markDriveAway(repositoryID: UUID)
        /// The repository's server is out of reach: its upkeep, unstamped,
        /// waits for it (`AppModel.maintenanceAwaitingServer`).
        func markServerAway(repositoryID: UUID)
        /// A scheduled check read its slice of the data: the next one reads
        /// the slice after (`MaintenancePolicy.nextCheckDataSlice`).
        func advanceCheckDataSlice(repositoryID: UUID)
        func deliver(record: RunRecord, repository: Repository, transcript: RunTranscript.Contents) async
        func makeHookRunner() -> HookRunner
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
            planName: sink.label(of: repository),
            repositoryID: repository.id,
            startedAt: startedAt
        )
        let hooks = sink.makeHookRunner()
        // The backup engine's rule: restic's words for the log, bound around
        // the service call only.
        let transcript = RunTranscript()
        let hookContext = HookRunner.Context(
            event: .beforeMaintenance,
            repositoryName: sink.label(of: repository),
            repositoryID: repository.id.uuidString,
            maintenanceTask: task.rawValue,
            outcome: "starting"
        )

        // A failure leaves through the tail below (`break run`), which
        // stamps it; a drive or server that is away returns unstamped.
        run: do {
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
                        "The \(task.displayName.lowercased()) didn’t run because a hook that runs before it failed."
                    // Stamped at the tail like any other failure: a hook that
                    // always says no must not have the scheduler asking again
                    // every minute.
                    break run
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
                    sink: sink
                )
                if failures.contains(where: \.isRefusal) {
                    record.outcome = .failed
                    record.refusedShares = failures.filter(\.isRefusal).map(\.volumeName)
                    record.failureMessage = RunRecord.skippedReason(
                        sources: [repository.resolvedLocalPath], reconnectFailures: failures.reasonsByVolume
                    )
                    break run
                }
                if await sink.isDriveAway(repository) {
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
                record.detailText = RunRecord.serverUnreachableReason(repositoryName: sink.label(of: repository), why: why)
                sink.markServerAway(repositoryID: repository.id)
                await finish(
                    record: &record, repository: repository, hooks: hooks, context: hookContext,
                    transcript: transcript, sink: sink
                )
                return
            }

            switch task {
            case .check:
                // Asked for by hand, what was asked; scheduled, the
                // repository's depth — a rotation's next slice, moved on
                // once the check has read it.
                let subset: CheckDataSubset? = if let readDataPercentOverride {
                    readDataPercentOverride > 0 ? .percent(readDataPercentOverride) : nil
                } else {
                    repository.maintenance.scheduledDataSubset(for: repository.kind)
                }
                let summary = try await RunTranscript.$current.withValue(transcript) {
                    try await service.check(context, readDataSubset: subset)
                }
                record.checkRead = subset?.words ?? "structure only"
                if readDataPercentOverride == nil, case .slice = subset {
                    sink.advanceCheckDataSlice(repositoryID: repository.id)
                }
                if readDataPercentOverride == nil {
                    // Housekeeping on this Mac: it must never fail the check.
                    do {
                        try await RunTranscript.$current.withValue(transcript) { try await service.cleanupCache() }
                    } catch {
                        transcript.note("restic’s old caches weren’t removed: \(error.localizedDescription)")
                    }
                }
                let errors = summary?.numErrors ?? 0
                record.outcome = errors == 0 ? .succeeded : .completedWithErrors
                // One sentence — a dash, not a period, before the command —
                // so Format.firstSentence carries the whole verdict to the
                // Detail column and the Maintenance
                // card; restic's prune advice stays a second sentence.
                record.detailText = errors == 0
                    ? "No errors found."
                    : "\(Format.plural(errors, "error")) — restic repair can recover some damage."
                if summary?.suggestPrune == true {
                    record.detailText? += " A cleanup is suggested."
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
