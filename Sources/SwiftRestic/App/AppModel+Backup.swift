import Foundation

extension AppModel {
    /// A held lock drops a run nobody asked for (scheduler, mount) without a
    /// banner: the next slot or mount brings it back. One the user asked for
    /// waits in the repository's queue (`startQueuedBackups`).
    func runBackup(planID: UUID, askedByUser: Bool = true) {
        guard !isShuttingDown else { return }
        guard !tasks.isOccupied(.plan(planID)) else { return }
        guard let plan = plan(id: planID) else { return }
        if let reason = backupLockReason(for: plan) {
            if askedByUser, let repositoryID = plan.repositoryID {
                enqueue(planID, in: repositoryID, askedByUser: true)
                post(Banner(title: "“\(label(of: plan))” waits", message: reason, level: .notice))
            }
            return
        }
        guard plan.isConfigurationComplete, let repositoryID = plan.repositoryID,
              let repository = repository(id: repositoryID)
        else {
            post(Banner(
                title: "Plan is incomplete",
                message: "Choose a backup location and a folder or file to back up.",
                level: .error
            ))
            return
        }

        // Back Up Now on a plan waiting its turn starts it now, out of line.
        removeFromBackupQueue(planID)
        installPlanActivity(plan: plan, repository: repository, askedByUser: askedByUser)
        tasks.install(Task { [weak self] in
            if let self {
                await BackupRunEngine.perform(plan: plan, repository: repository, sink: self)
            }
            self?.unwindPlanRun(planID)
        }, in: .plan(planID))
    }

    /// Call only from the run's own task: `clear` while a cancelled
    /// run is still unwinding would remove its slot, and quit's
    /// `tasks.drain()` would not wait for its record.
    func unwindPlanRun(_ planID: UUID) {
        tasks.clear(.plan(planID))
        // The token retires with the strip, so a hop from this run drops
        // from here on.
        retireRunToken(for: .plan(planID))
        activity[planID] = nil
        planProgress[planID] = nil
        reconcileSleepAssertion()
        startQueuedBackups()
    }

    /// One at a time per repository, as `Scheduler.duePlans`: started
    /// together, the first to finish ran its retention while the other's
    /// backup held the repository, and lost the lock (restic exit 11,
    /// "Retention skipped").
    func runBackups(planIDs: [UUID], askedByUser: Bool = true) {
        for planID in planIDs where activity[planID] == nil && !isQueued(planID) {
            if let repositoryID = plan(id: planID)?.repositoryID, planRunHolds(repositoryID) {
                enqueue(planID, in: repositoryID, askedByUser: askedByUser)
            } else {
                runBackup(planID: planID, askedByUser: askedByUser)
            }
        }
    }

    func isQueued(_ planID: UUID) -> Bool {
        backupQueue.values.contains { $0.contains { $0.planID == planID } }
    }

    private func enqueue(_ planID: UUID, in repositoryID: UUID, askedByUser: Bool) {
        guard !isQueued(planID) else { return }
        backupQueue[repositoryID, default: []].append(QueuedBackup(planID: planID, askedByUser: askedByUser))
    }

    private func planRunHolds(_ repositoryID: UUID) -> Bool {
        activity.values.contains { $0.repositoryID == repositoryID }
    }

    func removeFromBackupQueue(_ planID: UUID) {
        for (repositoryID, queue) in backupQueue where queue.contains(where: { $0.planID == planID }) {
            let rest = queue.filter { $0.planID != planID }
            backupQueue[repositoryID] = rest.isEmpty ? nil : rest
        }
    }

    /// Called as every run, check and prune unwinds. A queued run nobody
    /// asked for is dropped while a schedule hold stands, as the
    /// scheduler's runs are.
    func startQueuedBackups() {
        // Not `runBackup`'s lock test alone: a plan it re-queues behind a
        // held lock would come straight back to the front of this loop.
        for repositoryID in Array(backupQueue.keys) where !planRunHolds(repositoryID) && maintenance[repositoryID] == nil {
            while let next = backupQueue[repositoryID]?.first {
                removeFromBackupQueue(next.planID)
                guard next.askedByUser || scheduleHold(repositoryID: repositoryID) == nil else { continue }
                runBackup(planID: next.planID, askedByUser: next.askedByUser)
                if planRunHolds(repositoryID) { break }
            }
        }
    }

    /// The new run token drops a progress hop still in flight from the
    /// previous run. The engine's own writes (`setActivityPhase`) need no
    /// token: they are sequenced on the main actor before the unwind; only
    /// the reporter hops over from a background thread.
    func installPlanActivity(
        plan: BackupPlan,
        repository: Repository,
        askedByUser: Bool = true
    ) {
        rotateRunToken(for: .plan(plan.id))
        activity[plan.id] = PlanActivity(
            repositoryID: repository.id,
            planName: label(of: plan),
            askedByUser: askedByUser
        )
        planProgress[plan.id] = OperationProgress()
        reconcileSleepAssertion()
    }

    /// A Mac that idles to sleep mid-run suspends restic, and a long first
    /// backup never finishes overnight. Call wherever a run strip or
    /// maintenance entry is installed or retired. The display and a closed
    /// lid still sleep.
    func reconcileSleepAssertion() {
        let working = !activity.isEmpty || !maintenance.isEmpty
        if working, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "SwiftRestic is running a backup"
            )
        } else if !working, let token = sleepActivity {
            ProcessInfo.processInfo.endActivity(token)
            sleepActivity = nil
        }
    }

    func cancelBackup(planID: UUID) {
        activity[planID]?.phase = .cancelling
        tasks.cancel(.plan(planID))
    }

    func markPlanRun(_ planID: UUID, at date: Date, wrote stamp: BackupStamp) {
        updatePlan(planID) { plan in
            plan.lastRunAt = date
            if stamp == .whole { plan.lastSuccessAt = date }
        }
    }
}

extension AppModel: BackupRunEngine.Sink {
    func setActivityPhase(_ phase: PlanActivity.Phase, for planID: UUID) {
        // Stop's word stays: an engine phase landing after it would offer
        // Stop again.
        if activity[planID]?.phase != .cancelling { activity[planID]?.phase = phase }
        activity[planID]?.isInRetentionStep = phase == .applyingRetention
        if phase.isPastCopying { planProgress[planID] = nil }
    }

    func endRetentionStep(for planID: UUID) {
        activity[planID]?.isInRetentionStep = false
    }

    func progressReporter(planID: UUID) -> @Sendable (OperationProgress) -> Void {
        hopWriter(for: .plan(planID)) { model, progress in
            // A status queued behind the end of copying would put the
            // numbers back, frozen, under "Removing old backups…".
            guard model.activity[planID]?.phase.isPastCopying != true else { return }
            model.planProgress[planID] = progress
        }
    }

    func noteRepositoryAway(repositoryID: UUID, away: ReachabilityGate.Away, reason: String) {
        // A drive's absence reads as the listing's own; a silent server
        // keeps the run's words. The location's path can change while the
        // run looked, to one on no volume: then the run's words too.
        if away == .drive, let volume = repository(id: repositoryID)?.driveVolumeName {
            snapshotListingOutcomes[repositoryID] = .notConnected(volume: volume)
        } else {
            snapshotListingOutcomes[repositoryID] = .failed(reason)
        }
    }

    func deliver(record: RunRecord, transcript: RunTranscript.Contents) async {
        var record = record
        // Probed as the run ends and recorded: the drawer's wording reads
        // this stored answer, not `fullDiskAccess`, which an older probe
        // may still overwrite afterwards.
        record.fullDiskAccessAtRun = await refreshFullDiskAccess()
        await seal(&record, transcript: transcript)
        append(record: record)
        announceInApp(record: record)
        notify(about: record)
    }

    /// Only a skipped Back Up Now gets a banner: it ends in milliseconds and
    /// nothing but Activity records a skip. Other outcomes already show in
    /// the sidebar, plan page, Activity badge and menu bar; a skip nobody
    /// asked for (a drive away at every hourly slot) stays in Activity.
    /// The banner queue is global, so the title names the repository too.
    private func announceInApp(record: RunRecord) {
        // A removed plan's run outlives it (`deletePlan`): no banner for it.
        guard record.outcome == .skipped, let planID = record.planID,
              activity[planID]?.askedByUser == true, plan(id: planID) != nil
        else { return }
        let name = RunRecordPresentation.displayName(
            for: record,
            plans: configuration.plans,
            repositories: configuration.repositories
        )
        post(Banner(
            title: "“\(name)” skipped",
            message: record.detailText ?? "",
            level: .notice
        ))
    }
}
