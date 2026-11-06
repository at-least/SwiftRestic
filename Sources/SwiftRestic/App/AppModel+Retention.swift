import Foundation

extension AppModel {
    /// What `plan`'s retention would remove right now: a plain await with no
    /// slot and nothing marked busy (`--no-lock` reads beside a backup),
    /// cancelled with the caller's task. Takes a value, so an unsaved draft
    /// travels too.
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

    func startQuietPlanRun(
        planID: UUID,
        work: PlanActivity.Work,
        perform: @escaping @MainActor (BackupPlan, Repository, AppModel) async -> Void
    ) {
        guard !isShuttingDown else { return }
        guard !tasks.isOccupied(.plan(planID)) else { return }
        guard let plan = plan(id: planID), let repository = repository(id: plan.repositoryID) else { return }
        guard !busyRepositoryIDs.contains(repository.id) else {
            postBusyBanner(for: repository)
            return
        }

        installPlanActivity(plan: plan, repository: repository)
        activity[planID]?.work = work
        activity[planID]?.phase = switch work {
        case .removeFromEarlierBackups: .removingFromEarlierBackups
        case .backup: preconditionFailure("a backup runs through runBackup, not a quiet run")
        }
        tasks.install(Task { [weak self] in
            if let self {
                await perform(plan, repository, self)
            }
            self?.unwindPlanRun(planID)
        }, in: .plan(planID))
    }
}

extension AppModel: QuietPlanRunSink {
    /// The record, and nothing else: no banner, no local notification and
    /// no channel alert (see `RetentionRunEngine`). How it went is the plan
    /// page's — its Backups count, or its problem card and the sidebar's
    /// caption for a failure — and Activity's, where a banner over every
    /// page said it again.
    func deliverQuietly(record: RunRecord, plan: BackupPlan, transcript: RunTranscript.Contents) async {
        var record = record
        await seal(&record, transcript: transcript)
        append(record: record)
    }
}

extension AppModel {
    func itemsInEarlierBackups(planID: UUID) async throws -> [EarlierBackupItem] {
        guard let plan = plan(id: planID), let repositoryID = plan.repositoryID else { return [] }
        var items: [EarlierBackupItem] = []
        for excluded in ResticService.excludedPaths(of: plan) {
            let holders = try await indexedHolders(ofPath: excluded.path, inChain: ResticService.planTag(planID), repositoryID: repositoryID)
            if !holders.isEmpty { items.append(EarlierBackupItem(excluded: excluded, backups: holders)) }
        }
        return items
    }

    func removeFromEarlierBackupsBlocker(planID: UUID) -> String? {
        guard let plan = plan(id: planID), let repository = repository(id: plan.repositoryID) else {
            return BackupPlan.incompleteConfigurationReason
        }
        if let absence = resticAbsence { return absence.sentence }
        guard !busyRepositoryIDs.contains(repository.id) else {
            return BackupPlan.busyRepositoryReason
        }
        return nil
    }

    func removeFromEarlierBackups(planID: UUID, items: [ExcludedPath]) {
        guard !items.isEmpty else { return }
        startQuietPlanRun(planID: planID, work: .removeFromEarlierBackups) { plan, repository, sink in
            await RewriteRunEngine.perform(plan: plan, repository: repository, removing: items, sink: sink)
        }
    }
}
