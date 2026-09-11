import Foundation

extension AppModel {
    // MARK: - Plans

    func plan(id: UUID?) -> BackupPlan? {
        guard let id else { return nil }
        return configuration.plans.first { $0.id == id }
    }

    func upsert(plan: BackupPlan) {
        if let index = configuration.plans.firstIndex(where: { $0.id == plan.id }) {
            // The editor's draft was taken before the sheet opened, and a run
            // may have finished since. The stamps are written by the model,
            // never by the editor, so the stored ones win — otherwise saving
             // an edit would erase the plan's own last success.
            var updated = plan
            updated.lastRunAt = configuration.plans[index].lastRunAt
            updated.lastSuccessAt = configuration.plans[index].lastSuccessAt
            configuration.plans[index] = updated
        } else {
            configuration.plans.append(plan)
        }
    }

    /// Enables or disables a plan's schedule by mutating only that field.
    ///
    /// A whole-struct `upsert` from a captured copy would silently undo
    /// `markPlanRun`'s stamps when a run finishes between reading the plan and
    /// writing the copy — a paused plan must not erase its own last success.
    func setPlanEnabled(id: UUID, isEnabled: Bool) {
        guard let index = configuration.plans.firstIndex(where: { $0.id == id }) else { return }
        configuration.plans[index].isEnabled = isEnabled
    }

    func deletePlan(id: UUID) {
        planTasks[id]?.cancel()
        configuration.plans.removeAll { $0.id == id }
        activity[id] = nil
        forgetProblemSeen(planID: id)
    }

    func isRunning(planID: UUID) -> Bool { activity[planID] != nil }

    var runningPlanIDs: Set<UUID> { Set(activity.keys) }

    /// Whether ⌘B has something to do right now: the sidebar must be on a
    /// complete, currently idle plan.
    var canRunSelectedPlan: Bool {
        guard case let .plan(id) = sidebarSelection,
              let plan = plan(id: id)
        else { return false }
        return plan.isConfigurationComplete && !isRunning(planID: id)
    }
}
