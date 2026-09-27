import Foundation

extension AppModel {
    // MARK: - Apply Retention Now

    /// What the plan's retention would remove right now — the sheet's
    /// preview. A plain await, not a run: it takes no slot and marks nothing
    /// busy, because `--no-lock` lets it read beside a backup, and it is
    /// cancelled with the sheet's task.
    func previewRetention(planID: UUID) async throws -> RetentionPreview {
        guard let plan = plan(id: planID),
              let repository = repository(id: plan.repositoryID)
        else { throw ResticError.repositoryMissing }
        do {
            let service = try service()
            let context = try await context(for: repository)
            return try await service.forgetPreview(context, plan: plan)
        } catch {
            noteAuthFailure(error, repositoryID: repository.id)
            throw error
        }
    }

    /// Runs the plan's forget now, as the post-backup retention step does —
    /// its "Also prune" included — in the plan's own slot, so Stop, the
    /// sidebar's spinner, quitting and the busy repository behave as for a
    /// backup. Guarded like `runMaintenance`: a busy repository says so
    /// instead of queueing.
    func applyRetention(planID: UUID) {
        guard !isShuttingDown else { return }
        guard !tasks.isOccupied(.plan(planID)) else { return }
        guard let plan = plan(id: planID), plan.retention.isSafeToRun,
              let repository = repository(id: plan.repositoryID)
        else { return }
        guard !busyRepositoryIDs.contains(repository.id) else {
            post(Banner(
                title: "“\(repository.name)” is busy",
                message: "A backup or another maintenance job is already using this repository.",
                isError: false
            ))
            return
        }

        installPlanActivity(planID: planID)
        activity[planID]?.phase = .applyingRetention
        activity[planID]?.isBackup = false
        tasks.install(Task { [weak self] in
            if let self {
                await RetentionRunEngine.perform(plan: plan, repository: repository, sink: self)
            }
            // `runBackup`'s unwind, step for step: the same slot, token and
            // strip — and Pause and Stop's mark, which stops this run too.
            self?.tasks.clear(.plan(planID))
            self?.backupRunTokens[planID] = nil
            self?.pauseStoppedPlanIDs.remove(planID)
            self?.activity[planID] = nil
            self?.planProgress[planID] = nil
        }, in: .plan(planID))
    }
}

// MARK: - The retention engine's view of the model

extension AppModel: RetentionRunEngine.Sink {
    /// The record and the window's banner, and nothing else: no local
    /// notification and no channel alert (see `RetentionRunEngine`).
    func deliverRetention(record: RunRecord, plan: BackupPlan, transcript: RunTranscript.Contents) async {
        var record = record
        await seal(&record, transcript: transcript)
        append(record: record)
        switch record.outcome {
        case .succeeded, .completedWithErrors:
            post(Banner(
                title: "Applied retention to “\(record.planName)”",
                message: record.detailText ?? "",
                isError: false
            ))
        case .failed:
            post(Banner(
                title: "Could not apply retention to “\(record.planName)”",
                message: record.failureMessage ?? "",
                isError: true
            ))
        case .cancelled:
            // The user's own Stop, or the quit they confirmed: nothing to add.
            break
        }
    }
}
