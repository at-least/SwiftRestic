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
    /// repository page's Protection line and its sidebar row's warning. Read from
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

    /// The repository page's Protection line, from the same rows the
    /// repository's sidebar row reads its warning from — one derivation.
    /// Read from a view body, the lookups still register that view's
    /// observation of the state they touch.
    func protectionSummary(repositoryID: UUID, now: Date) -> ProtectionSummary? {
        let plans = plans(in: repositoryID)
        let existingRepositoryIDs = Set(configuration.repositories.map(\.id))
        return OverviewMetrics.protectionSummary(
            rows: protectionRows(for: plans, now: now),
            listingLoaded: snapshotListingOutcome(for: repositoryID) == .loaded,
            otherBackupsCount: shelves(for: repositoryID).otherBackupsCount,
            willNotRun: { planID in
                plans.first { $0.id == planID }.flatMap {
                    PlanStatus.willNotRunCaption(for: $0, existingRepositoryIDs: existingRepositoryIDs, now: now)
                }
            },
            hold: scheduleHold,
            now: now,
            relative: { Format.ago($0, now: now) }
        )
    }

    /// Exclude, from an unreadable item's line: the item's exact path, its
    /// glob characters escaped so it matches itself alone, added to the
    /// plan's patterns once. Mutates only that list, as the pause does —
    /// a whole-plan upsert from a captured copy could undo a run's stamps.
    func exclude(path: String, fromPlan planID: UUID) {
        guard let index = configuration.plans.firstIndex(where: { $0.id == planID }) else { return }
        let pattern = ResticService.globEscaped(path)
        guard !configuration.plans[index].excludePatterns.contains(pattern) else { return }
        configuration.plans[index].excludePatterns.append(pattern)
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
