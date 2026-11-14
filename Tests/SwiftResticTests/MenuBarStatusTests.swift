import Foundation
import Testing

@Suite("Menu bar status")
struct MenuBarStatusTests {
    private func plan(name: String) -> BackupPlan {
        namedPlan(name, repositoryID: UUID())
    }

    private func repository(named name: String) -> Repository {
        namedRepository(name)
    }

    private func activity(phase: PlanActivity.Phase = .backingUp) -> PlanActivity {
        var activity = PlanActivity()
        activity.phase = phase
        return activity
    }

    private func progress(fraction: Double) -> OperationProgress {
        var value = OperationProgress()
        value.fraction = fraction
        return value
    }

    @Test("each repository's group carries its Status line in the card's words, only once its listing has loaded")
    func protectionLines() {
        let nas = repository(named: "Home NAS")
        let ssd = repository(named: "Travel SSD")
        var onNAS = plan(name: "Code")
        onNAS.repositoryID = nas.id
        var onSSD = plan(name: "Photos")
        onSSD.repositoryID = ssd.id
        let summary = UpToDateSummary(text: "2 of 2 plans up to date · Last backup 1 hour ago", showsResume: false)
        let groups = MenuBarStatus.planGroups(
            plans: [onNAS, onSSD], repositories: [nas, ssd], activity: [:], isResticDamaged: false,
            protection: { id in id == nas.id ? summary : nil }
        )
        // In a submenu the title already names the repository.
        #expect(groups.map(\.protection) == ["2 of 2 plans up to date · Last backup 1 hour ago", nil])
        #expect(groups[0].labeledStatus == "Home NAS — 2 of 2 plans up to date · Last backup 1 hour ago")
        #expect(groups[1].labeledStatus == nil)
    }

    @Test("idle with nothing configured says there is no schedule")
    func idleNoPlans() {
        let next = Date.now.addingTimeInterval(3600)
        #expect(MenuBarStatus.headline(activity: [:], plans: [], repositories: [], nextRun: nil) == "No backups scheduled")

        guard let headline = MenuBarStatus.headline(
            activity: [:],
            plans: [], repositories: [],
            nextRun: (plan(name: "Nightly"), next)
        ) else {
            Issue.record("idle state must have a headline")
            return
        }
        #expect(headline == "Next: Nightly — \(Format.tileTimestamp(next))")
    }

    @Test("the idle headline names the plan with its repository")
    func headlineNamesTheRepository() {
        let home = repository(named: "Home Disk")
        var nightly = plan(name: "Nightly")
        nightly.repositoryID = home.id
        let next = Date.now.addingTimeInterval(3600)

        // Two repositories can hold same-named plans; the headline says
        // whose next run it is announcing.
        #expect(
            MenuBarStatus.headline(
                activity: [:],
                plans: [], repositories: [home],
                nextRun: (nightly, next)
            ) == "Next: Nightly (Home Disk) — \(Format.tileTimestamp(next))"
        )
        var twin = plan(name: "Home Disk")
        twin.repositoryID = home.id
        #expect(
            MenuBarStatus.headline(activity: [:], plans: [], repositories: [home], nextRun: (twin, next))
                == "Next: Home Disk — \(Format.tileTimestamp(next))"
        )
        #expect(
            MenuBarStatus.headline(activity: [:], plans: [], repositories: [], nextRun: (nightly, next))
                == "Next: Nightly — \(Format.tileTimestamp(next))"
        )
    }

    @Test("with no repository configured, the headline sends the user to add one")
    func noRepositoriesHeadline() {
        #expect(
            MenuBarStatus.headline(activity: [:], hasNoRepositories: true, plans: [], repositories: [], nextRun: nil)
                == "No backup location set"
        )
        // Running work holds the headline back even with no repository.
        let nightly = plan(name: "Nightly")
        #expect(
            MenuBarStatus.headline(
                activity: [nightly.id: activity()],
                hasNoRepositories: true,
                plans: [], repositories: [],
                nextRun: nil
            ) == nil
        )
    }

    @Test("a running plan replaces the headline with a progress line")
    func runningReplacesHeadline() {
        let nightly = plan(name: "Nightly")
        #expect(MenuBarStatus.headline(activity: [nightly.id: activity()], plans: [], repositories: [], nextRun: nil) == nil)
        #expect(
            MenuBarStatus.runningLines(
                plans: [nightly],
                repositories: [],
                activity: [nightly.id: activity()],
                progress: [nightly.id: progress(fraction: 0)]
            ).map(\.text) == ["Nightly — 0%"]
        )
    }

    @Test("a running line names its plan's repository, like the headline")
    func runningLinesNameTheRepository() {
        let home = repository(named: "Home Disk")
        let offsite = repository(named: "Offsite")
        func groupedPlan(_ name: String, on repository: Repository) -> BackupPlan {
            var value = plan(name: name)
            value.repositoryID = repository.id
            return value
        }

        // Two same-named plans running at once stay distinguishable — the
        // ambiguity the tray's grouping exists to end.
        let documents = groupedPlan("Documents", on: home)
        let twin = groupedPlan("Documents", on: offsite)
        let lines = MenuBarStatus.runningLines(
            plans: [documents, twin],
            repositories: [home, offsite],
            activity: [documents.id: activity(), twin.id: activity()],
            progress: [documents.id: progress(fraction: 0.42), twin.id: progress(fraction: 0.1)]
        )
        #expect(lines.map(\.text) == ["Documents (Home Disk) — 42%", "Documents (Offsite) — 10%"])
        #expect(lines.map(\.id) == [documents.id.uuidString, twin.id.uuidString])

        let orphan = plan(name: "Nightly")
        #expect(
            MenuBarStatus.runningLines(
                plans: [orphan],
                repositories: [],
                activity: [orphan.id: activity()],
                progress: [:]
            ).map(\.text) == ["Nightly — 0%"]
        )
    }

    @Test("phases tick over: phase names before restic streams, percentages after")
    func phasesAndPercent() {
        #expect(MenuBarStatus.progressText(activity: nil, progress: nil) == "…")
        #expect(MenuBarStatus.progressText(activity: activity(phase: .starting), progress: nil) == "Starting…")
        #expect(MenuBarStatus.progressText(activity: activity(phase: .backingUp), progress: progress(fraction: 0)) == "0%")
        #expect(MenuBarStatus.progressText(activity: activity(phase: .backingUp), progress: progress(fraction: 0.418)) == "42%")
        #expect(MenuBarStatus.progressText(activity: activity(phase: .backingUp), progress: progress(fraction: 1)) == "100%")
        #expect(MenuBarStatus.progressText(activity: activity(phase: .applyingRetention), progress: progress(fraction: 1)) == "Removing old backups…")
        #expect(MenuBarStatus.progressText(activity: activity(phase: .cancelling), progress: nil) == "Stopping…")
    }

    @Test("two plans running at once each get a line, in configuration order")
    func multipleRunningLines() {
        let first = plan(name: "First")
        let second = plan(name: "Second")
        let third = plan(name: "Idle")

        let lines = MenuBarStatus.runningLines(
            plans: [first, second, third],
            repositories: [],
            activity: [
                second.id: activity(),
                first.id: activity(phase: .applyingRetention),
            ],
            progress: [second.id: progress(fraction: 0.5)]
        )
        #expect(lines.map(\.text) == ["First — Removing old backups…", "Second — 50%"])
        #expect(lines.map(\.id) == [first.id.uuidString, second.id.uuidString])
    }

    @Test("restores and upkeep get their own running lines")
    func nonPlanWorkIsVisible() {
        var progress = OperationProgress()
        progress.fraction = 0.25

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
        #expect(busy.map(\.text) == ["\(repository.label(among: [repository])) — Verifying…"])
        let freeing = MenuBarStatus.maintenanceLines(
            repositories: [repository],
            maintenance: [repository.id: MaintenanceActivity(task: .prune)]
        )
        #expect(freeing.map(\.text) == ["\(repository.label(among: [repository])) — Freeing space…"])
    }

    @Test("upkeep and restores hold the idle headline back, like a backup does")
    func nonPlanWorkHoldsTheHeadline() {
        let next = Date.now.addingTimeInterval(3600)
        #expect(MenuBarStatus.headline(activity: [:], plans: [], repositories: [], nextRun: (plan(name: "Nightly"), next)) != nil)
        #expect(
            MenuBarStatus.headline(activity: [:], isRestoring: true, plans: [], repositories: [], nextRun: (plan(name: "Nightly"), next))
                == nil
        )
        #expect(
            MenuBarStatus.headline(
                activity: [:],
                maintenance: [UUID(): MaintenanceActivity(task: .prune)],
                plans: [], repositories: [],
                nextRun: (plan(name: "Nightly"), next)
            ) == nil
        )
    }

    @Test("the icon warns on a recent problem, even under work, runs while anything runs, otherwise idles or asks for setup")
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

        var failed = RunRecord(planName: "Nightly")
        failed.outcome = .failed
        failed.startedAt = .now.addingTimeInterval(-60)
        failed.finishedAt = failed.startedAt
        #expect(state(runs: [failed]) == .problem)
        #expect(state(activity: busyActivity, runs: [failed]) == .problem)

        // A seven-day-stale failure is old news, same window as problemLine.
        var stale = RunRecord(planName: "Old")
        stale.outcome = .failed
        stale.startedAt = .now.addingTimeInterval(-9 * 86_400)
        stale.finishedAt = stale.startedAt
        #expect(state(runs: [stale]) == .idle)
    }

    @Test("idle, running and an empty install wear the brand mark; a problem stands the exclamation mark in it")
    func iconSymbolsAndVoice() {
        // The exclamation mark is a problem's sign alone — Time Machine's
        // grammar — and an empty install wears the plain mark: a mark asking
        // for attention over a setup that has not begun would read as a
        // failure that has not happened. The menu's first line says which.
        #expect(MenuBarStatus.glyph(for: .unconfigured) == .logo)
        #expect(MenuBarStatus.glyph(for: .idle) == .logo)
        #expect(MenuBarStatus.glyph(for: .running) == .animatedLogo)
        #expect(MenuBarStatus.glyph(for: .problem) == .attentionLogo)

        // The plain mark for two states means VoiceOver carries the
        // distinction between them.
        #expect(MenuBarStatus.accessibilityDescription(for: .unconfigured).contains("no backup location"))
        #expect(MenuBarStatus.accessibilityDescription(for: .running).contains("work in progress"))
        #expect(MenuBarStatus.accessibilityDescription(for: .problem).contains("attention"))
        #expect(MenuBarStatus.accessibilityDescription(for: .unconfigured)
            != MenuBarStatus.accessibilityDescription(for: .problem))
    }

    @Test("finishing returns to the idle headline")
    func finishedReturnsToIdle() {
        let nightly = plan(name: "Nightly")
        let next = Date.now.addingTimeInterval(86_400)
        let whileRunning = MenuBarStatus.headline(activity: [nightly.id: activity()], plans: [], repositories: [], nextRun: nil)
        #expect(whileRunning == nil)
        // The relative-date suffix has its own pins; the prefix is what tells
        // this state from its neighbours.
        let restored = MenuBarStatus.headline(activity: [:], plans: [], repositories: [], nextRun: (plan: nightly, date: next))
        #expect(restored?.hasPrefix("Next: Nightly — ") == true)
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

    @Test("a repository's tray submenu carries its plans' news in the sidebar's words, and nothing for a quiet or running plan")
    func submenuNewsLines() {
        let now = Date.now
        var home = Repository()
        home.localPath = "/Users/someone/Home NAS"
        func plan(_ name: String) -> BackupPlan {
            var plan = BackupPlan()
            plan.repositoryID = home.id
            plan.path = "/Users/someone/\(name)"
            plan.schedule.frequency = .weekly
            return plan
        }
        let code = plan("Code")
        let photos = plan("Photos")
        let quiet = plan("Quiet")
        var failed = RunRecord(planName: "Code")
        failed.planID = code.id
        failed.outcome = .failed
        failed.finishedAt = now.addingTimeInterval(-7_200)

        let plans = [code, photos, quiet]
        #expect(MenuBarStatus.newsLines(for: code, among: plans, activity: nil, problem: failed, now: now, relative: Self.ago)
            == ["Code: Failed — 2 hours ago"])
        #expect(MenuBarStatus.newsLines(for: photos, among: plans, activity: nil, problem: nil, now: now, relative: Self.ago).isEmpty)
        #expect(MenuBarStatus.newsLines(for: photos, among: plans, activity: nil, problem: failed, now: now, relative: Self.ago)
            == ["Photos: Failed — 2 hours ago"])
        #expect(MenuBarStatus.newsLines(for: quiet, among: plans, activity: nil, problem: nil, now: now, relative: Self.ago).isEmpty)
        #expect(MenuBarStatus.newsLines(for: code, among: plans, activity: PlanActivity(phase: .backingUp), problem: failed, now: now).isEmpty)

        let groups = MenuBarStatus.planGroups(
            plans: [code, photos, quiet], repositories: [home], activity: [:], isResticDamaged: false,
            problem: { $0 == code.id ? failed : nil }, now: now, relative: Self.ago
        )
        #expect(groups.first?.newsLines == ["Code: Failed — 2 hours ago"])
    }

    @Test("Back Up Now waits while its repository is locked exclusively, and says why")
    func backUpWaitsForAnExclusiveLock() {
        var repository = Repository()
        repository.localPath = "/Users/someone/Home NAS"
        var plan = BackupPlan()
        plan.repositoryID = repository.id
        plan.path = "/Users/someone/Documents"
        let reason = "“Home NAS” is freeing space — backups wait until it finishes."
        let locked = MenuBarStatus.planRows(
            plans: [plan], activity: [:], isResticDamaged: false,
            lockedRepositories: [repository.id: reason]
        )
        #expect(locked.first?.action == .backUp)
        #expect(locked.first?.isEnabled == false)
        #expect(locked.first?.disabledReason == reason)
        let free = MenuBarStatus.planRows(plans: [plan], activity: [:], isResticDamaged: false)
        #expect(free.first?.isEnabled == true)
        #expect(free.first?.disabledReason == nil)
    }

    @Test("while restic is missing the tray says the backups are held, promises no next run, and each grey row says why")
    func resticMissing() {
        var plan = BackupPlan()
        plan.repositoryID = UUID()
        plan.path = "/Users/someone/Documents"
        let next = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(MenuBarStatus.headline(
            activity: [:], isResticDamaged: true, plans: [], repositories: [], nextRun: (plan, next)
        ) == nil)
        #expect(MenuBarStatus.headline(activity: [:], plans: [], repositories: [], nextRun: (plan, next)) != nil)

        let rows = MenuBarStatus.planRows(
            plans: [plan], activity: [:], isResticDamaged: true,
            lockedRepositories: [plan.repositoryID!: "“Home NAS” is freeing space — backups wait until it finishes."]
        )
        #expect(rows.first?.isEnabled == false)
        // The cause no wait cures leads.
        #expect(rows.first?.disabledReason == "SwiftRestic is damaged. Install it again.")
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
                == "Photos: some files skipped 2 hours ago"
        )
        // Two problems: the one that finished later leads, whatever the
        // storage order.
        #expect(MenuBarStatus.problemLine(runs: [failed, warned], hasNoRepositories: false)?.hasPrefix("Photos:") == true)
        #expect(MenuBarStatus.problemLine(runs: [warned, failed], hasNoRepositories: false)?.hasPrefix("Photos:") == true)
    }

    @Test("a failed retention run is named by what it did, then the plan")
    func retentionProblemLine() {
        var removal = RunRecord(kind: .forget, planName: "Documents")
        removal.outcome = .failed
        removal.startedAt = .now.addingTimeInterval(-600)
        removal.finishedAt = removal.startedAt
        #expect(
            MenuBarStatus.problemLine(runs: [removal], hasNoRepositories: false, relative: Self.ago)
                == "Old backup removal on Documents failed 2 hours ago"
        )
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
        var long = RunRecord(planName: "Long")
        long.outcome = .failed
        long.startedAt = .now.addingTimeInterval(-8 * 86_400)
        long.finishedAt = .now.addingTimeInterval(-1 * 3_600)
        #expect(MenuBarStatus.problemLine(runs: [long], hasNoRepositories: false) != nil)
    }

    @Test("a failure older than the dashboard's seven-day window is old news")
    func staleFailureStaysQuiet() {
        var stale = RunRecord(planName: "Old Plan")
        stale.outcome = .failed
        stale.startedAt = .now.addingTimeInterval(-9 * 86_400)
        stale.finishedAt = .now.addingTimeInterval(-8 * 86_400)
        #expect(MenuBarStatus.problemLine(runs: [stale], hasNoRepositories: false) == nil)

        var fresh = RunRecord(planName: "New Plan")
        fresh.outcome = .failed
        fresh.startedAt = .now.addingTimeInterval(-7 * 86_400)
        fresh.finishedAt = .now.addingTimeInterval(-6 * 86_400)
        #expect(MenuBarStatus.problemLine(runs: [fresh], hasNoRepositories: false) != nil)
    }

    private func run(
        _ outcome: RunRecord.Outcome,
        minutesAgo: Double,
        planID: UUID? = nil,
        kind: RunRecord.Kind = .backup,
        name: String = "Nightly"
    ) -> RunRecord {
        var record = RunRecord(planName: name)
        record.kind = kind
        record.planID = planID
        record.outcome = outcome
        record.finishedAt = .now.addingTimeInterval(-minutesAgo * 60)
        record.startedAt = record.finishedAt
        return record
    }

    private func face(_ runs: [RunRecord]) -> MenuBarStatus.IconState {
        MenuBarStatus.iconState(
            activity: [:],
            maintenance: [:],
            isRestoring: false,
            isConsoleRunning: false,
            hasNoRepositories: false,
            runs: runs
        )
    }

    @Test("a later successful backup of the same plan clears the face's dot and the problem line")
    func laterSuccessHeals() {
        let planID = UUID()
        for outcome in [RunRecord.Outcome.failed, .completedWithErrors] {
            let problem = run(outcome, minutesAgo: 60, planID: planID)
            #expect(face([problem]) == .problem)

            let runs = [problem, run(.succeeded, minutesAgo: 10, planID: planID)]
            #expect(MenuBarStatus.problemLine(runs: runs, hasNoRepositories: false) == nil)
            #expect(face(runs) == .idle)
        }
    }

    @Test("only a newer successful backup of that same plan heals it")
    func whatDoesNotHeal() {
        let planID = UUID()
        let failed = run(.failed, minutesAgo: 60, planID: planID)
        // Another plan's success, a success that came before the failure, a
        // cancelled run, and a successful forget (Apply Retention Now
        // records it under the plan's ID) — the sidebar's rule exactly.
        let leaves: [RunRecord] = [
            run(.succeeded, minutesAgo: 10, planID: UUID()),
            run(.succeeded, minutesAgo: 90, planID: planID),
            run(.cancelled, minutesAgo: 10, planID: planID),
            run(.succeeded, minutesAgo: 10, planID: planID, kind: .forget),
        ]
        for other in leaves {
            #expect(face([failed, other]) == .problem)
            #expect(MenuBarStatus.problemLine(runs: [failed, other], hasNoRepositories: false)?.hasPrefix("Nightly ") == true)
        }
    }

    @Test("a check, prune, retention or restore problem keeps the seven-day window whatever succeeds after it")
    func otherKindsKeepTheWindow() {
        let planID = UUID()
        for kind in [RunRecord.Kind.check, .prune, .forget, .restore] {
            let failed = run(.failed, minutesAgo: 60, planID: kind == .forget ? planID : nil, kind: kind)
            let runs = [
                failed,
                run(.succeeded, minutesAgo: 10, planID: planID),
                run(.succeeded, minutesAgo: 10, planID: kind == .forget ? planID : nil, kind: kind),
            ]
            #expect(face(runs) == .problem)
        }
    }

    @Test("a healed failure hands the line to the newest problem still standing")
    func lineFallsBackToStandingProblem() {
        let documents = UUID()
        let photos = UUID()
        let runs = [
            run(.failed, minutesAgo: 120, planID: documents, name: "Documents"),
            run(.failed, minutesAgo: 60, planID: photos, name: "Photos"),
            run(.succeeded, minutesAgo: 10, planID: photos, name: "Photos"),
        ]
        #expect(MenuBarStatus.problemLine(runs: runs, hasNoRepositories: false)?.hasPrefix("Documents ") == true)
        #expect(face(runs) == .problem)
    }

    @Test("the Activity badge still counts a healed failure for the week")
    func historyCountsHealedProblems() {
        let planID = UUID()
        let runs = [run(.failed, minutesAgo: 60, planID: planID), run(.succeeded, minutesAgo: 10, planID: planID)]
        let since = OverviewMetrics.problemWindowStart(from: .now)
        #expect(OverviewMetrics.problems(in: runs, since: since).count == 1)
        #expect(face(runs) == .idle)
    }

    @Test("the problem line yields when no repository is configured")
    func problemLineYieldsToUnconfigured() {
        var failed = RunRecord(planName: "Nightly")
        failed.outcome = .failed
        failed.startedAt = .now.addingTimeInterval(-60)
        failed.finishedAt = failed.startedAt

        // Runs outlive the repository that produced them — removing it keeps
        // the history — so the line must yield explicitly, or the menu of an
        // app with no repository would open leading with "Nightly failed 2
        // hours ago".
        #expect(MenuBarStatus.problemLine(runs: [failed], hasNoRepositories: true) == nil)
        #expect(MenuBarStatus.problemLine(runs: [failed], hasNoRepositories: false) != nil)

        // The icon's order: unconfigured beats problem, so the icon and the
        // problem line both answer setup.
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
                == "Verification on NAS failed 2 hours ago"
        )
        #expect(
            MenuBarStatus.problemLine(runs: [failedRun(kind: .prune, name: "NAS")], hasNoRepositories: false, relative: Self.ago)
                == "Freeing space on NAS failed 2 hours ago"
        )
        #expect(
            MenuBarStatus.problemLine(runs: [failedRun(kind: .restore, name: "Report.pdf")], hasNoRepositories: false, relative: Self.ago)
                == "Restore of Report.pdf failed 2 hours ago"
        )
        #expect(
            MenuBarStatus.problemLine(runs: [failedRun(kind: .backup, name: "Nightly")], hasNoRepositories: false, relative: Self.ago)
                == "Nightly failed 2 hours ago"
        )
        // A subject nobody can name — a repository gone from the configuration
        // — says the kind instead of an empty name.
        #expect(
            MenuBarStatus.problemLine(runs: [failedRun(kind: .check, name: "")], hasNoRepositories: false, relative: Self.ago)
                == "Verification failed 2 hours ago"
        )
    }

    @Test("the subject names the repository the problem belongs to, derived from IDs")
    func subjectsNameTheRepository() {
        let home = repository(named: "Home Disk")
        let offsite = repository(named: "Offsite")
        var documents = plan(name: "Documents")
        documents.repositoryID = home.id

        func failedBackup(planID: UUID? = nil, planName: String, repositoryID: UUID?) -> RunRecord {
            var record = RunRecord(kind: .backup, planID: planID, planName: planName, repositoryID: repositoryID)
            record.outcome = .failed
            record.startedAt = .now.addingTimeInterval(-60)
            record.finishedAt = record.startedAt
            return record
        }

        #expect(
            MenuBarStatus.problemLine(
                runs: [failedBackup(planID: documents.id, planName: "Documents", repositoryID: home.id)],
                hasNoRepositories: false,
                plans: [documents],
                repositories: [home, offsite],
                relative: Self.ago
            ) == "Documents (Home Disk) failed 2 hours ago"
        )
        // The plan as it is called now, not as the record stored it.
        var renamed = documents
        renamed.path = "/Users/someone/Papers"
        #expect(
            MenuBarStatus.problemLine(
                runs: [failedBackup(planID: documents.id, planName: "Documents", repositoryID: home.id)],
                hasNoRepositories: false,
                plans: [renamed],
                repositories: [home],
                relative: Self.ago
            ) == "Papers (Home Disk) failed 2 hours ago"
        )
        // A check names the repository its ID resolves to — a rename between
        // the run and the banner must not leave it saying the old name.
        var check = RunRecord(kind: .check, planName: "Old Name", repositoryID: offsite.id)
        check.outcome = .failed
        check.startedAt = .now.addingTimeInterval(-60)
        check.finishedAt = check.startedAt
        #expect(
            MenuBarStatus.problemLine(
                runs: [check],
                hasNoRepositories: false,
                plans: [],
                repositories: [home, offsite],
                relative: Self.ago
            ) == "Verification on Offsite failed 2 hours ago"
        )
    }

    private var newYork: Calendar { newYorkCalendar() }

    private func flat(_ value: String) -> String { flatSpaces(value) }

    @Test("a hold replaces the next-run headline and names itself")
    func holdLeadsAndHeadlineStepsAside() throws {
        let future = Date.now.addingTimeInterval(3600)
        let nightly = plan(name: "Nightly")
        // While held, a "Next:" headline would lie: the scheduler will not
        // fire it.
        #expect(MenuBarStatus.headline(activity: [:], hold: .onMeteredNetwork, plans: [], repositories: [], nextRun: (nightly, future)) == nil)
        #expect(MenuBarStatus.headline(activity: [:], hold: .paused(until: future), plans: [], repositories: [], nextRun: (nightly, future)) == nil)
        #expect(
            MenuBarStatus.headline(activity: [:], hold: nil, plans: [], repositories: [], nextRun: (nightly, future))
                == MenuBarStatus.headline(activity: [:], plans: [], repositories: [], nextRun: (nightly, future))
        )
        #expect(MenuBarStatus.headline(activity: [:], hold: nil, plans: [], repositories: [], nextRun: (nightly, future))?.hasPrefix("Next: Nightly") == true)

        let calendar = newYork
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute)))
        }
        let now = try at(9, 10)
        #expect(
            flat(ScheduleHold.paused(until: try at(9, 15, 40)).summary(now: now, calendar: calendar))
                == "Backups paused until 3:40 PM"
        )
        #expect(
            flat(ScheduleHold.paused(until: try at(10, 0)).summary(now: now, calendar: calendar))
                == "Backups paused until tomorrow"
        )
        #expect(ScheduleHold.onMeteredNetwork.summary(now: now, calendar: calendar) == "Backups paused on a metered network")
        #expect(ScheduleHold.onMeteredNetwork.resumesAt == nil)
    }

    @Test("the tray's leading lines keep their order: verdict, hold, Status line when flat, and the running lines only where no headline stands")
    func trayLineOrder() {
        let runID = UUID()
        let running = [MenuBarStatus.RunningLine(id: "documents", text: "Documents — 40%")]

        #expect(
            MenuBarStatus.trayLines(
                verdict: .problem(text: "Documents failed 2 hours ago", runID: runID),
                holdSummary: "Backups paused until 3:40 PM",
                labeledStatus: nil,
                headline: nil,
                running: running
            ) == [
                .problem(text: "Documents failed 2 hours ago", runID: runID),
                .status("Backups paused until 3:40 PM"),
                .status("Documents — 40%"),
            ]
        )

        #expect(
            MenuBarStatus.trayLines(
                verdict: nil,
                holdSummary: nil,
                labeledStatus: nil,
                headline: "Next: Documents — in an hour",
                running: running
            ) == [.status("Next: Documents — in an hour")]
        )

        #expect(
            MenuBarStatus.trayLines(
                verdict: .status(MenuBarStatus.allUpToDateLine),
                holdSummary: nil,
                labeledStatus: "Home NAS — 2 of 2 plans up to date",
                headline: "No backups scheduled",
                running: running
            ) == [
                .status(MenuBarStatus.allUpToDateLine),
                .status("Home NAS — 2 of 2 plans up to date"),
                .status("No backups scheduled"),
            ]
        )
    }

    private func protectionRow(
        _ name: String, isKnown: Bool = true, isUpToDate: Bool, didFail: Bool = false, isRunning: Bool = false,
        stateText: String = "state"
    ) -> UpToDateRow {
        var plan = BackupPlan()
        plan.path = "/\(name)"
        return UpToDateRow(
            plan: plan, among: [plan], stateText: stateText, isKnown: isKnown,
            isUpToDate: isUpToDate, didFail: didFail, isRunning: isRunning
        )
    }

    @Test("the verdict leads with the worst thing wrong, and says all is well only when every plan is known to be")
    func verdict() {
        let runID = UUID()
        func verdict(
            _ rows: [UpToDateRow], isResticDamaged: Bool = false, noRepositories: Bool = false, problem: String? = nil
        ) -> MenuBarStatus.TrayLine? {
            MenuBarStatus.verdict(
                rows: rows, isResticDamaged: isResticDamaged, hasNoRepositories: noRepositories,
                problemLine: problem, problemID: problem == nil ? nil : runID
            )
        }
        let fine = protectionRow("Fine", isUpToDate: true)
        let overdue = protectionRow("Old", isUpToDate: false, stateText: "Not backed up for 9 days")

        #expect(verdict([fine]) == .status("All plans up to date"))
        #expect(verdict([overdue, fine]) == .status("Old: Not backed up for 9 days"))
        #expect(verdict([overdue], problem: "Check on NAS failed") == .problem(text: "Check on NAS failed", runID: runID))
        #expect(verdict([fine], isResticDamaged: true) == .status("SwiftRestic is damaged. Install it again."))
        // A listing still being read, or a first backup running: nobody can vouch yet.
        #expect(verdict([fine, protectionRow("Reading", isKnown: false, isUpToDate: false)]) == nil)
        #expect(verdict([protectionRow("First", isUpToDate: false, isRunning: true)]) == nil)
        #expect(verdict([]) == nil)
        #expect(verdict([], noRepositories: true) == nil)
    }

    @Test("the icon warns for what the verdict warns about, a hold included, with work running or not")
    func iconFollowsTheVerdict() {
        func state(rows: [UpToDateRow], isResticDamaged: Bool = false, activity: [UUID: PlanActivity] = [:]) -> MenuBarStatus.IconState {
            MenuBarStatus.iconState(
                activity: activity, maintenance: [:], isRestoring: false, isConsoleRunning: false,
                hasNoRepositories: false, runs: [], rows: rows, isResticDamaged: isResticDamaged
            )
        }
        let fine = protectionRow("Fine", isUpToDate: true)
        #expect(state(rows: [fine]) == .idle)
        #expect(state(rows: [fine], isResticDamaged: true) == .problem)
        #expect(state(rows: [protectionRow("Old", isUpToDate: false)]) == .problem)
        #expect(state(rows: [protectionRow("Gone", isKnown: false, isUpToDate: false, didFail: true)]) == .problem)
        #expect(state(rows: [protectionRow("Reading", isKnown: false, isUpToDate: false)]) == .idle)
        #expect(state(rows: [protectionRow("Old", isUpToDate: false)], activity: [UUID(): activity()]) == .problem)
        #expect(state(rows: [fine], activity: [UUID(): activity()]) == .running)
        #expect(state(rows: [fine], isResticDamaged: true, activity: [UUID(): activity()]) == .problem)
    }

    @Test("work in flight does not hide a standing failure, and a plan's own run does not read as its problem")
    func problemOutranksRunning() {
        func state(rows: [UpToDateRow] = [], runs: [RunRecord] = [], isRestoring: Bool = false, hasNoRepositories: Bool = false) -> MenuBarStatus.IconState {
            MenuBarStatus.iconState(
                activity: [:], maintenance: [:], isRestoring: isRestoring, isConsoleRunning: false,
                hasNoRepositories: hasNoRepositories, runs: runs, rows: rows
            )
        }
        var failed = RunRecord(kind: .backup, planID: UUID(), planName: "Documents")
        failed.outcome = .failed
        failed.startedAt = .now.addingTimeInterval(-60)

        #expect(state(runs: [failed], isRestoring: true) == .problem)
        #expect(state(isRestoring: true) == .running)
        // A plan's first backup, or an overdue plan's catching up: the run in
        // flight is the answer to the row's complaint.
        let catchingUp = protectionRow("First", isUpToDate: false, isRunning: true)
        #expect(state(rows: [catchingUp], isRestoring: true) == .running)
        // Run history outlives removed locations.
        #expect(state(runs: [failed], isRestoring: true, hasNoRepositories: true) == .running)
        #expect(state(runs: [failed], hasNoRepositories: true) == .unconfigured)

        #expect(MenuBarStatus.accessibilityDescription(for: .problem, isWorking: true) == "SwiftRestic, needs attention; work in progress")
        #expect(MenuBarStatus.accessibilityDescription(for: .problem) == "SwiftRestic, needs attention")
        // The running face already says it: once, not twice.
        #expect(MenuBarStatus.accessibilityDescription(for: .running, isWorking: true) == "SwiftRestic, work in progress")
    }

    @Test("plan rows back up when idle, stop while running, and stand disabled while stopping")
    func planRowsStopWhileRunning() {
        let nightly = plan(name: "Nightly")
        // No path yet: incomplete, and nothing to be called.
        var incomplete = plan(name: "Half")
        incomplete.path = ""
        let scans = plan(name: "Scans")
        let photos = plan(name: "Photos")

        let idle = MenuBarStatus.planRows(plans: [nightly, incomplete, scans, photos], activity: [:], isResticDamaged: false)
        #expect(idle.map(\.planID) == [nightly.id, incomplete.id, scans.id, photos.id])
        #expect(idle[0] == MenuBarStatus.PlanRow(planID: nightly.id, title: "Back Up “Nightly” Now", action: .backUp, isEnabled: true))
        #expect(idle[1].action == .backUp)
        #expect(!idle[1].isEnabled)
        #expect(idle[1].title == "Back Up “Untitled Plan” Now")
        #expect(idle[2].title == "Back Up “Scans” Now")

        let noRestic = MenuBarStatus.planRows(plans: [nightly], activity: [:], isResticDamaged: true)
        #expect(noRestic.first?.isEnabled == false)

        let running = MenuBarStatus.planRows(
            plans: [nightly, photos],
            activity: [nightly.id: activity(phase: .backingUp)],
            isResticDamaged: false
        )
        #expect(running[0] == MenuBarStatus.PlanRow(planID: nightly.id, title: "Stop “Nightly” Backup", action: .stop, isEnabled: true))
        #expect(running[1].title == "Back Up “Photos” Now")
        #expect(running[1].isEnabled)
        // A stop is a stop whatever the run is doing — retention too.
        let retention = MenuBarStatus.planRows(plans: [nightly], activity: [nightly.id: activity(phase: .applyingRetention)], isResticDamaged: false)
        #expect(retention.first?.action == .stop)

        let stopping = MenuBarStatus.planRows(
            plans: [nightly],
            activity: [nightly.id: activity(phase: .cancelling)],
            isResticDamaged: false
        )
        #expect(stopping.first == MenuBarStatus.PlanRow(planID: nightly.id, title: "Stopping “Nightly”…", action: .none, isEnabled: false))
    }

    @Test("plan rows group by repository, in configuration order, and only two or more groups are submenus")
    func planRowsGroupByRepository() {
        let home = repository(named: "Home Disk")
        let offsite = repository(named: "Offsite")
        func groupedPlan(_ name: String, on repository: Repository) -> BackupPlan {
            var value = plan(name: name)
            value.repositoryID = repository.id
            return value
        }
        let documents = groupedPlan("Documents", on: home)
        let photos = groupedPlan("Photos", on: home)
        let archive = groupedPlan("Archive", on: offsite)

        let groups = MenuBarStatus.planGroups(
            plans: [photos, archive, documents],
            repositories: [offsite, home],
            activity: [:],
            isResticDamaged: false
        )
        // Repositories in configuration order, plans in the order given —
        // from the model that is `configuration.plans`'s order.
        #expect(groups.map(\.title) == ["Offsite", "Home Disk"])
        #expect(groups[0].rows.map(\.planID) == [archive.id])
        #expect(groups[1].rows.map(\.planID) == [photos.id, documents.id])
        #expect(groups[1].rows.map(\.title) == ["Back Up “Photos” Now", "Back Up “Documents” Now"])
        #expect(MenuBarStatus.showsGroupsAsSubmenus(groups))

        let running = MenuBarStatus.planGroups(
            plans: [documents],
            repositories: [home],
            activity: [documents.id: activity(phase: .backingUp)],
            isResticDamaged: false
        )
        #expect(running.map(\.title) == ["Home Disk"])
        #expect(running[0].rows.map(\.title) == ["Stop “Documents” Backup"])

        let single = MenuBarStatus.planGroups(
            plans: [documents],
            repositories: [home],
            activity: [:],
            isResticDamaged: false
        )
        #expect(single.map(\.title) == ["Home Disk"])
        #expect(!MenuBarStatus.showsGroupsAsSubmenus(single))

        // A repository with no plans gets no group, so it does not make one
        // repository's rows a submenu.
        let empty = repository(named: "Empty")
        let withEmpty = MenuBarStatus.planGroups(plans: [documents], repositories: [home, empty], activity: [:], isResticDamaged: false)
        #expect(withEmpty.map(\.title) == ["Home Disk"])
        #expect(!MenuBarStatus.showsGroupsAsSubmenus(withEmpty))
    }

    @Test("the icon dims for a hold only while nothing runs, and says why")
    func heldIconDimsAndSpeaks() {
        let pause = ScheduleHold.paused(until: .now.addingTimeInterval(3600))
        #expect(MenuBarStatus.appearsHeld(state: .idle, hold: .onMeteredNetwork))
        #expect(MenuBarStatus.appearsHeld(state: .problem, hold: pause))
        #expect(!MenuBarStatus.appearsHeld(state: .running, hold: .onMeteredNetwork))
        #expect(!MenuBarStatus.appearsHeld(state: .running, hold: pause))
        #expect(!MenuBarStatus.appearsHeld(state: .idle, hold: nil))

        let paused = MenuBarStatus.accessibilityDescription(for: .idle, hold: pause)
        #expect(paused.contains("paused"), "was \(paused)")
        #expect(paused.hasPrefix("SwiftRestic"))
        let problemHeld = MenuBarStatus.accessibilityDescription(for: .problem, hold: .onMeteredNetwork)
        #expect(problemHeld.contains("attention") && problemHeld.contains("metered"), "was \(problemHeld)")
        // No hold: the words spelled out, so a default argument cannot make
        // the comparison trivially true.
        #expect(MenuBarStatus.accessibilityDescription(for: .idle, hold: nil) == "SwiftRestic")
        #expect(MenuBarStatus.accessibilityDescription(for: .problem, hold: nil) == "SwiftRestic, needs attention")
        #expect(MenuBarStatus.accessibilityDescription(for: .running, hold: nil) == "SwiftRestic, work in progress")

        // A damaged install has no face of its own; its words join the label
        // the way the menu's leading line words it.
        #expect(MenuBarStatus.accessibilityDescription(for: .idle, isResticDamaged: true)
            == "SwiftRestic, SwiftRestic is damaged. Install it again.")
        #expect(MenuBarStatus.accessibilityDescription(for: .idle, hold: nil, isResticDamaged: false)
            == "SwiftRestic")
    }
}

/// The tray's problem line and a notification click (`TrayStatusItem.showRun`).
@MainActor
@Suite("Problem routes")
struct ProblemRouteTests {
    @Test("a run with a fix that opens a sheet lands Activity on the run with that sheet asked for; any other run lands on Activity alone")
    func runFixOpensOverActivity() {
        let runID = UUID()
        let repositoryID = UUID()
        let planID = UUID()
        let cases: [(RunFix?, AppRouter.Intent?)] = [
            (.enterPassword(repositoryID), .enterPassword(repositoryID)),
            (.enterSharePassword(.repository(repositoryID)), .enterSharePassword(.repository(repositoryID))),
            (.enterSharePassword(.plan(planID)), .enterSharePassword(.plan(planID))),
            (.addRepository(repositoryID), .addRepository(replacing: repositoryID)),
            (.freeUpSpace(repositoryID), nil),
            (.locate(repositoryID), nil),
            (.locateFolder(planID: planID), nil),
            (nil, nil),
        ]
        for (fix, intent) in cases {
            let router = AppRouter()
            router.focusRun(runID, openingFix: fix)
            #expect(router.selection == .activity, "\(String(describing: fix))")
            #expect(router.activityFocusRunID == runID, "\(String(describing: fix))")
            #expect(router.pendingIntent == intent, "\(String(describing: fix))")
        }
    }
}
