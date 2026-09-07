import Foundation
import Testing

/// Walks the menu bar headline through its lifecycle, appending state one step
/// at a time the way a user's afternoon actually unfolds: idle → next run
/// announced → backup starts → phases tick over → finishes → idle again.
@Suite("Menu bar status")
struct MenuBarStatusTests {
    private func plan(name: String) -> BackupPlan {
        var plan = BackupPlan()
        plan.name = name
        plan.repositoryID = UUID()
        plan.sources = ["/tmp"]
        return plan
    }

    private func activity(
        phase: PlanActivity.Phase = .backingUp,
        fraction: Double = 0
    ) -> PlanActivity {
        var activity = PlanActivity()
        activity.phase = phase
        activity.progress.fraction = fraction
        return activity
    }

    @Test("idle with nothing configured says there is no schedule")
    func idleNoPlans() {
        let next = Date.now.addingTimeInterval(3600)
        #expect(MenuBarStatus.headline(activity: [:], nextRun: nil) == "No backups scheduled")

        guard let headline = MenuBarStatus.headline(
            activity: [:],
            nextRun: (plan(name: "Nightly"), next)
        ) else {
            Issue.record("idle state must have a headline")
            return
        }
        #expect(headline == "Next: Nightly \(Format.relative(next))")
    }

    @Test("a running plan replaces the headline with a progress line")
    func runningReplacesHeadline() {
        let nightly = plan(name: "Nightly")
        #expect(MenuBarStatus.headline(activity: [nightly.id: activity()], nextRun: nil) == nil)
        #expect(MenuBarStatus.runningLines(plans: [nightly], activity: [nightly.id: activity()]).map(\.text) == ["Nightly — 0%"])
    }

    @Test("phases tick over: phase names before restic streams, percentages after")
    func phasesAndPercent() {
        #expect(MenuBarStatus.progressText(nil) == "…")
        #expect(MenuBarStatus.progressText(activity(phase: .starting)) == "Starting…")
        #expect(MenuBarStatus.progressText(activity(phase: .backingUp, fraction: 0)) == "0%")
        #expect(MenuBarStatus.progressText(activity(phase: .backingUp, fraction: 0.418)) == "42%")
        #expect(MenuBarStatus.progressText(activity(phase: .backingUp, fraction: 1)) == "100%")
        // Retention and notification phases are named, never shown as a percent.
        #expect(MenuBarStatus.progressText(activity(phase: .applyingRetention, fraction: 1)) == "Applying retention")
        #expect(MenuBarStatus.progressText(activity(phase: .cancelling)) == "Cancelling…")
    }

    @Test("two plans running at once each get a line, in configuration order")
    func multipleRunningLines() {
        let first = plan(name: "First")
        let second = plan(name: "Second")
        let third = plan(name: "Idle")

        let lines = MenuBarStatus.runningLines(
            plans: [first, second, third],
            activity: [
                second.id: activity(fraction: 0.5),
                first.id: activity(phase: .applyingRetention),
            ]
        )
        #expect(lines.map(\.text) == ["First — Applying retention", "Second — 50%"])
        #expect(lines.map(\.planID) == [first.id, second.id])
    }

    @Test("finishing returns to the idle headline")
    func finishedReturnsToIdle() {
        let nightly = plan(name: "Nightly")
        let next = Date.now.addingTimeInterval(86_400)
        let whileRunning = MenuBarStatus.headline(activity: [nightly.id: activity()], nextRun: nil)
        #expect(whileRunning == nil)
        // Back to the next-run line — not the running line and not the
        // empty-state text. (The relative-date suffix has its own pins; the
        // prefix is what distinguishes this state from its neighbours.)
        let restored = MenuBarStatus.headline(activity: [:], nextRun: (plan: nightly, date: next))
        #expect(restored?.hasPrefix("Next: Nightly ") == true)
    }
}
