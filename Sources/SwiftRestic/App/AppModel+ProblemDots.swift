import Foundation

extension AppModel {
    // MARK: - Unseen-problem dots (the Mail grammar)

    /// The plan's newest problem run (failed or completed-with-errors) that
    /// still stands — no successful run has landed after it. Seeing the
    /// failure does not heal it, so this, not the dot, is the persistent
    /// surface: the Protection card and the row's own subtitle read from it.
    func currentProblem(for planID: UUID) -> RunRecord? {
        guard let problem = newestRun(for: planID, outcomeIn: [.failed, .completedWithErrors])
        else { return nil }
        if let success = newestRun(for: planID, outcomeIn: [.succeeded]),
           success.finishedAt > problem.finishedAt {
            return nil
        }
        return problem
    }

    /// Whether the plan's sidebar row wears the blue dot: a standing problem
    /// the user has not opened since it happened. Opening the plan's page
    /// stamps it seen; a later successful run heals the dot away even unseen
    /// — the next run fixed it, so there is nothing left to intervene in.
    func showsProblemDot(for planID: UUID) -> Bool {
        guard let problem = currentProblem(for: planID) else { return false }
        return problem.finishedAt > (problemsSeenAt[planID] ?? .distantPast)
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

    private func newestRun(
        for planID: UUID,
        outcomeIn outcomes: Set<RunRecord.Outcome>
    ) -> RunRecord? {
        configuration.runs
            .filter { $0.planID == planID && outcomes.contains($0.outcome) }
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
