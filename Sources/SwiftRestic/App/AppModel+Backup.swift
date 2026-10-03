import Foundation

extension AppModel {
    // MARK: - Running a backup

    func runBackup(planID: UUID) {
        guard !isShuttingDown else { return }
        guard !tasks.isOccupied(.plan(planID)) else { return }
        guard let plan = plan(id: planID) else { return }
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
        tasks.install(Task { [weak self] in
            if let self {
                await BackupRunEngine.perform(plan: plan, repository: repository, sink: self)
            }
            self?.tasks.clear(.plan(planID))
            // The unwind retires the token as well as the strip, so a hop
            // from this run drops from here on — restore's own rule.
            self?.backupRunTokens[planID] = nil
            // Pause and Stop's mark belongs to this run alone: left behind,
            // a later plain Stop of the plan would skip its stamp too.
            self?.pauseStoppedPlanIDs.remove(planID)
            self?.activity[planID] = nil
            self?.planProgress[planID] = nil
        }, in: .plan(planID))
    }

    /// Installs a fresh run strip — activity for the phase, a zeroed
    /// progress entry for the numbers — plus a new run token with them, so
    /// any progress hop still in flight from the previous run of this plan
    /// drops instead of writing into this one. The engine's own writes
    /// (`setActivityPhase`) need no token: they run inside `perform`,
    /// sequenced on the main actor before the unwind clears the strip —
    /// only the runner-invoked reporter executes on a background thread and
    /// hops over unsequenced.
    func installPlanActivity(planID: UUID) {
        backupRunTokens[planID] = UUID()
        activity[planID] = PlanActivity()
        planProgress[planID] = OperationProgress()
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
    /// banner (successes auto-dismiss — success that outlives its moment
    /// reads as stale — while warnings and failures stay until dismissed),
    /// the user notification, and the external channels.
    func deliver(record: RunRecord, plan: BackupPlan, transcript: RunTranscript.Contents) async {
        var record = record
        // Probed as the run ends: whether the grant was there decides, for
        // good, whether the drawer says "grant it", "it has it now, back up
        // again" or "macOS protects these anyway". The probe's own answer,
        // not `fullDiskAccess`, which an older probe may still overwrite.
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
    /// banner queue so "did it work?" is answered in the pane the user is
    /// looking at, without a trip to Activity. The queue is global, so the
    /// title names the plan with its repository — a banner arriving while
    /// another repository's page is open says whose backup it was.
    private func announceInApp(record: RunRecord) {
        let name = RunRecordPresentation.displayName(
            for: record,
            plans: configuration.plans,
            repositories: configuration.repositories
        )
        switch record.outcome {
        case .cancelled:
            // The user asked for this stop — or confirmed the quit that caused
            // it — and a banner nagging about it adds nothing.
            return
        case .succeeded:
            post(Banner(
                title: "“\(name)” backed up",
                message: "Backed up \(Format.bytes(record.dataAdded)) of new data in \(Format.duration(record.duration)).",
                isError: false
            ))
        case .completedWithErrors:
            // restic's partial success: a snapshot exists, so this is not a
            // failure — but the unreadable items are exactly what the banner
            // queue exists to keep visible. The words are the plan row's
            // (RunRecordPresentation); the fix, when the app knows one,
            // follows.
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
