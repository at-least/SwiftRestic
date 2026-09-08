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

    /// Pins the whole sentence: the injected formatter removes the only
    /// unpinned part (the relative-date suffix, which has its own pins).
    private static func ago(_ date: Date) -> String { "2 hours ago" }

    @Test("a clean or empty history has no problem line")
    func noProblemWhenClean() {
        #expect(MenuBarStatus.problemLine(runs: []) == nil)

        var succeeded = RunRecord(planName: "Nightly")
        succeeded.outcome = .succeeded
        #expect(MenuBarStatus.problemLine(runs: [succeeded]) == nil)

        // Cancelled is not a problem: the user asked for it.
        var cancelled = RunRecord(planName: "Nightly")
        cancelled.outcome = .cancelled
        #expect(MenuBarStatus.problemLine(runs: [cancelled]) == nil)
    }

    @Test("a recent failure and a recent warning both lead, newest first")
    func recentProblemsSurface() {
        var failed = RunRecord(planName: "Documents to NAS")
        failed.outcome = .failed
        failed.startedAt = .now.addingTimeInterval(-3_600)
        failed.finishedAt = failed.startedAt.addingTimeInterval(600)

        var warned = RunRecord(planName: "Photos")
        warned.outcome = .completedWithErrors
        warned.startedAt = .now.addingTimeInterval(-600)
        warned.finishedAt = warned.startedAt

        #expect(
            MenuBarStatus.problemLine(runs: [failed], relative: Self.ago)
                == "Documents to NAS failed 2 hours ago"
        )
        #expect(
            MenuBarStatus.problemLine(runs: [warned], relative: Self.ago)
                == "Photos finished with errors 2 hours ago"
        )
        // Two problems: the one that finished later leads, whatever the
        // storage order.
        #expect(MenuBarStatus.problemLine(runs: [failed, warned])?.hasPrefix("Photos ") == true)
        #expect(MenuBarStatus.problemLine(runs: [warned, failed])?.hasPrefix("Photos ") == true)
    }

    @Test("recency counts from when the run finished, not when it started")
    func finishedAtIsTheNewsClock() {
        // An overnight backup that failed at dawn against an afternoon failure:
        // the dawn one is the newest news despite starting first.
        var overnight = RunRecord(planName: "Nightly")
        overnight.outcome = .failed
        overnight.startedAt = .now.addingTimeInterval(-10 * 3_600)
        overnight.finishedAt = .now.addingTimeInterval(-1 * 3_600)

        var afternoon = RunRecord(planName: "Daytime")
        afternoon.outcome = .failed
        afternoon.startedAt = .now.addingTimeInterval(-5 * 3_600)
        afternoon.finishedAt = .now.addingTimeInterval(-4.5 * 3_600)

        #expect(
            MenuBarStatus.problemLine(runs: [overnight, afternoon])?.hasPrefix("Nightly ") == true
        )

        // A run that started outside the window but finished inside it is
        // still news.
        #expect(MenuBarStatus.problemLine(runs: [overnight]) != nil)
    }

    @Test("a failure older than the dashboard's seven-day window is old news")
    func staleFailureStaysQuiet() {
        var stale = RunRecord(planName: "Old Plan")
        stale.outcome = .failed
        stale.startedAt = .now.addingTimeInterval(-9 * 86_400)
        stale.finishedAt = .now.addingTimeInterval(-8 * 86_400)
        #expect(MenuBarStatus.problemLine(runs: [stale]) == nil)

        // Just inside the window still counts.
        var fresh = RunRecord(planName: "New Plan")
        fresh.outcome = .failed
        fresh.startedAt = .now.addingTimeInterval(-7 * 86_400)
        fresh.finishedAt = .now.addingTimeInterval(-6 * 86_400)
        #expect(MenuBarStatus.problemLine(runs: [fresh]) != nil)
    }

    @Test("the subject names what ran: a plan, a restore's target, or a repository")
    func subjects() {
        func failedRun(kind: RunRecord.Kind, name: String) -> RunRecord {
            var record = RunRecord(kind: kind, planName: name)
            record.outcome = .failed
            record.startedAt = .now.addingTimeInterval(-60)
            record.finishedAt = record.startedAt
            return record
        }

        #expect(
            MenuBarStatus.problemLine(runs: [failedRun(kind: .check, name: "NAS")], relative: Self.ago)
                == "Check on NAS failed 2 hours ago"
        )
        #expect(
            MenuBarStatus.problemLine(runs: [failedRun(kind: .prune, name: "NAS")], relative: Self.ago)
                == "Prune on NAS failed 2 hours ago"
        )
        #expect(
            MenuBarStatus.problemLine(runs: [failedRun(kind: .restore, name: "Report.pdf")], relative: Self.ago)
                == "Restore of Report.pdf failed 2 hours ago"
        )
        #expect(
            MenuBarStatus.problemLine(runs: [failedRun(kind: .backup, name: "Nightly")], relative: Self.ago)
                == "Nightly failed 2 hours ago"
        )
    }
}
