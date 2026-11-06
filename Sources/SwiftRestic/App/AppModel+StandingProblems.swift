import Foundation

extension AppModel {
    /// The plan's newest problem run (failed or completed-with-errors) that
    /// still stands: no successful run has landed after it
    /// (`OverviewMetrics.isHealed`, the menu bar face's rule too).
    func currentProblem(for planID: UUID) -> RunRecord? {
        guard let problem = newestRun(for: planID, outcomeIn: [.failed, .completedWithErrors]),
              !OverviewMetrics.isHealed(problem, in: configuration.runs)
        else { return nil }
        return problem
    }

    /// The plan's newest backup, when it backed up the rest of the plan
    /// around an away drive's folders (`RunRecord.isPartialSkip`, a record
    /// of an earlier build) — the record whose words name the drive, for
    /// the Status section. Nil once any later backup ran.
    func standingPartialSkip(for planID: UUID) -> RunRecord? {
        guard let newest = newestRun(for: planID), newest.isPartialSkip else { return nil }
        return newest
    }

    /// The sidebar's Activity badge: the week's problems the menu bar still
    /// stands for (`OverviewMetrics.isHealed`) that finished after Activity
    /// was last open. Opening Activity is the Mail "read" for all of them at
    /// once; the rows stay in the history (the user's pick, 2026-10-25).
    func activityBadgeCount(now: Date) -> Int {
        let seenAt = activitySeenAt ?? .distantPast
        let runs = configuration.runs
        return OverviewMetrics.problems(in: runs, since: OverviewMetrics.problemWindowStart(from: now))
            .filter { $0.finishedAt > seenAt && !OverviewMetrics.isHealed($0, in: runs) }
            .count
    }

    /// A no-op while the badge is clear, so a history that changes under an
    /// open Activity writes a stamp only when a problem landed.
    func markActivitySeen() {
        guard activityBadgeCount(now: .now) > 0 else { return }
        activitySeenAt = .now
        ActivitySeenStore.saveActivitySeenAt(activitySeenAt!, to: viewDefaults)
    }

    /// Backups only: a plan's health is whether its backups work. Apply
    /// Retention Now records its forget under the plan's ID, and without
    /// the kind a failed forget became the plan's problem (`isHealed` keeps
    /// a successful one from healing a backup failure). Such runs still
    /// count in Activity and the 7-day problem count, as check and prune do.
    private func newestRun(
        for planID: UUID,
        outcomeIn outcomes: Set<RunRecord.Outcome>? = nil
    ) -> RunRecord? {
        configuration.runs
            .filter { $0.isBackup(ofPlan: planID) && outcomes?.contains($0.outcome) ?? true }
            .max { $0.finishedAt < $1.finishedAt }
    }
}

/// UserDefaults, never config.json: whether a failure has been looked at is this
/// device's view state, and the configuration is rewritten whole on every edit.
enum ActivitySeenStore {
    private static let activityKey = "activitySeenAt"

    static func loadActivitySeenAt(from defaults: UserDefaults) -> Date? {
        defaults.object(forKey: activityKey) as? Date
    }

    static func saveActivitySeenAt(_ stamp: Date, to defaults: UserDefaults) {
        defaults.set(stamp, forKey: activityKey)
    }
}
