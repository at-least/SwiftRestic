import Foundation

/// A lock in the way is unlocked and the work run once more. `restic
/// unlock` removes only stale locks (with restic 0.19.1 a running backup's
/// lock survived it), so a lock in use makes the second try fail too.
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

/// The pre-run gate both engines walk, asked before restic. A local
/// repository's drive is checked here because restic cannot tell it from a
/// moved folder (both exit 10, "Fatal: repository does not exist: unable to
/// open config file", restic 0.19.1); a server is probed here because restic
/// retries an unreachable one for about a quarter of an hour, then fails.
@MainActor
enum ReachabilityGate {
    fileprivate enum Verdict {
        /// Carries the reconnect failures, for a later skip's words (a
        /// folder whose share would not mount).
        case clear(reconnectFailures: [String: String])
        /// Only the user clears a refused share (its password, name, access,
        /// a leftover folder, the Keychain), so the run fails rather than
        /// skips. `sources` are the needed paths on the refused volumes,
        /// `reasons` the refusals by volume.
        case refusedShare(sources: [String], reasons: [String: String], volumes: [String])
        case driveAway(reason: String)
        case serverAway(reason: String)
    }

    /// Travels with the reason so the listing need not re-derive it from the
    /// sentence.
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
    func label(of repository: Repository) -> String
    func service() throws -> any ResticClient
    func context(for repository: Repository) async throws -> RepositoryContext
    func noteAuthFailure(_ error: Error, repositoryID: UUID)
    /// Scheduled by the sink, outside the run's task: a cancelled run leaves
    /// its task cancelled, and an inline refresh would die with it. The sink
    /// keeps it from outliving a quit.
    func scheduleSnapshotRefresh(repositoryID: UUID)
    func reconnectShares(volumes: [String]) async -> [ShareReconnect]
    /// Nil when there is nothing to ask first.
    func probeServer(of repository: Repository) async -> ServerProbe.Outcome?
    /// Nil for a path on the startup disk. Off the main actor (`VolumeProbe`).
    func isMounted(volumeOf path: String) async -> Bool?
}

extension RunEngineSink {
    /// False while the mount cannot be told.
    func isVolumeMissing(_ repository: Repository) async -> Bool {
        guard repository.kind == .local else { return false }
        return await isMounted(volumeOf: repository.resolvedLocalPath) == false
    }
}

/// One backup run's order — gate → backup → retention → closing refresh →
/// record — kept apart from its effects so a mock sink can
/// test it. Everything observable goes through the sink (`AppModel`).
@MainActor
enum BackupRunEngine {
    @MainActor
    protocol Sink: RunEngineSink {
        /// The user's Stop or the app quitting.
        var cancellationMessage: String { get }
        func label(of plan: BackupPlan) -> String
        /// Nil-anchored like the activity entry itself: a phase for a plan
        /// whose run has already unwound is dropped, never resurrected.
        func setActivityPhase(_ phase: PlanActivity.Phase, for planID: UUID)
        /// The forget's restic child is gone, so the repository's other
        /// backups may start. Leaves the phase alone, so a Stop's
        /// `.cancelling` stays.
        func endRetentionStep(for planID: UUID)
        /// Built by the sink: the @Sendable closure must capture a concrete
        /// main-actor class, not an existential or a generic parameter.
        func progressReporter(planID: UUID) -> @Sendable (OperationProgress) -> Void
        func markPlanRun(_ planID: UUID, at date: Date, wrote stamp: BackupStamp)
        /// Must stay after retention: the snapshot index takes the listing
        /// the forget left.
        func refreshSnapshots(repositoryID: UUID) async
        /// The share's reconnect was already tried; a refresh would try it
        /// again.
        func noteRepositoryAway(repositoryID: UUID, away: ReachabilityGate.Away, reason: String)
        func deliver(record: RunRecord, transcript: RunTranscript.Contents) async
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
        // Bound around the restic service calls only: the closing refresh is
        // not part of the run's log.
        let transcript = RunTranscript()
        var reconnectFailures: [String: String] = [:]

        // Every exit leaves through the tail below (`break run`), so delivery
        // runs once.
        run: do {
            let service = try sink.service()
            let context = try await sink.context(for: repository)

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
                sink.noteRepositoryAway(repositoryID: repository.id, away: .drive, reason: reason)
                break run
            case let .serverAway(reason):
                record.outcome = .skipped
                record.detailText = reason
                sink.markPlanRun(plan.id, at: startedAt, wrote: .nothing)
                sink.noteRepositoryAway(repositoryID: repository.id, away: .server, reason: reason)
                break run
            }

            // A Stop during the checks above, which do not answer a cancel.
            if Task.isCancelled { throw ResticError.cancelled }

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

            // Stamped before anything else, so nothing that follows can make
            // a good backup look like a failed one.
            sink.markPlanRun(plan.id, at: startedAt, wrote: .whole)

            // Only after a backup that produced a snapshot, so a failed run
            // never triggers a forget against stale data.
            if record.snapshotID != nil {
                sink.setActivityPhase(.applyingRetention, for: plan.id)
                do {
                    let removed = try await unlockingStaleLocks(service: service, context: context, transcript: transcript) {
                        try await service.forget(context, plan: plan)
                    }
                    transcript.note("Removed \(Format.plural(removed, "backup"))")
                } catch where ResticError.isCancellation(error) {
                    // A Stop or a quit: recorded as every stop is, never as
                    // the lock failure below. The snapshot stands and is
                    // already stamped.
                    record.setOutcome(
                        from: error, cancellationMessage: sink.cancellationMessage,
                        location: (sink.label(of: repository), repository.kind)
                    )
                    transcript.note("Stopped removing old backups")
                } catch {
                    // `forget` needs an exclusive lock while `backup` takes a
                    // shared one, so a second plan backing up to the same
                    // repository fails this with exit code 11. The data is
                    // safe and the next backup's retention runs again, so
                    // this warns instead of failing the backup.
                    record.outcome = .completedWithErrors
                    let reason = if ResticError.isRepositoryLocked(error) {
                        "the location was busy. They’re removed after the next backup."
                    } else {
                        error.localizedDescription
                    }
                    let line = RunRecord.retentionSkippedPrefix + reason
                    record.itemErrors.append(line)
                    transcript.note(line)
                }
                sink.endRetentionStep(for: plan.id)
            }

            // A stop during retention, or just after restic returned, leaves
            // this task cancelled, which would kill an inline refresh.
            if record.outcome == .cancelled || Task.isCancelled {
                sink.scheduleSnapshotRefresh(repositoryID: repository.id)
            } else {
                await sink.refreshSnapshots(repositoryID: repository.id)
            }
        } catch let ResticError.commandFailed(_, message) where message.hasPrefix(RunRecord.everySourceMissingMessage) {
            // The plan's folder is missing. On a drive that is away the run
            // is skipped: a mount brings it back (`catchUpAfterMount`).
            // Missing from a disk that is here, the run fails. The slot is
            // stamped either way, so an hourly plan does not retry every tick.
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
            // The repository's disk full gets Free Up Space as its fix: on a
            // 40 MB disk image a 57 MB backup failed with 35 MB left behind,
            // which `restic prune` freed. A full disk elsewhere (restic's
            // cache on this Mac) keeps restic's own words.
            if case let ResticError.commandFailed(_, message) = error,
               let full = RunRecord.repositoryFullMessage(resticMessage: message, repository: repository)
            {
                record.failureMessage = full
                record.repositoryFull = true
            }
            sink.noteAuthFailure(error, repositoryID: repository.id)
            sink.markPlanRun(plan.id, at: startedAt, wrote: .nothing)
        }

        await finish(record: &record, transcript: transcript, sink: sink)
    }

    private static func finish(
        record: inout RunRecord,
        transcript: RunTranscript,
        sink: Sink
    ) async {
        record.finishedAt = .now

        // A run that threw gets the first exit restic reached.
        let contents = transcript.contents
        if record.exitCode == nil { record.exitCode = contents.firstExitCode }
        await sink.deliver(record: record, transcript: contents)
    }
}

/// One `check` or `prune` run, kept apart from its effects as
/// `BackupRunEngine` is.
@MainActor
enum MaintenanceRunEngine {
    @MainActor
    protocol Sink: RunEngineSink {
        var cancellationMessage: String { get }
        func stampMaintenance(repositoryID: UUID, task: MaintenanceTask, at date: Date)
        /// Not-yet-configured repositories record nothing and stamp nothing.
        func markPasswordMissing(repositoryID: UUID)
        /// Upkeep, unstamped, waits for the drive
        /// (`AppModel.maintenanceAwaitingDrive`).
        func markDriveAway(repositoryID: UUID)
        /// Upkeep, unstamped, waits for the server
        /// (`AppModel.maintenanceAwaitingServer`).
        func markServerAway(repositoryID: UUID)
        /// `MaintenancePolicy.nextCheckDataSlice`.
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
        let transcript = RunTranscript()

        // A failure leaves through the tail below (`break run`), which
        // stamps it; a drive or server that is away returns unstamped, so
        // the task stays due and the scheduler leaves it alone until the
        // drive is back or the network changes.
        run: do {
            let service = try sink.service()
            let context = try await sink.context(for: repository)

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
                // By hand or scheduled; a slice moves on only once read.
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
                record.detailText = errors == 0
                    ? "No errors found."
                    : "\(Format.plural(errors, "error")) found. Click Repair… to fix them."
                if summary?.suggestPrune == true {
                    record.detailText? += " Freeing space is suggested."
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
            // Record and stamp nothing: the scheduler skips this repository
            // until a password exists, and nothing may claim a check happened.
            sink.markPasswordMissing(repositoryID: repository.id)
            return
        } catch {
            record.setOutcome(
                from: error, cancellationMessage: sink.cancellationMessage,
                location: (sink.label(of: repository), repository.kind)
            )
            if ResticError.isRepositoryLocked(error) {
                record.failureMessage = inUseMessage(location: sink.label(of: repository), nextRun: task == .check ? "verification" : "scheduled time")
            }
            sink.noteAuthFailure(error, repositoryID: repository.id)
        }

        // Stamped on failure too: unstamped, the scheduler would retry every
        // minute against a repository that is likely still unreachable.
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
        // Not awaited here: an inherited cancel would kill the refresh
        // mid-call and leave the listing stale.
        sink.scheduleSnapshotRefresh(repositoryID: repository.id)
    }
}
