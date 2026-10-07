import Foundation

extension AppModel {
    // MARK: - Running a backup

    /// `askedByUser` is false for the scheduler's and a mount's runs.
    func runBackup(planID: UUID, askedByUser: Bool = true) {
        guard !isShuttingDown else { return }
        guard !tasks.isOccupied(.plan(planID)) else { return }
        guard let plan = plan(id: planID) else { return }
        if let reason = backupLockReason(for: plan) {
            post(Banner(title: "“\(plan.displayName)” waits", message: reason, isError: false))
            return
        }
        guard plan.isConfigurationComplete, let repositoryID = plan.repositoryID,
              let repository = repository(id: repositoryID)
        else {
            post(Banner(
                title: "Plan is incomplete",
                message: "Choose a repository and at least one folder to back up.",
                isError: true
            ))
            return
        }

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

    func markPlanRun(_ planID: UUID, at date: Date, succeeded: Bool) {
        // A backup Pause and Stop ended leaves its slot unstamped, so the
        // scheduler runs it again once the pause ends: restic cannot resume
        // it, and stamping would count the slot as done — the stopped run
        // would wait a whole period. Safe only because the pause holds the
        // scheduler meanwhile; a plain Stop has no pause behind it and
        // stamps, or the next tick would restart the run within a minute.
        if !succeeded, pauseStoppedPlanIDs.contains(planID) { return }
        guard let index = configuration.plans.firstIndex(where: { $0.id == planID }) else { return }
        configuration.plans[index].lastRunAt = date
        if succeeded { configuration.plans[index].lastSuccessAt = date }
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

    func addStartPing(_ event: NotificationEvent) {
        let channels = configuration.settings.notificationChannels
        tasks.addBackground(Task.detached {
            _ = await NotificationPoster.broadcast(event, to: channels)
        })
    }

    /// Stores and announces a finished run: its log, history, the in-app
    /// banner, the user notification, and the external channels.
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

    /// The in-app counterpart to `notify`: a finished backup lands in the
    /// banner queue, so "did it work?" is answered in the pane the user is
    /// looking at. The queue is global, so the title names the plan with
    /// its repository.
    private func announceInApp(record: RunRecord) {
        let name = RunRecordPresentation.displayName(
            for: record,
            plans: configuration.plans,
            repositories: configuration.repositories
        )
        switch record.outcome {
        case .cancelled:
            // The user asked for this stop, or confirmed the quit that
            // caused it — a banner would add nothing.
            return
        case .skipped:
            // A drive away at every slot of an hourly plan would post one
            // an hour, so a run nobody asked for stays in Activity, and the
            // quiet-plan alert speaks if the drive stays away. A Back Up Now
            // is answered: it ends in milliseconds, the strip's flash saying
            // nothing. Not an error, so it goes by itself.
            guard let planID = record.planID, activity[planID]?.askedByUser == true else { return }
            post(Banner(
                title: "“\(name)” skipped",
                message: record.detailText ?? "",
                isError: false,
                symbolName: RunRecord.Outcome.skipped.symbolName
            ))
        case .succeeded:
            post(Banner(
                title: "“\(name)” backed up",
                message: "Backed up \(Format.bytes(record.dataAdded)) of new data in \(Format.duration(record.duration)).",
                isError: false
            ))
        case .completedWithErrors:
            // restic's partial success: a snapshot exists, so not a failure
            // — but the unreadable items are what the banner queue exists to
            // keep visible.
            var message = RunRecordPresentation.warningBannerMessage(for: record)
            if let hint = ItemErrorDiagnosis.headline(for: record) { message += " " + hint }
            post(Banner(title: "“\(name)” finished with warnings", message: message, isError: true))
        case .failed:
            post(Banner(
                title: "Backup of “\(name)” failed",
                message: record.failureMessage ?? "",
                isError: true
            ))
        }
    }
}
