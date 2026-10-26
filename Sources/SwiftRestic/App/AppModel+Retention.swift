import Foundation

extension AppModel {
    // MARK: - Apply Retention Now

    /// The retention sheet's preview, for a saved plan.
    func previewRetention(planID: UUID) async throws -> RetentionPreview {
        guard let plan = plan(id: planID) else { throw ResticError.planMissing }
        return try await previewRetention(plan: plan)
    }

    /// What `plan`'s retention would remove right now — the forget preview,
    /// a plain await: no slot, nothing marked busy (`--no-lock` reads beside
    /// a backup), cancelled with the caller's task. Takes a plan value
    /// rather than an ID, so a draft that is not saved yet travels too —
    /// the adopt sheet's dry run.
    func previewRetention(plan: BackupPlan) async throws -> RetentionPreview {
        guard let repository = repository(id: plan.repositoryID)
        else { throw ResticError.repositoryMissing }
        do {
            let (service, context) = try await resticContext(for: repository)
            return try await service.forgetPreview(context, plan: plan)
        } catch {
            noteAuthFailure(error, repositoryID: repository.id)
            throw error
        }
    }

    /// Runs the plan's forget now, as the post-backup retention step does —
    /// its "Also clean up" included — in the plan's own slot, so Stop, the
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
            postBusyBanner(for: repository)
            return
        }

        installPlanActivity(planID: planID)
        activity[planID]?.phase = .applyingRetention
        activity[planID]?.isBackup = false
        tasks.install(Task { [weak self] in
            if let self {
                await RetentionRunEngine.perform(plan: plan, repository: repository, sink: self)
            }
            self?.unwindPlanRun(planID)
        }, in: .plan(planID))
    }
}

// MARK: - The retention engine's view of the model

extension AppModel: RetentionRunEngine.Sink {
    /// The record, and nothing else: no banner, no local notification and
    /// no channel alert (see `RetentionRunEngine`). How it went is the plan
    /// page's — its Backups count, or its problem card and the sidebar's
    /// caption for a failure — and Activity's, where a banner over every
    /// page said it again.
    func deliverRetention(record: RunRecord, plan: BackupPlan, transcript: RunTranscript.Contents) async {
        var record = record
        await seal(&record, transcript: transcript)
        append(record: record)
    }
}
