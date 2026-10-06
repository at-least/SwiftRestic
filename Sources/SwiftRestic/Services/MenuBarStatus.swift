import Foundation

/// The menu bar's headline, derived from observable state.
///
/// Pure and view-free, so the idle → running → finished transitions can be
/// tested by handing it snapshots of the state.
enum MenuBarStatus {
    /// The four faces the menu bar icon can wear. Running beats everything
    /// else: an animated-then-badged glyph would flicker between faces on
    /// every run. Unconfigured beats problem: run history outlives removed
    /// repositories, so the icon must not ask for setup over a line
    /// announcing an old failure.
    enum IconState: Equatable {
        case unconfigured
        case idle
        case running
        case problem
    }

    /// Which face the icon wears right now. Every kind of restic work counts
    /// as running — the menu bar is the only surface that exists when the
    /// window is closed, so work invisible there is invisible everywhere.
    /// A problem is `newestStandingProblem`'s: the seven-day window, less
    /// what a later successful backup healed.
    static func iconState(
        activity: [UUID: PlanActivity],
        maintenance: [UUID: MaintenanceActivity],
        isRestoring: Bool,
        isConsoleRunning: Bool,
        hasNoRepositories: Bool,
        runs: [RunRecord],
        now: Date = .now
    ) -> IconState {
        let isRunning = !activity.isEmpty || !maintenance.isEmpty || isRestoring || isConsoleRunning
        if isRunning { return .running }
        if hasNoRepositories { return .unconfigured }
        return newestStandingProblem(runs: runs, now: now) == nil ? .idle : .problem
    }

    /// What the icon draws for a state: the app's own line drawing (see
    /// `MenuBarLogo`), pulsing while running, and one small companion dot for
    /// both intervention states — the dot's job is "open me", and the menu's
    /// first line names the reason, so unconfigured and problem share one
    /// face.
    enum Glyph: Equatable {
        case logo
        case badgedLogo
        case animatedLogo
    }

    static func glyph(for state: IconState) -> Glyph {
        switch state {
        case .unconfigured: .badgedLogo
        case .idle: .logo
        case .running: .animatedLogo
        case .problem: .badgedLogo
        }
    }

    /// The face's words, with the hold when one is in force — the dimmed
    /// face is otherwise invisible to VoiceOver ("SwiftRestic, backups
    /// paused until 3:40 PM").
    static func accessibilityDescription(
        for state: IconState,
        hold: ScheduleHold? = nil,
        now: Date = .now
    ) -> String {
        let base = switch state {
        case .unconfigured: "SwiftRestic, no repository configured yet"
        case .idle: "SwiftRestic"
        case .running: "SwiftRestic, work in progress"
        case .problem: "SwiftRestic, a recent run had a problem"
        }
        guard let hold else { return base }
        let summary = hold.summary(now: now)
        let clause = summary.prefix(1).lowercased() + summary.dropFirst()
        return state == .idle ? "\(base), \(clause)" : "\(base); \(clause)"
    }

    /// Whether the icon wears its dimmed face: a hold is in force and nothing
    /// runs. The running face wins — work in flight is the news, and a run
    /// the user started by hand ignores the hold.
    static func appearsHeld(state: IconState, hold: ScheduleHold?) -> Bool {
        hold != nil && state != .running
    }

    /// The newest problem of the week's set that no later success has healed,
    /// or nil — what `iconState` asks for and `problemLine` words.
    static func newestStandingProblem(runs: [RunRecord], now: Date = .now) -> RunRecord? {
        OverviewMetrics.problems(in: runs, since: OverviewMetrics.problemWindowStart(from: now))
            .filter { !OverviewMetrics.isHealed($0, in: runs) }
            .max { $0.finishedAt < $1.finishedAt }
    }

    /// The newest problem in the run history that still stands, as one
    /// sentence, or `nil` while there is none. From `OverviewMetrics.problems`'s
    /// week it drops the backup failures a later successful backup of the same
    /// plan healed (`OverviewMetrics.isHealed`, the sidebar's rule): the dot
    /// and this line lead the user in, and leading with a failure forever
    /// would read as permanent breakage.
    ///
    /// Yields to `hasNoRepositories`: it must not answer the `unconfigured`
    /// face with a failure of a removed repository's runs.
    ///
    /// `plans` and `repositories` name the subject by the one run-naming rule.
    static func problemLine(
        runs: [RunRecord],
        hasNoRepositories: Bool,
        plans: [BackupPlan] = [],
        repositories: [Repository] = [],
        now: Date = .now,
        relative: (Date) -> String = { Format.relative($0) }
    ) -> String? {
        guard !hasNoRepositories else { return nil }
        guard let newest = newestStandingProblem(runs: runs, now: now) else { return nil }

        // The subject is the run's display name — the plan with its
        // repository for a backup, the repository alone for a check or
        // prune ("NAS failed" would read as the NAS failing).
        let name = RunRecordPresentation.displayName(for: newest, plans: plans, repositories: repositories)
        let subject: String
        if name.isEmpty {
            subject = newest.kind.displayName
        } else {
            switch newest.kind {
            case .backup:
                subject = name
            case .restore:
                subject = "Restore of \(name)"
            case .check, .prune, .forget:
                subject = "\(newest.kind.displayName) on \(name)"
            }
        }
        let verb = newest.outcome == .failed ? "failed" : "finished with errors"
        return "\(subject) \(verb) \(relative(newest.finishedAt))"
    }

    /// The single line above the plan buttons. `nil` while anything runs —
    /// restores and repository upkeep included: the running lines replace it
    /// rather than sitting underneath. `nil` under a hold too: the hold's own
    /// line leads the menu, and a next-run headline would announce a run the
    /// scheduler will not fire. `hasNoRepositories` answers the
    /// `unconfigured` icon face: it tells a first-time user what to do next.
    ///
    /// The plan is named with its repository — two repositories can hold
    /// same-named plans.
    static func headline(
        activity: [UUID: PlanActivity],
        maintenance: [UUID: MaintenanceActivity] = [:],
        isRestoring: Bool = false,
        isConsoleRunning: Bool = false,
        hasNoRepositories: Bool = false,
        hold: ScheduleHold? = nil,
        repositories: [Repository],
        nextRun: (plan: BackupPlan, date: Date)?
    ) -> String? {
        guard activity.isEmpty, maintenance.isEmpty, !isRestoring, !isConsoleRunning else { return nil }
        guard hold == nil else { return nil }
        if hasNoRepositories { return "No repository set up yet" }
        guard let nextRun else { return "No backups scheduled" }
        let name = RunRecordPresentation.planWithRepository(nextRun.plan, repositories: repositories)
        // The plan page's Next backup tile spells the same moment in these
        // words; the scheduler clamps the date to now, so a due run reads
        // "Due now".
        return "Next: \(name) — \(Format.tileTimestamp(nextRun.date))"
    }

    /// One tray row per plan, in configuration order: Back Up Now while the
    /// plan is idle, Stop while it runs — the tray is the only surface once
    /// the window is closed, so a running backup must keep a working Stop
    /// there.
    struct PlanRow: Equatable {
        enum Action: Equatable {
            case backUp
            case stop
            case none
        }

        var planID: UUID
        var title: String
        var action: Action
        var isEnabled: Bool
    }

    static func planRows(
        plans: [BackupPlan],
        activity: [UUID: PlanActivity],
        isResticAvailable: Bool
    ) -> [PlanRow] {
        plans.map { plan in
            let name = plan.displayName
            switch activity[plan.id]?.phase {
            case nil:
                // The rule every Back Up Now follows: enabled only where the
                // plan could run.
                return PlanRow(
                    planID: plan.id,
                    title: "Back Up “\(name)” Now",
                    action: .backUp,
                    isEnabled: plan.isConfigurationComplete && isResticAvailable
                )
            case .cancelling?:
                return PlanRow(planID: plan.id, title: "Stopping “\(name)”…", action: .none, isEnabled: false)
            case let phase?:
                // No percentage: restic's measure is reading, not uploading,
                // and "Stop (100%)" would make stopping look free. The
                // running line above keeps restic's figure.
                let title = stopsRetention(phase) ? "Stop Applying Retention to “\(name)”" : "Stop “\(name)” Backup"
                return PlanRow(planID: plan.id, title: title, action: .stop, isEnabled: true)
            }
        }
    }

    /// Whether Stop, in this phase of a plan's run, ends a forget rather
    /// than a backup: Apply Retention Now…'s run, or a backup's own
    /// retention step, whose snapshot is already written. The one rule the
    /// tray's row and the Plan menu's Stop item both word themselves by.
    static func stopsRetention(_ phase: PlanActivity.Phase?) -> Bool {
        phase == .applyingRetention
    }

    /// One tray submenu per repository, its plans' rows under the
    /// repository's own name, repositories in configuration order and plans
    /// in theirs — the flat list could not tell two repositories' same-named
    /// plans apart. A single repository still gets its submenu, so the shape
    /// never changes when a second arrives. Removing a repository removes its
    /// plans, so no plan is left without a group.
    struct PlanGroup: Equatable {
        var repositoryID: UUID
        var title: String
        var rows: [PlanRow]
    }

    static func planGroups(
        plans: [BackupPlan],
        repositories: [Repository],
        activity: [UUID: PlanActivity],
        isResticAvailable: Bool
    ) -> [PlanGroup] {
        repositories.compactMap { repository in
            let rows = planRows(
                plans: plans.filter { $0.repositoryID == repository.id },
                activity: activity,
                isResticAvailable: isResticAvailable
            )
            return rows.isEmpty ? nil : PlanGroup(repositoryID: repository.id, title: repository.name, rows: rows)
        }
    }

    /// One line per job in flight, in the order plans, upkeep, restore — the
    /// menu reads top-down from the plan the user most likely came for.
    /// Identified by a stable string (two lines can share a display name, and
    /// a `ForEach` over bare strings would collide).
    struct RunningLine: Equatable, Identifiable {
        var id: String
        var text: String
    }

    static func runningLines(
        plans: [BackupPlan],
        repositories: [Repository],
        activity: [UUID: PlanActivity],
        progress: [UUID: OperationProgress]
    ) -> [RunningLine] {
        plans.filter { activity[$0.id] != nil }.map { plan in
            // The plan with its repository, like the idle headline — two
            // same-named plans can run at once.
            let name = RunRecordPresentation.planWithRepository(plan, repositories: repositories)
            return RunningLine(
                id: plan.id.uuidString,
                text: "\(name) — \(progressText(activity: activity[plan.id], progress: progress[plan.id]))"
            )
        }
    }

    /// One line per repository whose check or prune is running.
    static func maintenanceLines(
        repositories: [Repository],
        maintenance: [UUID: MaintenanceActivity]
    ) -> [RunningLine] {
        repositories.filter { maintenance[$0.id] != nil }.map { repository in
            let task = maintenance[repository.id]?.task.displayName.lowercased() ?? "maintenance"
            return RunningLine(
                id: "maintenance-\(repository.id.uuidString)",
                text: "\(repository.name) — \(task) running"
            )
        }
    }

    /// The restore, which is always at most one. `nil` while nothing restores.
    static func restoreLine(progress: OperationProgress?) -> RunningLine? {
        guard let progress else { return nil }
        let percent = progress.fraction.formatted(.percent.precision(.fractionLength(0)))
        return RunningLine(id: "restore", text: "Restoring — \(percent)")
    }

    /// A console command in flight: short commands never render it long
    /// enough to matter, but a long `prune` typed there deserves the same
    /// visibility as any other restic work.
    static func consoleLine(isRunning: Bool) -> RunningLine? {
        guard isRunning else { return nil }
        return RunningLine(id: "console", text: "Console — command running")
    }

    /// Progress as the menu bar shows it: a percentage once restic is
    /// streaming status, the phase's name before that. Progress arrives
    /// beside the activity, not inside it — the menu is built from the pair
    /// when it opens.
    static func progressText(activity: PlanActivity?, progress: OperationProgress?) -> String {
        guard let activity else { return "…" }
        guard activity.phase == .backingUp else { return activity.phase.displayName }
        let fraction = progress?.fraction ?? 0
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}
