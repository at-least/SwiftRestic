import Foundation

/// Runs restic work under the run's transcript; a lock in its way is
/// unlocked and the work run once more, unasked. `restic unlock` removes
/// only stale locks — with restic 0.19.1 a running backup's lock survived
/// it — so a lock in use stays and the second try fails as the first did.
@MainActor
private func unlockingStaleLocks<T>(
    service: any ResticClient,
    context: RepositoryContext,
    transcript: RunTranscript,
    _ work: () async throws -> T
) async throws -> T {
    do {
        return try await RunTranscript.$current.withValue(transcript) { try await work() }
    } catch where ResticError.isRepositoryLocked(error) {
        transcript.note("The location was locked: removing stale locks and trying again")
        return try await RunTranscript.$current.withValue(transcript) {
            try await service.unlock(context)
            return try await work()
        }
    }
}

/// A run a lock still stopped after `unlockingStaleLocks`: someone is using
/// the location, and the scheduler's next run of the same kind tries again.
private func inUseMessage(location: String, nextRun: String) -> String {
    "“\(location)” is in use by another Mac or app. SwiftRestic tries again at the next \(nextRun)."
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

/// The pre-run gate the backup and maintenance engines walk, stated once:
/// the saved shares `paths` need are reconnected first; a share that refused fails the run in the skip's words,
/// never asking restic, the editor that holds the share's password being
/// the fix; a local repository's drive that is away skips the run —
/// restic's "does not exist" could not tell it from a moved folder (both
/// exit 10, "Fatal: repository does not exist: unable to open config file",
/// restic 0.19.1); a network repository's server out of reach skips it
/// within seconds — restic would retry such a server for about a quarter
/// of an hour, then fail.
@MainActor
enum ReachabilityGate {
    fileprivate enum Verdict {
        /// Run. Carries the reconnect failures, for a partial skip's words
        /// later in the run (a folder whose share would not mount).
        case clear(reconnectFailures: [String: String])
        /// A saved share refused to mount — its password, its name, its
        /// access, a leftover folder, the Keychain. Only the user clears
        /// this, so the run fails in the skip's words. `sources` are the
        /// needed paths sitting on the refused volumes, `reasons` their
        /// refusals by volume.
        case refusedShare(sources: [String], reasons: [String: String], volumes: [String])
        /// The repository's drive is away; the run is skipped.
        case driveAway(reason: String)
        /// The repository's server is out of reach; the run is skipped.
        case serverAway(reason: String)
    }

    /// Which away a skip verdict named: the repository's drive, or its
    /// server. Travels with the reason so the listing's answer need not
    /// re-derive it from the sentence.
    enum Away {
        case drive, server
    }

    fileprivate static func verdict(
        of repository: Repository,
        needing paths: [String],
        sink: some RunEngineSink,
        transcript: RunTranscript
    ) async -> Verdict {
        let failures = await reconnectAwayShares(of: paths, transcript: transcript, sink: sink)
        let refused = failures.filter(\.isRefusal)
        if !refused.isEmpty {
            let volumes = refused.map(\.volumeName)
            return .refusedShare(
                sources: paths.filter { VolumePresence.volumeName(of: $0).map(volumes.contains) == true },
                reasons: refused.reasonsByVolume,
                volumes: volumes
            )
        }
        if repository.kind == .local {
            if await sink.isVolumeMissing(repository) {
                return .driveAway(reason: RunRecord.skippedReason(
                    sources: [repository.resolvedLocalPath],
                    reconnectFailures: failures.reasonsByVolume
                ))
            }
        } else if case let .unreachable(why)? = await sink.probeServer(of: repository) {
            return .serverAway(reason: RunRecord.serverUnreachableReason(
                repositoryName: sink.label(of: repository), why: why
            ))
        }
        return .clear(reconnectFailures: failures.reasonsByVolume)
    }
}

@MainActor
protocol RunEngineSink: AnyObject {
    /// What every surface calls the repository (`AppModel.label(of:)`): the
    /// run's record says it.
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
    func isVolumeMissing(_ repository: Repository) async -> Bool {
        guard repository.kind == .local else { return false }
        return await isMounted(volumeOf: repository.resolvedLocalPath) == false
    }
}

/// One backup run's lifecycle, so the sequencing — gate → start ping →
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
        /// run's record and notifications say it.
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
        /// The listing of a repository whose drive or server the run found
        /// away, in the run's words — its share's reconnect already tried,
        /// and not tried again by a refresh.
        func noteRepositoryAway(repositoryID: UUID, away: ReachabilityGate.Away, reason: String)
        /// Stores and announces a finished run: its log, run history,
        /// banner, user notification, external channels.
        func deliver(record: RunRecord, plan: BackupPlan, transcript: RunTranscript.Contents) async
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
        // What restic said, for the run's log: bound around the restic
        // service calls only — the closing refresh is not part of the run.
        let transcript = RunTranscript()
        // Why each away share this run needed could not be reconnected, by
        // volume name, for the skip's words.
        var reconnectFailures: [String: String] = [:]

        // Every exit but a missing password leaves through the tail below
        // (`break run`), so delivery runs once.
        run: do {
            let service = try sink.service()
            let context = try await sink.context(for: repository)

            // The gate: this run's shares — the repository's folder, the
            // plan's — reconnected, a refusal failed in the skip's words,
            // the drive or server that is away skipped.
            switch await ReachabilityGate.verdict(
                of: repository,
                needing: (repository.kind == .local ? [repository.resolvedLocalPath] : [])
                    + [plan.resolvedPath],
                sink: sink,
                transcript: transcript
            ) {
            case let .clear(failures):
                reconnectFailures = failures
            case let .refusedShare(sources, reasons, volumes):
                record.outcome = .failed
                record.refusedShares = volumes
                record.failureMessage = RunRecord.skippedReason(sources: sources, reconnectFailures: reasons)
                sink.markPlanRun(plan.id, at: startedAt, wrote: .nothing)
                break run
            case let .driveAway(reason):
                record.outcome = .skipped
                record.detailText = reason
                sink.markPlanRun(plan.id, at: startedAt, wrote: .nothing)
                // The listing learns it now, not at the next launch, and
                // why: a refresh would reconnect the share again.
                sink.noteRepositoryAway(repositoryID: repository.id, away: .drive, reason: reason)
                break run
            case let .serverAway(reason):
                record.outcome = .skipped
                record.detailText = reason
                sink.markPlanRun(plan.id, at: startedAt, wrote: .nothing)
                sink.noteRepositoryAway(repositoryID: repository.id, away: .server, reason: reason)
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
            let outcome = try await unlockingStaleLocks(service: service, context: context, transcript: transcript) {
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
                    let removed = try await unlockingStaleLocks(service: service, context: context, transcript: transcript) {
                        try await service.forget(context, plan: plan)
                    }
                    transcript.note("Removed \(Format.plural(removed, "backup"))")
                } catch where ResticError.isCancellation(error) {
                    // The user's stop, "Stop Removing Old Backups" in the Plan
                    // menu or the tray, or a quit: recorded
                    // as every stop is, never as the lock failure below. The
                    // snapshot stands and is already stamped, so nothing
                    // stamps the run again.
                    record.setOutcome(
                        from: error, cancellationMessage: sink.cancellationMessage,
                        location: (sink.label(of: repository), repository.kind)
                    )
                    transcript.note("Stopped removing old backups")
                } catch {
                    // `forget` needs an exclusive repository lock while `backup`
                    // takes a shared one, so a second plan backing up to the
                    // same repository fails this with exit code 11, its lock
                    // live. The data is safe; warn instead of failing the
                    // whole backup — the next backup's retention runs again.
                    record.outcome = .completedWithErrors
                    let reason = if ResticError.isRepositoryLocked(error) {
                        "another backup or job was using the location. Old backups are removed after the next backup."
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
            record.setOutcome(
                from: error, cancellationMessage: sink.cancellationMessage,
                location: (sink.label(of: repository), repository.kind)
            )
            if ResticError.isRepositoryLocked(error) {
                record.failureMessage = inUseMessage(location: sink.label(of: repository), nextRun: "backup")
            }
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

        await finish(record: &record, plan: plan, transcript: transcript, sink: sink)
    }

    private static func finish(
        record: inout RunRecord,
        plan: BackupPlan,
        transcript: RunTranscript,
        sink: Sink
    ) async {
        record.finishedAt = .now

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
    }

    static func perform(
        repository: Repository,
        task: MaintenanceTask,
        sink: Sink
    ) async {
        let startedAt = Date.now
        var record = RunRecord(
            kind: task == .prune ? .prune : .check,
            planName: sink.label(of: repository),
            repositoryID: repository.id,
            startedAt: startedAt
        )
        // The backup engine's rule: restic's words for the log, bound around
        // the service call only.
        let transcript = RunTranscript()

        // A failure leaves through the tail below (`break run`), which
        // stamps it; a drive or server that is away returns unstamped.
        run: do {
            let service = try sink.service()
            let context = try await sink.context(for: repository)

            // The gate, as a backup walks it. Refused, the run fails in the
            // skip's words; its drive or server still away — no share saved,
            // or one out of reach — the run waits for it, Skipped,
            // unstamped, so the task stays due and the scheduler leaves it
            // alone until the drive is back (`markDriveAway`) or the
            // network changes (`markServerAway`).
            switch await ReachabilityGate.verdict(
                of: repository,
                needing: repository.kind == .local ? [repository.resolvedLocalPath] : [],
                sink: sink,
                transcript: transcript
            ) {
            case .clear:
                break
            case let .refusedShare(sources, reasons, volumes):
                record.outcome = .failed
                record.refusedShares = volumes
                record.failureMessage = RunRecord.skippedReason(sources: sources, reconnectFailures: reasons)
                break run
            case let .driveAway(reason):
                record.outcome = .skipped
                record.detailText = reason
                sink.markDriveAway(repositoryID: repository.id)
                await finish(
                    record: &record, repository: repository, transcript: transcript, sink: sink
                )
                return
            case let .serverAway(reason):
                record.outcome = .skipped
                record.detailText = reason
                sink.markServerAway(repositoryID: repository.id)
                await finish(
                    record: &record, repository: repository, transcript: transcript, sink: sink
                )
                return
            }

            switch task {
            case .check:
                // By hand or scheduled, the repository's depth — a
                // rotation's next slice, moved on once the check has read it.
                let subset = repository.maintenance.scheduledDataSubset(for: repository.kind)
                let summary = try await unlockingStaleLocks(service: service, context: context, transcript: transcript) {
                    try await service.check(context, readDataSubset: subset)
                }
                if case .slice = subset {
                    sink.advanceCheckDataSlice(repositoryID: repository.id)
                }
                // Housekeeping on this Mac: it must never fail the check.
                do {
                    try await RunTranscript.$current.withValue(transcript) { try await service.cleanupCache() }
                } catch {
                    transcript.note("restic’s old caches weren’t removed: \(error.localizedDescription)")
                }
                let errors = summary?.numErrors ?? 0
                record.outcome = errors == 0 ? .succeeded : .completedWithErrors
                // The count is the first sentence, which the Result column
                // and the Maintenance row show; the repair steps follow for
                // the drawer. The commands as the console takes them: it
                // supplies `restic` itself.
                record.detailText = errors == 0
                    ? "No errors found."
                    : "\(Format.plural(errors, "error")) found. Some damage can be repaired in the restic Console: repair index, then repair snapshots."
                if summary?.suggestPrune == true {
                    record.detailText? += " A cleanup is suggested."
                }
            case .prune:
                let output = try await unlockingStaleLocks(service: service, context: context, transcript: transcript) {
                    try await service.prune(context, onRawLine: nil)
                }
                // Nothing freed says nothing: "Freed Zero KB." reads as a fault.
                record.detailText = ResticService.pruneFreedBytes(in: output)
                    .flatMap { $0 > 0 ? "Freed \(Format.bytes($0))." : nil }
                record.outcome = .succeeded
            }
        } catch ResticError.passwordMissing {
            // Not finished being set up. Record nothing and stamp nothing: the
            // scheduler skips this repository until a password exists, and the
            // repository screen must not claim a check happened.
            sink.markPasswordMissing(repositoryID: repository.id)
            return
        } catch {
            record.setOutcome(
                from: error, cancellationMessage: sink.cancellationMessage,
                location: (sink.label(of: repository), repository.kind)
            )
            if ResticError.isRepositoryLocked(error) {
                record.failureMessage = inUseMessage(location: sink.label(of: repository), nextRun: task.displayName.lowercased())
            }
            sink.noteAuthFailure(error, repositoryID: repository.id)
        }

        // Stamp the timestamp whatever happened. Leaving it unset on failure would
        // make the scheduler retry every minute against a repository that is very
        // likely still unreachable.
        sink.stampMaintenance(repositoryID: repository.id, task: task, at: startedAt)
        await finish(
            record: &record, repository: repository, transcript: transcript, sink: sink
        )
    }

    private static func finish(
        record: inout RunRecord,
        repository: Repository,
        transcript: RunTranscript,
        sink: Sink
    ) async {
        record.finishedAt = .now
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
