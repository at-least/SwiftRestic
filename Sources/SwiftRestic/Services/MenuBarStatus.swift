import Foundation

/// The menu bar's headline, derived from observable state.
///
/// Pure and view-free, so the idle → running → finished transitions can be
/// tested by handing it snapshots of the state.
enum MenuBarStatus {
    /// The four faces the menu bar icon can wear. Problem beats running: the
    /// icon answers "am I safe?" first, and a failure stays one steady face
    /// until a success heals it. A plan's own run does not count against it,
    /// so a first backup pulses. Unconfigured beats problem: run history
    /// outlives removed repositories, so the icon must not ask for setup over
    /// a line announcing an old failure.
    enum IconState: Equatable {
        case unconfigured
        case idle
        case running
        case problem
    }

    /// Every kind of restic work counts: the menu bar is the only surface
    /// that exists when the window is closed.
    static func isWorking(
        activity: [UUID: PlanActivity],
        maintenance: [UUID: MaintenanceActivity],
        isRestoring: Bool,
        isConsoleRunning: Bool
    ) -> Bool {
        !activity.isEmpty || !maintenance.isEmpty || isRestoring || isConsoleRunning
    }

    /// A problem is what `verdict` would lead with: a damaged install, a run's
    /// standing problem, or a plan not running that needs attention.
    static func iconState(
        activity: [UUID: PlanActivity],
        maintenance: [UUID: MaintenanceActivity],
        isRestoring: Bool,
        isConsoleRunning: Bool,
        hasNoRepositories: Bool,
        runs: [RunRecord],
        rows: [ProtectionRow] = [],
        isResticDamaged: Bool = false,
        now: Date = .now
    ) -> IconState {
        let isRunning = isWorking(activity: activity, maintenance: maintenance, isRestoring: isRestoring, isConsoleRunning: isConsoleRunning)
        if hasNoRepositories { return isRunning ? .running : .unconfigured }
        let isHealthy = !isResticDamaged
            && newestStandingProblem(runs: runs, now: now) == nil
            && OverviewMetrics.needingAttention(rows.filter { !$0.isRunning }).isEmpty
        if !isHealthy { return .problem }
        return isRunning ? .running : .idle
    }

    /// What the icon draws for a state: the app's own line drawing (see
    /// `MenuBarLogo`), pulsing while running, and with an exclamation mark
    /// in the stack's place for a standing problem — Time Machine's menu
    /// bar sign for a backup that needs the user; the menu's first line
    /// names the run. An empty install wears the plain mark: a mark asking
    /// for attention over a setup that has not begun would read as a
    /// failure that has not happened, and the menu's first line says what
    /// to set up (its VoiceOver words say so too).
    enum Glyph: Equatable {
        case logo
        case attentionLogo
        case animatedLogo
    }

    static func glyph(for state: IconState) -> Glyph {
        switch state {
        case .unconfigured: .logo
        case .idle: .logo
        case .running: .animatedLogo
        case .problem: .attentionLogo
        }
    }

    /// The face's words, with what the glyph can't show: a hold, restic
    /// missing, work running under a problem's steady face
    /// ("SwiftRestic, backups paused until 3:40 PM").
    static func accessibilityDescription(
        for state: IconState,
        hold: ScheduleHold? = nil,
        isResticDamaged: Bool = false,
        isWorking: Bool = false,
        now: Date = .now
    ) -> String {
        let base = switch state {
        case .unconfigured: "SwiftRestic, no backup location set"
        case .idle: "SwiftRestic"
        case .running: "SwiftRestic, work in progress"
        case .problem: "SwiftRestic, needs attention"
        }
        var clauses: [String] = []
        if isWorking, state != .running { clauses.append("work in progress") }
        if let hold {
            let summary = hold.summary(now: now)
            clauses.append(summary.prefix(1).lowercased() + summary.dropFirst())
        }
        if isResticDamaged { clauses.append(damagedLine) }
        guard !clauses.isEmpty else { return base }
        let separator = state == .idle ? ", " : "; "
        return base + clauses.map { separator + $0 }.joined()
    }

    /// Whether the icon wears its dimmed face: a hold is in force and nothing
    /// runs. The running face wins — work in flight is the news, and a run
    /// the user started by hand ignores the hold.
    static func appearsHeld(state: IconState, hold: ScheduleHold?) -> Bool {
        hold != nil && state != .running
    }

    static func newestStandingProblem(runs: [RunRecord], now: Date = .now) -> RunRecord? {
        OverviewMetrics.problems(in: runs, since: OverviewMetrics.problemWindowStart(from: now))
            .filter { !OverviewMetrics.isHealed($0, in: runs) }
            .max { $0.finishedAt < $1.finishedAt }
    }

    /// The newest problem in the run history that still stands, as one
    /// sentence, or `nil` while there is none. From `OverviewMetrics.problems`'s
    /// week it drops the backup failures a later successful backup of the same
    /// plan healed (`OverviewMetrics.isHealed`, the sidebar's rule): this line leads the
    /// user in, and leading with a failure forever
    /// would read as permanent breakage.
    ///
    /// Yields to `hasNoRepositories`: it must not answer the `unconfigured`
    /// state with a failure of a removed repository's runs.
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
            case .check, .prune, .forget, .rewrite:
                subject = "\(newest.kind.displayName) on \(name)"
            }
        }
        // The outcome's own words, as the sidebar, the plan page and Activity
        // say it. Notification bodies keep their count-bearing prose
        // ("Completed with 2 unreadable items.") — a sentence about the run,
        // not its label.
        return "\(subject) \(newest.outcome.displayName.lowercased()) \(relative(newest.finishedAt))"
    }

    /// Leads the menu, as a hold's line does: the scheduler starts nothing
    /// without restic.
    static let damagedLine = ResticError.damagedInstall.localizedDescription

    /// The single line above the plan buttons. `nil` while anything runs —
    /// restores and repository upkeep included: the running lines replace it
    /// rather than sitting underneath. Console work has no running line, so
    /// it does not hold the headline back. `nil` under a hold too: the hold's own
    /// line leads the menu, and a next-run headline would announce a run the
    /// scheduler will not fire — and while restic is damaged, for the same
    /// reason. `hasNoRepositories` answers the
    /// `unconfigured` icon face: it tells a first-time user what to do next.
    ///
    /// The plan is named with its repository — two repositories can hold
    /// same-named plans.
    static func headline(
        activity: [UUID: PlanActivity],
        maintenance: [UUID: MaintenanceActivity] = [:],
        isRestoring: Bool = false,
        hasNoRepositories: Bool = false,
        hold: ScheduleHold? = nil,
        isResticDamaged: Bool = false,
        plans: [BackupPlan],
        repositories: [Repository],
        nextRun: (plan: BackupPlan, date: Date)?
    ) -> String? {
        guard activity.isEmpty, maintenance.isEmpty, !isRestoring else { return nil }
        guard hold == nil, !isResticDamaged else { return nil }
        if hasNoRepositories { return "No backup location set" }
        guard let nextRun else { return "No backups scheduled" }
        // The plan page's Next backup tile spells the same moment in these
        // words; the scheduler clamps the date to now, so a due run reads
        // "Due now".
        return "Next: " + RunRecordPresentation.nextRunLine(
            plan: nextRun.plan, date: nextRun.date, plans: plans, repositories: repositories
        )
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
        var disabledReason: String?
    }

    static func planRows(
        plans: [BackupPlan],
        activity: [UUID: PlanActivity],
        isResticDamaged: Bool,
        lockedRepositories: [UUID: String] = [:]
    ) -> [PlanRow] {
        plans.map { plan in
            let name = plan.label(among: plans)
            switch activity[plan.id]?.phase {
            case nil:
                // The rule every Back Up Now follows: enabled only where the
                // plan could run — not while its repository is locked
                // exclusively, which restic would refuse at once.
                let lockReason = plan.repositoryID.flatMap { lockedRepositories[$0] }
                return PlanRow(
                    planID: plan.id,
                    title: "Back Up “\(name)” Now",
                    action: .backUp,
                    isEnabled: plan.isConfigurationComplete && !isResticDamaged && lockReason == nil,
                    // The Backup menu's own words for each reason.
                    disabledReason: !plan.isConfigurationComplete ? BackupPlan.incompleteConfigurationReason
                        : isResticDamaged ? damagedLine : lockReason
                )
            case .cancelling?:
                return PlanRow(planID: plan.id, title: "Stopping “\(name)”…", action: .none, isEnabled: false)
            case let phase?:
                // No percentage: restic's measure is reading, not uploading,
                // and "Stop (100%)" would make stopping look free. The
                // running line above keeps restic's figure.
                return PlanRow(planID: plan.id, title: stopTitle(for: phase, planName: name), action: .stop, isEnabled: true)
            }
        }
    }

    /// The Backup menu's Stop for this phase of a plan's run: a backup's own
    /// retention step, whose snapshot is already written, is no backup. The
    /// tray's row passes `planName`.
    static func stopTitle(for phase: PlanActivity.Phase?, planName: String? = nil) -> String {
        let quoted = planName.map { "“\($0)”" }
        switch phase {
        case .applyingRetention?: return quoted.map { "Stop Removing Old Backups of \($0)" } ?? "Stop Removing Old Backups"
        default: return quoted.map { "Stop \($0) Backup" } ?? "Stop Backup"
        }
    }

    /// One group per repository with plans, its plans' rows under the
    /// repository's own name, repositories in configuration order and plans
    /// in theirs — a flat list of two repositories could not tell their
    /// same-named plans apart. Removing a repository removes its plans, so
    /// no plan is left without a group.
    struct PlanGroup: Equatable {
        var repositoryID: UUID
        var title: String
        /// The repository page's Protection line ("3 of 3 plans up to date ·
        /// Last backup 3 hours ago"), so the tray answers "did my backups
        /// run?" with the window closed. Nil until the listing has loaded.
        var protection: String?
        var rows: [PlanRow]
        /// The plans' news under the verbs: with the window closed the tray
        /// is the only surface, and one plan's failure must not hide
        /// another's.
        var newsLines: [String] = []

        /// The Protection line where no submenu title names the repository.
        var labeledProtection: String? {
            protection.map { "\(title) — \($0)" }
        }
    }

    /// One submenu per group only when there are two or more: a single
    /// repository's rows sit in the menu itself, a hover closer (the user's
    /// call, 2026-10-24).
    static func showsGroupsAsSubmenus(_ groups: [PlanGroup]) -> Bool {
        groups.count > 1
    }

    /// A plan's lines in its repository's submenu: news only, a standing
    /// problem, in the sidebar caption's words, joined to the
    /// plan's label as the Status section join them
    /// ("Code: Failed — 3 hours ago"). A quiet plan says nothing (success is
    /// quiet); a running plan's line already leads the menu. The menu's top
    /// problem line repeats the newest problem as a sentence on purpose: a
    /// submenu opened by hover must read on its own.
    static func newsLines(
        for plan: BackupPlan,
        among plans: [BackupPlan],
        activity: PlanActivity?,
        problem: RunRecord?,
        now: Date,
        relative: (Date) -> String = { Format.relative($0) }
    ) -> [String] {
        guard activity == nil else { return [] }
        guard problem != nil else { return [] }
        let caption = PlanStatus.sidebarCaption(
            for: plan,
            activity: nil,
            problem: problem,
            existingRepositoryIDs: [],
            now: now,
            relative: relative
        )
        return ["\(plan.label(among: plans)): \(caption.text)"]
    }

    static func planGroups(
        plans: [BackupPlan],
        repositories: [Repository],
        activity: [UUID: PlanActivity],
        isResticDamaged: Bool,
        lockedRepositories: [UUID: String] = [:],
        problem: (UUID) -> RunRecord? = { _ in nil },
        protection: (UUID) -> ProtectionSummary? = { _ in nil },
        now: Date = .now,
        relative: (Date) -> String = { Format.relative($0) }
    ) -> [PlanGroup] {
        repositories.compactMap { repository in
            let members = plans.filter { $0.repositoryID == repository.id }
            let rows = planRows(
                plans: members,
                activity: activity,
                isResticDamaged: isResticDamaged,
                lockedRepositories: lockedRepositories
            )
            let news = members.flatMap { plan in
                newsLines(for: plan, among: members, activity: activity[plan.id], problem: problem(plan.id), now: now, relative: relative)
            }
            return rows.isEmpty ? nil : PlanGroup(
                repositoryID: repository.id,
                title: repository.label(among: repositories),
                protection: protection(repository.id)?.text,
                rows: rows,
                newsLines: news
            )
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
            let name = RunRecordPresentation.planWithRepository(plan, plans: plans, repositories: repositories)
            return RunningLine(
                id: plan.id.uuidString,
                text: "\(name) — \(progressText(activity: activity[plan.id], progress: progress[plan.id]))"
            )
        }
    }

    static func maintenanceLines(
        repositories: [Repository],
        maintenance: [UUID: MaintenanceActivity]
    ) -> [RunningLine] {
        repositories.compactMap { repository in
            guard let work = maintenance[repository.id] else { return nil }
            return RunningLine(
                id: "maintenance-\(repository.id.uuidString)",
                text: "\(repository.label(among: repositories)) — \(work.task.inFlightTitle)"
            )
        }
    }

    /// The restore, which is always at most one.
    static func restoreLine(progress: OperationProgress?) -> RunningLine? {
        guard let progress else { return nil }
        let percent = Format.percent(progress.fraction)
        return RunningLine(id: "restore", text: "Restoring — \(percent)")
    }

    /// Progress as the menu bar shows it: a percentage once restic is
    /// streaming status, the phase's name before that. Progress arrives
    /// beside the activity, not inside it — the menu is built from the pair
    /// when it opens.
    static func progressText(activity: PlanActivity?, progress: OperationProgress?) -> String {
        guard let activity else { return "…" }
        guard activity.phase == .backingUp else { return activity.phase.displayName }
        return Format.percent(progress?.fraction ?? 0)
    }

    /// One leading line of the tray's menu, before the repository rows.
    enum TrayLine: Equatable {
        /// Greyed status text.
        case status(String)
        /// The problem sentence: the menu's one line that goes somewhere
        /// (Show in Activity), so it carries the run it names.
        case problem(text: String, runID: UUID)
    }

    /// "Am I safe?" in one line: the worst thing wrong, or that nothing is.
    /// Nil where neither is known yet, because no plan can be vouched for
    /// while a listing is still being read or a first backup runs, and while
    /// nothing is set up, where the headline says what to do.
    static func verdict(
        rows: [ProtectionRow],
        isResticDamaged: Bool,
        hasNoRepositories: Bool,
        problemLine: String?,
        problemID: UUID?
    ) -> TrayLine? {
        if isResticDamaged { return .status(damagedLine) }
        guard !hasNoRepositories else { return nil }
        if let problemLine, let problemID { return .problem(text: problemLine, runID: problemID) }
        if let worst = OverviewMetrics.needingAttention(rows).first {
            return .status("\(worst.planName): \(worst.stateText)")
        }
        guard !rows.isEmpty, rows.allSatisfy(\.isProtected) else { return nil }
        return .status(allUpToDateLine)
    }

    static let allUpToDateLine = "All plans up to date"

    /// The tray's leading lines, in the order a menu open reads them: the
    /// verdict, the hold, the named Protection line when no submenu carries
    /// it, then the idle headline or the running lines (which replace it).
    static func trayLines(
        verdict: TrayLine?,
        holdSummary: String?,
        labeledProtection: String?,
        headline: String?,
        running: [RunningLine]
    ) -> [TrayLine] {
        var lines: [TrayLine] = []
        if let verdict { lines.append(verdict) }
        if let holdSummary { lines.append(.status(holdSummary)) }
        if let labeledProtection { lines.append(.status(labeledProtection)) }
        if let headline { lines.append(.status(headline)) }
        else { lines += running.map { .status($0.text) } }
        return lines
    }
}
