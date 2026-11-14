import Foundation
import Testing

@MainActor
@Suite("Standing problems")
struct StandingProblemTests {
    private let planID = UUID()
    private let otherPlanID = UUID()
    private let suiteName = "SwiftResticStandingProblemTests"

    private func makeModel() -> AppModel {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppModel(
            store: ConfigStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("StandingProblemTests-\(UUID().uuidString)")),
            secrets: .inMemory(),
            defaults: defaults
        )
    }

    private func record(
        _ outcome: RunRecord.Outcome,
        finishedAt: Date,
        planID: UUID? = nil
    ) -> RunRecord {
        var record = RunRecord()
        record.planID = planID ?? self.planID
        record.outcome = outcome
        record.finishedAt = finishedAt
        return record
    }

    private let hour1 = Date(timeIntervalSince1970: 1_700_003_600)
    private let hour2 = Date(timeIntervalSince1970: 1_700_007_200)

    @Test("a standing failure is named")
    func standingFailureNamed() {
        let model = makeModel()
        model.configuration.runs = [.failed, .completedWithErrors, .cancelled].map {
            record($0, finishedAt: hour1)
        }

        #expect(model.currentProblem(for: planID)?.outcome == .failed)
    }

    @Test("a later successful run heals it")
    func successHeals() {
        let model = makeModel()
        model.configuration.runs = [
            record(.succeeded, finishedAt: hour2),
            record(.failed, finishedAt: hour1),
        ]

        #expect(model.currentProblem(for: planID) == nil)
    }

    @Test("a success older than the failure does not heal it")
    func olderSuccessDoesNotHeal() {
        let model = makeModel()
        model.configuration.runs = [
            record(.failed, finishedAt: hour2),
            record(.succeeded, finishedAt: hour1),
        ]

        #expect(model.currentProblem(for: planID)?.outcome == .failed)
    }

    @Test("cancelled is not a problem")
    func cancelledIsQuiet() {
        let model = makeModel()
        model.configuration.runs = [record(.cancelled, finishedAt: hour1)]

        #expect(model.currentProblem(for: planID) == nil)
    }

    @Test("another plan's failure is not this plan's")
    func plansDoNotLeak() {
        let model = makeModel()
        model.configuration.runs = [record(.failed, finishedAt: hour1, planID: otherPlanID)]

        #expect(model.currentProblem(for: planID) == nil)
        #expect(model.currentProblem(for: otherPlanID) != nil)
    }

    @Test("opening Activity clears its badge; the history keeps the run; a later problem badges again")
    func activityBadgeClearsOnOpen() {
        let model = makeModel()
        // Stamps are "now": the first problem predates the mark, the second
        // lands after it, as real runs do.
        // A failure its plan's next backup healed is not the badge's, as it
        // is not the menu bar's.
        model.configuration.runs = [
            record(.succeeded, finishedAt: .now.addingTimeInterval(-1_800)),
            record(.failed, finishedAt: .now.addingTimeInterval(-3_600)),
        ]
        #expect(model.activityBadgeCount(now: .now) == 0)
        #expect(MenuBarStatus.problemLine(runs: model.configuration.runs, hasNoRepositories: false) == nil)

        model.configuration.runs = [record(.failed, finishedAt: .now.addingTimeInterval(-3_600))]
        #expect(model.activityBadgeCount(now: .now) == 1)

        model.markActivitySeen()
        #expect(model.activityBadgeCount(now: .now) == 0)
        #expect(OverviewMetrics.problems(
            in: model.configuration.runs,
            since: OverviewMetrics.problemWindowStart(from: .now)
        ).count == 1)

        model.configuration.runs.insert(record(.completedWithErrors, finishedAt: .now.addingTimeInterval(1)), at: 0)
        #expect(model.activityBadgeCount(now: .now) == 1)
    }

    @Test("the Activity stamp survives a relaunch")
    func activityStampPersists() {
        let model = makeModel()
        model.configuration.runs = [record(.failed, finishedAt: .now.addingTimeInterval(-60))]
        model.markActivitySeen()

        let relaunched = AppModel(
            store: ConfigStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("StandingProblemTests-\(UUID().uuidString)")),
            secrets: .inMemory(),
            defaults: UserDefaults(suiteName: suiteName)!
        )
        relaunched.configuration.runs = model.configuration.runs
        #expect(relaunched.activityBadgeCount(now: .now) == 0)
    }
}
