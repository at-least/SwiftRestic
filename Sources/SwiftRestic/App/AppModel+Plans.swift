import Foundation

extension AppModel {
    // MARK: - Plans

    func plan(id: UUID?) -> BackupPlan? {
        guard let id else { return nil }
        return configuration.plans.first { $0.id == id }
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
