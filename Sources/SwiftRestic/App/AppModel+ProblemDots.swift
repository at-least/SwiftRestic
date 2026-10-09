import Foundation

extension AppModel {
    // MARK: - Unseen-problem dots (the Mail grammar)

    /// The plan's newest problem run (failed or completed-with-errors) that
    /// still stands — no successful run has landed after it
    /// (`OverviewMetrics.isHealed`, the menu bar face's rule too). Seeing the
    /// failure does not heal it, so this, not the dot, is the persistent
    /// surface: the plan page's status row, the sidebar row's subtitle and
    /// a repository page's Plans rows read from it.
    func currentProblem(for planID: UUID) -> RunRecord? {
        guard let problem = newestRun(for: planID, outcomeIn: [.failed, .completedWithErrors]),
              !OverviewMetrics.isHealed(problem, in: configuration.runs)
        else { return nil }
        return problem
    }

    /// The plan's newest backup, when it backed up the rest of the plan
    /// around an away drive's folders (`RunRecord.partlySkippedReason`) —
    /// the record whose words name the drive, for the Protection card.
    /// Nil once any later backup ran, whole or not.
    func standingPartialSkip(for planID: UUID) -> RunRecord? {
        guard let newest = newestRun(for: planID), newest.isPartialSkip else { return nil }
        return newest
    }

    /// Whether the plan's sidebar row wears the blue dot: a standing problem
    /// the user has not opened since it happened. Opening the plan's page
    /// stamps it seen; a later successful run heals the dot away even unseen
    /// — the next run fixed it, so there is nothing left to intervene in.
    func showsProblemDot(for planID: UUID) -> Bool {
        unseenProblem(for: planID) != nil
    }

    /// What the dot says to VoiceOver and in its tooltip: the outcome it
    /// stands for, since a run that completed with errors wears the same dot
    /// as a failure. Nil when there is no dot.
    func unseenProblemLabel(for planID: UUID) -> String? {
        unseenProblem(for: planID).map { "\($0.outcome.displayName), not yet viewed" }
    }

    /// The standing problem behind the dot, while it is unseen.
    private func unseenProblem(for planID: UUID) -> RunRecord? {
        guard let problem = currentProblem(for: planID),
              problem.finishedAt > (problemsSeenAt[planID] ?? .distantPast)
        else { return nil }
        return problem
    }

    /// Opening the plan's page is the Mail "read". A no-op when nothing is
    /// unseen, so paging around plans never writes a stamp.
    func markProblemSeen(planID: UUID) {
        guard showsProblemDot(for: planID) else { return }
        problemsSeenAt[planID] = .now
        ProblemDotsStore.save(problemsSeenAt, to: viewDefaults)
    }

    /// Drops a deleted plan's stamp so deleted-and-recreated plans cannot
    /// inherit a reading progress that belongs to a different plan.
    func forgetProblemSeen(planID: UUID) {
        guard problemsSeenAt[planID] != nil else { return }
        problemsSeenAt[planID] = nil
        ProblemDotsStore.save(problemsSeenAt, to: viewDefaults)
    }

    /// Backups only: a plan's health is whether its backups work. Apply
    /// Retention Now… records its forget under the plan's ID, and without
    /// the kind a failed forget became the plan's problem (`isHealed` keeps
    /// a successful one from healing a backup failure). Such runs still
    /// count in Activity and the 7-day problem count, as check and prune do.
    private func newestRun(
        for planID: UUID,
        outcomeIn outcomes: Set<RunRecord.Outcome>? = nil
    ) -> RunRecord? {
        configuration.runs
            .filter { $0.planID == planID && $0.kind == .backup && outcomes?.contains($0.outcome) ?? true }
            .max { $0.finishedAt < $1.finishedAt }
    }
}

/// Persistence for the seen stamps. UserDefaults, never config.json: whether
/// a failure has been looked at is this device's view state, and the
/// configuration is rewritten whole on every edit.
enum ProblemDotsStore {
    private static let key = "unseenProblemSeenAt"

    static func load(from defaults: UserDefaults) -> [UUID: Date] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        let coded = (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
        return Dictionary(
            uniqueKeysWithValues: coded.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            }
        )
    }

    static func save(_ stamps: [UUID: Date], to defaults: UserDefaults) {
        let coded = Dictionary(uniqueKeysWithValues: stamps.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(coded) else { return }
        defaults.set(data, forKey: key)
    }
}
