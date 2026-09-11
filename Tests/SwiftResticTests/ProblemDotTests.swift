import Foundation
import Testing

/// The sidebar's Mail-dot logic: a plan's row wears the dot while its newest
/// failure stands unseen, and the dot clears on "read" (opening the plan's
/// page) or on healing (a later successful run) — while `currentProblem`
/// keeps naming the failure either way, until a success really retires it.
@MainActor
@Suite("Unseen problem dots")
struct ProblemDotTests {
    private let planID = UUID()
    private let otherPlanID = UUID()
    private let suiteName = "SwiftResticProblemDotTests"

    private func makeModel() -> AppModel {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppModel(
            store: ConfigStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ProblemDotTests-\(UUID().uuidString)")),
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

    private let hour0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let hour1 = Date(timeIntervalSince1970: 1_700_003_600)
    private let hour2 = Date(timeIntervalSince1970: 1_700_007_200)

    @Test("a standing unseen failure wears the dot and is named")
    func unseenFailureDots() {
        let model = makeModel()
        model.configuration.runs = [.failed, .completedWithErrors, .cancelled].map {
            record($0, finishedAt: hour1)
        }

        #expect(model.showsProblemDot(for: planID))
        #expect(model.currentProblem(for: planID)?.outcome == .failed)
    }

    @Test("opening the plan clears the dot but the failure stays named")
    func seenFailureKeepsNamingItself() {
        let model = makeModel()
        model.configuration.runs = [record(.failed, finishedAt: hour1)]

        model.markProblemSeen(planID: planID)

        #expect(!model.showsProblemDot(for: planID))
        #expect(model.currentProblem(for: planID) != nil)
    }

    @Test("a later successful run heals the dot even unseen")
    func successHeals() {
        let model = makeModel()
        model.configuration.runs = [
            record(.succeeded, finishedAt: hour2),
            record(.failed, finishedAt: hour1),
        ]

        #expect(!model.showsProblemDot(for: planID))
        #expect(model.currentProblem(for: planID) == nil)
    }

    @Test("a success older than the failure does not heal it")
    func olderSuccessDoesNotHeal() {
        let model = makeModel()
        model.configuration.runs = [
            record(.failed, finishedAt: hour2),
            record(.succeeded, finishedAt: hour1),
        ]

        #expect(model.showsProblemDot(for: planID))
        #expect(model.currentProblem(for: planID)?.outcome == .failed)
    }

    @Test("a newer failure after a seen stamp dots again")
    func refailureDotsAgain() {
        let model = makeModel()
        // The stamp is "now", so the first failure must predate it and the
        // second must land after it — real events always do, being stamped
        // by the same clock as the mark.
        model.configuration.runs = [record(.failed, finishedAt: .now.addingTimeInterval(-3_600))]
        model.markProblemSeen(planID: planID)
        #expect(!model.showsProblemDot(for: planID))

        model.configuration.runs.insert(record(.failed, finishedAt: .now), at: 0)

        #expect(model.showsProblemDot(for: planID))
    }

    @Test("cancelled is not a problem")
    func cancelledIsQuiet() {
        let model = makeModel()
        model.configuration.runs = [record(.cancelled, finishedAt: hour1)]

        #expect(!model.showsProblemDot(for: planID))
        #expect(model.currentProblem(for: planID) == nil)
    }

    @Test("another plan's failure does not dot this plan")
    func plansDoNotLeak() {
        let model = makeModel()
        model.configuration.runs = [record(.failed, finishedAt: hour1, planID: otherPlanID)]

        #expect(!model.showsProblemDot(for: planID))
        #expect(model.showsProblemDot(for: otherPlanID))
    }

    @Test("marking seen writes through the store and survives a reload")
    func stampsRoundTrip() {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let model = makeModel()
        model.configuration.runs = [record(.failed, finishedAt: hour1)]
        model.markProblemSeen(planID: planID)

        #expect(ProblemDotsStore.load(from: defaults)[planID] != nil)

        let reloaded = AppModel(
            store: model.store,
            secrets: .inMemory(),
            defaults: defaults
        )
        #expect(reloaded.problemsSeenAt[planID] != nil)
        #expect(!reloaded.showsProblemDot(for: planID))
    }

    @Test("deleting a plan forgets its stamp")
    func deletionForgetsStamp() {
        let model = makeModel()
        var plan = BackupPlan()
        plan.id = planID
        model.configuration.plans = [plan]
        model.configuration.runs = [record(.failed, finishedAt: hour1)]
        model.markProblemSeen(planID: planID)

        model.deletePlan(id: planID)

        #expect(model.problemsSeenAt[planID] == nil)
    }
}
