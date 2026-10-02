import Foundation

extension AppModel {
    // MARK: - Plans

    func plan(id: UUID?) -> BackupPlan? {
        guard let id else { return nil }
        return configuration.plans.first { $0.id == id }
    }

    /// A repository's plans, in the configuration's order — what its page
    /// lists and what its removal takes with it.
    func plans(in repositoryID: UUID) -> [BackupPlan] {
        configuration.plans.filter { $0.repositoryID == repositoryID }
    }

    /// These plans' Protection rows as of `now` — one derivation for the
    /// repository page's Plans card and its sidebar row's warning. Read from
    /// a view body, the lookups below still register that view's
    /// observation of the state they touch.
    func protectionRows(for plans: [BackupPlan], now: Date) -> [ProtectionRow] {
        OverviewMetrics.protectionRows(
            plans: plans,
            latestSnapshot: { repositoryID, planID in
                self.snapshots(for: repositoryID, planID: planID).first
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

    func upsert(plan: BackupPlan) {
        if let index = configuration.plans.firstIndex(where: { $0.id == plan.id }) {
            configuration.plans[index] = configuration.plans[index].merging(draft: plan)
        } else {
            configuration.plans.append(plan)
        }
    }

    /// Pause Schedule: Until I Resume switches the schedule off; the timed
    /// lengths leave it on with an end date, so it resumes by itself.
    /// Mutates only these two fields.
    ///
    /// A whole-struct `upsert` from a captured copy would silently undo
    /// `markPlanRun`'s stamps when a run finishes between reading the plan and
    /// writing the copy — a paused plan must not erase its own last success.
    func pausePlanSchedule(id: UUID, for length: PauseLength, now: Date = .now) {
        guard let index = configuration.plans.firstIndex(where: { $0.id == id }) else { return }
        let end = length.end(from: now)
        configuration.plans[index].isEnabled = end != nil
        configuration.plans[index].pausedUntil = end
    }

    /// Resume Schedule, for either kind of pause.
    func resumePlanSchedule(id: UUID) {
        guard let index = configuration.plans.firstIndex(where: { $0.id == id }) else { return }
        configuration.plans[index].isEnabled = true
        configuration.plans[index].pausedUntil = nil
    }

    func deletePlan(id: UUID) {
        tasks.cancel(.plan(id))
        pauseStoppedPlanIDs.remove(id)
        configuration.plans.removeAll { $0.id == id }
        activity[id] = nil
        planProgress[id] = nil
        backupRunTokens[id] = nil
        forgetProblemSeen(planID: id)
    }

    func isRunning(planID: UUID) -> Bool { activity[planID] != nil }

    var runningPlanIDs: Set<UUID> { Set(activity.keys) }
}
