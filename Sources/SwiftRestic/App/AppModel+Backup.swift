import Foundation

extension AppModel {
    // MARK: - Running a backup

    func runBackup(planID: UUID) {
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

        activity[planID] = PlanActivity()
        tasks.install(Task { [weak self] in
            if let self {
                await BackupRunEngine.perform(plan: plan, repository: repository, sink: self)
            }
            self?.tasks.clear(.plan(planID))
            self?.activity[planID] = nil
        }, in: .plan(planID))
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
        { [weak self] progress in
            Task { @MainActor in
                guard let self, self.activity[planID] != nil else { return }
                self.activity[planID]?.progress = progress
            }
        }
    }

    func addStartPing(_ event: NotificationEvent) {
        let channels = configuration.settings.notificationChannels
        tasks.addBackground(Task.detached {
            _ = await NotificationPoster.broadcast(event, to: channels)
        })
    }

    /// Stores and announces a finished run: history, the in-app banner
    /// (successes auto-dismiss — success that outlives its moment reads as
    /// stale — while warnings and failures stay until dismissed), the user
    /// notification, and the external channels.
    func deliver(record: RunRecord, plan: BackupPlan) async {
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
    /// looking at, without a trip to Activity.
    private func announceInApp(record: RunRecord) {
        switch record.outcome {
        case .cancelled:
            // The user asked for this stop — or confirmed the quit that caused
            // it — and a banner nagging about it adds nothing.
            return
        case .succeeded:
            post(Banner(
                title: "“\(record.planName)” backed up",
                message: "Backed up \(Format.bytes(record.dataAdded)) of new data in \(Format.duration(record.duration)).",
                isError: false
            ))
        case .completedWithErrors:
            // restic's partial success: a snapshot exists, so this is not a
            // failure — but the unreadable items are exactly what the banner
            // queue exists to keep visible.
            let count = max(record.itemErrorCount, record.itemErrors.count)
            let message = record.itemErrors.first.map {
                "\($0) — \(Format.plural(count, "unreadable item")) in total."
            } ?? record.failureMessage ?? "Finished, but restic reported problems."
            post(Banner(title: "“\(record.planName)” finished with warnings", message: message, isError: true))
        case .failed:
            post(Banner(
                title: "Backup of “\(record.planName)” failed",
                message: record.failureMessage ?? "",
                isError: true
            ))
        }
    }
}
