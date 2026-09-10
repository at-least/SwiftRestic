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

    @Test("with no repository configured, the headline sends the user to add one")
    func noRepositoriesHeadline() {
        #expect(MenuBarStatus.headline(activity: [:], hasNoRepositories: true, nextRun: nil) == "No repository set up yet")
        // Running work still holds the headline back even with no repository —
        // the same rule as every other running state.
        let nightly = plan(name: "Nightly")
        #expect(
            MenuBarStatus.headline(
                activity: [nightly.id: activity()],
                hasNoRepositories: true,
                nextRun: nil
            ) == nil
        )
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
        #expect(lines.map(\.id) == [first.id.uuidString, second.id.uuidString])
    }

    @Test("restores, upkeep and console work read as running and get their own lines")
    func nonPlanWorkIsVisible() {
        var progress = OperationProgress()
        progress.fraction = 0.25

        // The restore is one line with its own stable identity.
        let restore = MenuBarStatus.restoreLine(progress: progress)
        #expect(restore?.text == "Restoring — 25%")
        #expect(restore?.id == "restore")
        #expect(MenuBarStatus.restoreLine(progress: nil) == nil)

        // Upkeep names the repository and the task, never "NAS failed"-style
        // ambiguity — a check on the NAS is not the NAS failing.
        let idle = Repository()
        let upkeep = MenuBarStatus.maintenanceLines(
            repositories: [idle],
            maintenance: [UUID(): MaintenanceActivity(task: .prune)]
        )
        #expect(upkeep.isEmpty, "a repository with no maintenance in flight gets no line")

        let repository = Repository()
        let busy = MenuBarStatus.maintenanceLines(
            repositories: [repository],
            maintenance: [repository.id: MaintenanceActivity(task: .check)]
        )
        #expect(busy.map(\.text) == ["\(repository.name) — check running"])

        let console = MenuBarStatus.consoleLine(isRunning: true)
        #expect(console?.id == "console")
        #expect(MenuBarStatus.consoleLine(isRunning: false) == nil)
    }

    @Test("upkeep, restores and console work hold the idle headline back, like a backup does")
    func nonPlanWorkHoldsTheHeadline() {
        let next = Date.now.addingTimeInterval(3600)
        #expect(MenuBarStatus.headline(activity: [:], nextRun: (plan(name: "Nightly"), next)) != nil)
        #expect(MenuBarStatus.headline(activity: [:], isRestoring: true, nextRun: (plan(name: "Nightly"), next)) == nil)
        #expect(MenuBarStatus.headline(activity: [:], isConsoleRunning: true, nextRun: (plan(name: "Nightly"), next)) == nil)
        #expect(
            MenuBarStatus.headline(
                activity: [:],
                maintenance: [UUID(): MaintenanceActivity(task: .prune)],
                nextRun: (plan(name: "Nightly"), next)
            ) == nil
        )
    }

    @Test("the icon runs while anything runs, warns on a recent problem, otherwise idles or asks for setup")
    func iconStates() {
        let repository = Repository()
        let busyActivity = [UUID(): activity()]

        func state(
            activity: [UUID: PlanActivity] = [:],
            maintenance: [UUID: MaintenanceActivity] = [:],
            isRestoring: Bool = false,
            isConsoleRunning: Bool = false,
            hasNoRepositories: Bool = false,
            runs: [RunRecord] = []
        ) -> MenuBarStatus.IconState {
            MenuBarStatus.iconState(
                activity: activity,
                maintenance: maintenance,
                isRestoring: isRestoring,
                isConsoleRunning: isConsoleRunning,
                hasNoRepositories: hasNoRepositories,
                runs: runs
            )
        }

        #expect(state() == .idle)
        #expect(state(hasNoRepositories: true) == .unconfigured)
        #expect(state(activity: busyActivity) == .running)
        #expect(state(maintenance: [repository.id: MaintenanceActivity(task: .check)]) == .running)
        #expect(state(isRestoring: true) == .running)
        #expect(state(isConsoleRunning: true) == .running)
        // Running beats even having no repository — the icon should never
        // claim setup is needed while work it can't explain is in flight.
        #expect(state(activity: busyActivity, hasNoRepositories: true) == .running)

        // A recent failure is the warning face — but only when nothing runs;
        // the menu's problem line carries the news meanwhile.
        var failed = RunRecord(planName: "Nightly")
        failed.outcome = .failed
        failed.startedAt = .now.addingTimeInterval(-60)
        failed.finishedAt = failed.startedAt
        #expect(state(runs: [failed]) == .problem)
        #expect(state(activity: busyActivity, runs: [failed]) == .running)

        // A seven-day-stale failure is old news, same window as problemLine.
        var stale = RunRecord(planName: "Old")
        stale.outcome = .failed
        stale.startedAt = .now.addingTimeInterval(-9 * 86_400)
        stale.finishedAt = stale.startedAt
        #expect(state(runs: [stale]) == .idle)
    }

    @Test("idle and running wear the brand mark; unconfigured and problem wear a bare symbol")
    func iconSymbolsAndVoice() {
        #expect(MenuBarStatus.glyph(for: .unconfigured) == .symbol("questionmark"))
        #expect(MenuBarStatus.glyph(for: .idle) == .logo)
        #expect(MenuBarStatus.glyph(for: .running) == .animatedLogo)
        #expect(MenuBarStatus.glyph(for: .problem) == .symbol("exclamationmark"))

        #expect(MenuBarStatus.accessibilityDescription(for: .unconfigured).contains("no repository"))
        #expect(MenuBarStatus.accessibilityDescription(for: .running).contains("work in progress"))
        #expect(MenuBarStatus.accessibilityDescription(for: .problem).contains("problem"))
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
        #expect(MenuBarStatus.problemLine(runs: [], hasNoRepositories: false) == nil)

        var succeeded = RunRecord(planName: "Nightly")
        succeeded.outcome = .succeeded
        #expect(MenuBarStatus.problemLine(runs: [succeeded], hasNoRepositories: false) == nil)

        // Cancelled is not a problem: the user asked for it.
        var cancelled = RunRecord(planName: "Nightly")
        cancelled.outcome = .cancelled
        #expect(MenuBarStatus.problemLine(runs: [cancelled], hasNoRepositories: false) == nil)
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
            MenuBarStatus.problemLine(runs: [failed], hasNoRepositories: false, relative: Self.ago)
                == "Documents to NAS failed 2 hours ago"
        )
        #expect(
            MenuBarStatus.problemLine(runs: [warned], hasNoRepositories: false, relative: Self.ago)
                == "Photos finished with errors 2 hours ago"
        )
        // Two problems: the one that finished later leads, whatever the
        // storage order.
        #expect(MenuBarStatus.problemLine(runs: [failed, warned], hasNoRepositories: false)?.hasPrefix("Photos ") == true)
        #expect(MenuBarStatus.problemLine(runs: [warned, failed], hasNoRepositories: false)?.hasPrefix("Photos ") == true)
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
            MenuBarStatus.problemLine(runs: [overnight, afternoon], hasNoRepositories: false)?.hasPrefix("Nightly ") == true
        )

        // A run that started outside the window but finished inside it is
        // still news.
        #expect(MenuBarStatus.problemLine(runs: [overnight], hasNoRepositories: false) != nil)
    }

    @Test("a failure older than the dashboard's seven-day window is old news")
    func staleFailureStaysQuiet() {
        var stale = RunRecord(planName: "Old Plan")
        stale.outcome = .failed
        stale.startedAt = .now.addingTimeInterval(-9 * 86_400)
        stale.finishedAt = .now.addingTimeInterval(-8 * 86_400)
        #expect(MenuBarStatus.problemLine(runs: [stale], hasNoRepositories: false) == nil)

        // Just inside the window still counts.
        var fresh = RunRecord(planName: "New Plan")
        fresh.outcome = .failed
        fresh.startedAt = .now.addingTimeInterval(-7 * 86_400)
        fresh.finishedAt = .now.addingTimeInterval(-6 * 86_400)
        #expect(MenuBarStatus.problemLine(runs: [fresh], hasNoRepositories: false) != nil)
    }

    @Test("the problem line yields when no repository is configured")
    func problemLineYieldsToUnconfigured() {
        var failed = RunRecord(planName: "Nightly")
        failed.outcome = .failed
        failed.startedAt = .now.addingTimeInterval(-60)
        failed.finishedAt = failed.startedAt

        // Runs outlive the repository that produced them — removing it keeps
        // the history — so the line must yield explicitly, or a `?` icon's
        // menu would open leading with "Nightly failed 2 hours ago".
        #expect(MenuBarStatus.problemLine(runs: [failed], hasNoRepositories: true) == nil)
        #expect(MenuBarStatus.problemLine(runs: [failed], hasNoRepositories: false) != nil)

        // The icon's own ordering is unchanged: unconfigured still beats
        // problem, so both channels now answer setup the same way.
        #expect(
            MenuBarStatus.iconState(
                activity: [:],
                maintenance: [:],
                isRestoring: false,
                isConsoleRunning: false,
                hasNoRepositories: true,
                runs: [failed]
            ) == .unconfigured
        )
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
            MenuBarStatus.problemLine(runs: [failedRun(kind: .check, name: "NAS")], hasNoRepositories: false, relative: Self.ago)
                == "Check on NAS failed 2 hours ago"
        )
        #expect(
            MenuBarStatus.problemLine(runs: [failedRun(kind: .prune, name: "NAS")], hasNoRepositories: false, relative: Self.ago)
                == "Prune on NAS failed 2 hours ago"
        )
        #expect(
            MenuBarStatus.problemLine(runs: [failedRun(kind: .restore, name: "Report.pdf")], hasNoRepositories: false, relative: Self.ago)
                == "Restore of Report.pdf failed 2 hours ago"
        )
        #expect(
            MenuBarStatus.problemLine(runs: [failedRun(kind: .backup, name: "Nightly")], hasNoRepositories: false, relative: Self.ago)
                == "Nightly failed 2 hours ago"
        )
    }
}
