import Foundation

extension AppModel {
    /// The same `isHealed` rule as the menu bar face.
    func currentProblem(for planID: UUID) -> RunRecord? {
        guard let problem = newestRun(for: planID, outcomeIn: [.failed, .completedWithErrors]),
              !OverviewMetrics.isHealed(problem, in: configuration.runs)
        else { return nil }
        return problem
    }

    /// Opening Activity marks every problem read at once, like Mail; the
    /// rows stay in the history (the user's pick).
    func activityBadgeCount(now: Date) -> Int {
        let seenAt = activitySeenAt ?? .distantPast
        let runs = configuration.runs
        return OverviewMetrics.problems(in: runs, since: OverviewMetrics.problemWindowStart(from: now))
            .filter { $0.finishedAt > seenAt && !OverviewMetrics.isHealed($0, in: runs) }
            .count
    }

    /// A no-op while the badge is clear, so an open Activity writes a stamp
    /// only when a problem landed.
    func markActivitySeen() {
        guard activityBadgeCount(now: .now) > 0 else { return }
        activitySeenAt = .now
        ActivitySeenStore.saveActivitySeenAt(activitySeenAt!, to: viewDefaults)
    }

    /// Backups only: Apply Retention Now records its forget under the
    /// plan's ID, and a failed forget is not the plan's problem.
    private func newestRun(
        for planID: UUID,
        outcomeIn outcomes: Set<RunRecord.Outcome>? = nil
    ) -> RunRecord? {
        configuration.runs
            .filter { $0.isBackup(ofPlan: planID) && outcomes?.contains($0.outcome) ?? true }
            .max { $0.finishedAt < $1.finishedAt }
    }
}

/// UserDefaults, not config.json: this device's view state, and the
/// configuration is rewritten whole on every edit.
enum ActivitySeenStore {
    private static let activityKey = "activitySeenAt"

    static func loadActivitySeenAt(from defaults: UserDefaults) -> Date? {
        defaults.object(forKey: activityKey) as? Date
    }

    fileprivate static func saveActivitySeenAt(_ stamp: Date, to defaults: UserDefaults) {
        defaults.set(stamp, forKey: activityKey)
    }
}
