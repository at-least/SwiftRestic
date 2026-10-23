import Foundation

extension AppModel {
    // MARK: - Running a backup

    /// `askedByUser` is false for the scheduler's and a mount's runs.
    func runBackup(planID: UUID, askedByUser: Bool = true) {
        guard !isShuttingDown else { return }
        guard !tasks.isOccupied(.plan(planID)) else { return }
        guard let plan = plan(id: planID) else { return }
        if let reason = backupLockReason(for: plan) {
            post(Banner(title: "“\(label(of: plan))” waits", message: reason, isError: false, symbolName: "clock"))
            return
        }
        guard plan.isConfigurationComplete, let repositoryID = plan.repositoryID,
              let repository = repository(id: repositoryID)
        else {
            post(Banner(
                title: "Plan is incomplete",
                message: "Choose a repository and a folder or file to back up.",
                isError: true
            ))
            return
        }

        // Back Up Now on a plan waiting its turn starts it now, out of line.
        removeFromBackupQueue(planID)
        installPlanActivity(planID: planID)
        activity[planID]?.askedByUser = askedByUser
        tasks.install(Task { [weak self] in
            if let self {
                await BackupRunEngine.perform(plan: plan, repository: repository, sink: self)
            }
            self?.unwindPlanRun(planID)
        }, in: .plan(planID))
    }

    /// Retires a plan's run — its registry slot, run token, Pause-and-Stop
    /// mark and strip. The unwind of every run in the plan's slot (backup
    /// and Apply Retention Now… alike) calls this, so the copies cannot
    /// drift. Call only from the run's own task: `clear` while a cancelled
    /// run is still unwinding would remove its slot, and quit's
    /// `tasks.drain()` would no longer wait for its record.
    func unwindPlanRun(_ planID: UUID) {
        tasks.clear(.plan(planID))
        // The token retires with the strip, so a hop from this run drops
        // from here on — the same rule as restore's unwind.
        backupRunTokens[planID] = nil
        // Pause and Stop's mark belongs to this run alone: left behind,
        // a later plain Stop of the plan would skip its stamp too.
        pauseStoppedPlanIDs.remove(planID)
        activity[planID] = nil
        planProgress[planID] = nil
        reconcileSleepAssertion()
        startQueuedBackups()
    }

    /// Back Up All Plans Now: every complete plan, less those whose
    /// repository a check or prune holds — restic would refuse their lock
    /// at once, and no plan's run ends there to start them after it. A plan
    /// whose repository another plan's run holds, its retention step too,
    /// waits its turn (`runBackups`).
    func backUpAllPlans() {
        runBackups(planIDs: configuration.plans
            .filter { plan in
                guard plan.isConfigurationComplete, let repositoryID = plan.repositoryID else { return false }
                return maintenance[repositoryID] == nil
            }
            .map(\.id))
    }

    /// Starts several plans' backups — Back Up All's, a mount's catch-up —
    /// one at a time per repository, the scheduler's rule
    /// (`Scheduler.duePlans`): started together, the first to finish ran
    /// its retention while the other's backup still held the repository,
    /// and lost the lock (restic's exit 11, "Retention skipped"). A plan
    /// whose repository another plan's run holds waits in that
    /// repository's queue — its sidebar row says so — and starts when the
    /// runs ahead of it are done (`startQueuedBackups`). A plan already
    /// running or waiting is left as it is.
    func runBackups(planIDs: [UUID], askedByUser: Bool = true) {
        for planID in planIDs where activity[planID] == nil && !isQueued(planID) {
            if let repositoryID = plan(id: planID)?.repositoryID, planRunHolds(repositoryID) {
                backupQueue[repositoryID, default: []].append(QueuedBackup(planID: planID, askedByUser: askedByUser))
            } else {
                runBackup(planID: planID, askedByUser: askedByUser)
            }
        }
    }

    func isQueued(_ planID: UUID) -> Bool {
        backupQueue.values.contains { $0.contains { $0.planID == planID } }
    }

    /// Whether a plan's run — a backup, or Apply Retention Now…'s forget —
    /// is in flight on the repository.
    private func planRunHolds(_ repositoryID: UUID) -> Bool {
        activity.keys.contains { plan(id: $0)?.repositoryID == repositoryID }
    }

    func removeFromBackupQueue(_ planID: UUID) {
        for (repositoryID, queue) in backupQueue where queue.contains(where: { $0.planID == planID }) {
            let rest = queue.filter { $0.planID != planID }
            backupQueue[repositoryID] = rest.isEmpty ? nil : rest
        }
    }

    /// Starts the next plan in each queue whose repository no plan's run
    /// holds now — called as every run unwinds. A plan that does not start
    /// (removed meanwhile, the app quitting, its repository locked) gives
    /// its turn to the next. A catch-up nobody asked for waits out the
    /// app-wide hold as the scheduler's runs do, and is dropped meanwhile:
    /// a later mount or its next slot brings it back.
    private func startQueuedBackups() {
        for repositoryID in Array(backupQueue.keys) where !planRunHolds(repositoryID) {
            while let next = backupQueue[repositoryID]?.first {
                removeFromBackupQueue(next.planID)
                guard next.askedByUser || scheduleHold == nil else { continue }
                runBackup(planID: next.planID, askedByUser: next.askedByUser)
                if planRunHolds(repositoryID) { break }
            }
        }
    }

    /// Installs a fresh run strip — activity for the phase, a zeroed
    /// progress entry — plus a new run token, so a progress hop still in
    /// flight from the plan's previous run drops instead of writing into
    /// this one. The engine's own writes (`setActivityPhase`) need no token:
    /// they run inside `perform`, sequenced on the main actor before the
    /// unwind clears the strip — only the runner-invoked reporter runs on a
    /// background thread and hops over unsequenced.
    func installPlanActivity(planID: UUID) {
        backupRunTokens[planID] = UUID()
        activity[planID] = PlanActivity()
        planProgress[planID] = OperationProgress()
        reconcileSleepAssertion()
    }

    /// Whether the Mac is kept from idle sleep for running work.
    var holdsOffSleep: Bool { sleepActivity != nil }

    /// Holds off idle system sleep while any backup or maintenance job runs,
    /// and lets go when the last one ends — a Mac that idles to sleep
    /// mid-run suspends restic, and a long first backup otherwise never
    /// finishes overnight. Called wherever a run strip is installed or
    /// retired, so every way out of a run (done, failed, stopped) passes
    /// here. The display may still sleep; a closed lid still sleeps.
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

    /// Waits for a plan's in-flight run to finish, if there is one.
    func waitForRun(planID: UUID) async {
        await tasks.task(in: .plan(planID))?.value
    }

    func cancelBackup(planID: UUID) {
        activity[planID]?.phase = .cancelling
        tasks.cancel(.plan(planID))
    }

    func markPlanRun(_ planID: UUID, at date: Date, wrote stamp: BackupStamp) {
        // A backup Pause and Stop ended leaves its slot unstamped, so the
        // scheduler runs it again once the pause ends: restic cannot resume
        // it, and stamping would count the slot as done — the stopped run
        // would wait a whole period. Safe only because the pause holds the
        // scheduler meanwhile; a plain Stop has no pause behind it and
        // stamps, or the next tick would restart the run within a minute.
        if stamp == .nothing, pauseStoppedPlanIDs.contains(planID) { return }
        guard let index = configuration.plans.firstIndex(where: { $0.id == planID }) else { return }
        configuration.plans[index].lastRunAt = date
        if stamp == .whole { configuration.plans[index].lastSuccessAt = date }
    }
}

// MARK: - The backup engine's view of the model

extension AppModel: BackupRunEngine.Sink {
    func setActivityPhase(_ phase: PlanActivity.Phase, for planID: UUID) {
        activity[planID]?.phase = phase
    }

    func progressReporter(planID: UUID) -> @Sendable (OperationProgress) -> Void {
        let token = backupRunTokens[planID]
        return { [weak self] progress in
            Task { @MainActor in
                // The token, not the strip's existence, is the guard: after
                // run N unwinds, a hop from run N must drop even though run
                // N+1 has already installed its own strip. The write lands
                // in `planProgress` — its own observable storage — so the
                // tick invalidates the running strip, not every view that
                // reads the plan's phase.
                guard let self, self.backupRunTokens[planID] == token else { return }
                self.planProgress[planID] = progress
            }
        }
    }

    func noteRepositoryAway(repositoryID: UUID, reason: String) {
        snapshotListingOutcomes[repositoryID] = .failed(reason)
    }

    func addStartPing(_ event: NotificationEvent) {
        let channels = configuration.settings.notificationChannels
        tasks.addBackground(Task.detached {
            _ = await NotificationPoster.broadcast(event, to: channels)
        })
    }

    /// Stores and announces a finished run: its log, history, the user
    /// notification, and the external channels — and, for a Back Up Now
    /// that was skipped, the in-app banner.
    func deliver(record: RunRecord, plan: BackupPlan, transcript: RunTranscript.Contents) async {
        var record = record
        // Probed as the run ends and recorded: the drawer's wording reads
        // this stored answer, not `fullDiskAccess`, which an older probe
        // may still overwrite afterwards.
        record.fullDiskAccessAtRun = await refreshFullDiskAccess()
        await seal(&record, transcript: transcript)
        append(record: record)
        announceInApp(record: record)
        notify(about: record)
        await broadcast(record: record, plan: plan)
    }

    func makeHookRunner() -> HookRunner {
        HookRunner(runner: runner)
    }

    /// A Back Up Now that was skipped, answered in the window: it ends in
    /// milliseconds, the strip's flash saying nothing, and no surface but
    /// Activity records a skip. How every other run went is the sidebar's
    /// caption, the plan page's problem card, Activity's badge and the menu
    /// bar's — where a banner over every page said it again, the whole
    /// queue's worth after Back Up All.
    /// A skip nobody asked for — a drive away at every slot of an hourly
    /// plan — stays in Activity, and the quiet-plan alert speaks if the
    /// drive stays away. The queue is global, so the title names the plan
    /// with its repository.
    private func announceInApp(record: RunRecord) {
        guard record.outcome == .skipped, let planID = record.planID,
              activity[planID]?.askedByUser == true
        else { return }
        let name = RunRecordPresentation.displayName(
            for: record,
            plans: configuration.plans,
            repositories: configuration.repositories
        )
        post(Banner(
            title: "“\(name)” skipped",
            message: record.detailText ?? "",
            isError: false,
            symbolName: RunRecord.Outcome.skipped.symbolName
        ))
    }
}
