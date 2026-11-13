import Foundation

extension AppModel {
    func plan(id: UUID?) -> BackupPlan? {
        configuration.plans.withID(id)
    }

    func plans(in repositoryID: UUID) -> [BackupPlan] {
        configuration.plans.filter { $0.repositoryID == repositoryID }
    }

    /// One derivation for the repository page's Status section and its
    /// sidebar row's warning. The closures read observed state, so a view
    /// body calling this still registers its observation.
    func protectionRows(for plans: [BackupPlan], now: Date) -> [UpToDateRow] {
        OverviewMetrics.protectionRows(
            plans: plans,
            latestSnapshot: { repositoryID, planID in
                self.latestSnapshot(in: repositoryID, planID: planID)
            },
            repositoryHasSnapshots: { repositoryID in
                !self.snapshots(for: repositoryID).isEmpty
            },
            listingOutcome: { repositoryID in
                self.snapshotListingOutcome(for: repositoryID)
            },
            isChecking: { repositoryID in
                self.loadingSnapshots.contains(repositoryID)
            },
            activity: { planID in
                self.activity[planID]
            },
            standingProblem: { planID in
                self.currentProblem(for: planID)
            },
            relative: { date in
                Format.ago(date, now: now)
            }
        )
    }

    /// Built on `protectionRows`, so the Status section and the sidebar
    /// warning cannot disagree.
    func upToDateSummary(repositoryID: UUID, now: Date) -> UpToDateSummary? {
        let plans = plans(in: repositoryID)
        let existingRepositoryIDs = Set(configuration.repositories.map(\.id))
        return OverviewMetrics.upToDateSummary(
            rows: protectionRows(for: plans, now: now),
            listingLoaded: snapshotListingOutcome(for: repositoryID) == .loaded,
            otherBackupsCount: shelves(for: repositoryID).otherBackupsCount,
            willNotRun: { planID in
                plans.withID(planID).flatMap {
                    PlanStatus.willNotRunCaption(for: $0, existingRepositoryIDs: existingRepositoryIDs, now: now)
                }
            },
            hold: scheduleHold(repositoryID: repositoryID, now: now),
            now: now,
            relative: { Format.ago($0, now: now) }
        )
    }

    /// Mutates only the pattern list: a whole-plan upsert from a captured copy
    /// could undo a run's stamps.
    func exclude(paths: [String], fromPlan planID: UUID) {
        updatePlan(planID) { plan in
            for pattern in paths.map(ResticService.globEscaped) where !plan.excludePatterns.contains(pattern) {
                plan.excludePatterns.append(pattern)
            }
        }
    }

    /// Changes one plan's fields in place, in one write: each write to
    /// `configuration` runs its didSet. Nothing when the plan is gone.
    func updatePlan(_ id: UUID, _ change: (inout BackupPlan) -> Void) {
        guard let index = configuration.plans.firstIndex(where: { $0.id == id }) else { return }
        change(&configuration.plans[index])
    }

    func updateRepository(_ id: UUID, _ change: (inout Repository) -> Void) {
        guard let index = configuration.repositories.firstIndex(where: { $0.id == id }) else { return }
        change(&configuration.repositories[index])
    }

    func label(of plan: BackupPlan) -> String {
        plan.label(among: configuration.plans)
    }

    func label(of repository: Repository) -> String {
        repository.label(among: configuration.repositories)
    }

    func upsert(plan: BackupPlan) {
        if let index = configuration.plans.firstIndex(where: { $0.id == plan.id }) {
            configuration.plans[index] = configuration.plans[index].merging(draft: plan)
        } else {
            configuration.plans.append(plan)
        }
    }

    func deletePlan(id: UUID) {
        // A run in flight keeps its strip until its own unwind: the
        // cancelled restic child holds the repository's lock until it is
        // gone, and the strip is what holds the other plans' backups back.
        if tasks.isOccupied(.plan(id)) {
            cancelBackup(planID: id)
        } else {
            activity[id] = nil
            planProgress[id] = nil
            retireRunToken(for: .plan(id))
        }
        removeFromBackupQueue(id)
        configuration.plans.removeAll { $0.id == id }
    }

    /// Choose New Location…: a plan's path is fixed (`BackupPlan.path`), so
    /// the new folder gets a new plan with these settings and this one is
    /// removed; its backups stay in the location, under Other backups.
    func movePlan(id: UUID, toPath path: String) throws -> UUID {
        guard let old = plan(id: id) else { throw MessageError(message: "This plan was removed.") }
        var moved = old
        moved.id = UUID()
        moved.path = path
        moved.lastRunAt = nil
        moved.lastSuccessAt = nil
        moved.staleAlertedFor = nil
        let others = configuration.plans.filter { $0.id != id }
        if let reason = EditorRequirements.plan(moved, isNew: true, among: others) {
            throw MessageError(message: reason)
        }
        deletePlan(id: id)
        createPlan(moved)
        return moved.id
    }

    func isRunning(planID: UUID) -> Bool { activity[planID] != nil }

    var runningPlanIDs: Set<UUID> { Set(activity.keys) }
}
