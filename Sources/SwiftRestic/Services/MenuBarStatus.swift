import Foundation

/// The menu bar's headline, derived from observable state.
enum MenuBarStatus {
    /// Problem beats running: the icon answers "am I safe?" first, and a
    /// failure stays one steady face until a success heals it. A plan's own
    /// run does not count against it, so a first backup pulses. Unconfigured
    /// beats problem: run history outlives removed repositories, so the icon
    /// must not ask for setup over a line announcing an old failure.
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
        rows: [UpToDateRow] = [],
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

    /// `attentionLogo` is Time Machine's menu bar sign for a backup that
    /// needs the user. An empty install wears the plain mark: an attention
    /// mark before setup has begun would read as a failure that has not
    /// happened; the menu's first line says what to set up.
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

    static func accessibilityDescription(
        for state: IconState,
        hold: ScheduleHold? = nil,
        isResticDamaged: Bool = false,
        isWorking: Bool = false
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
            let summary = hold.summary()
            clauses.append(summary.prefix(1).lowercased() + summary.dropFirst())
        }
        if isResticDamaged { clauses.append(ResticError.damagedInstall.localizedDescription) }
        guard !clauses.isEmpty else { return base }
        let separator = state == .idle ? ", " : "; "
        return base + clauses.map { separator + $0 }.joined()
    }

    /// The running face wins over the dimmed one: work in flight is the
    /// news, and a run the user started by hand ignores the hold.
    static func appearsHeld(state: IconState, hold: ScheduleHold?) -> Bool {
        hold != nil && state != .running
    }

    static func newestStandingProblem(runs: [RunRecord], now: Date = .now) -> RunRecord? {
        OverviewMetrics.problems(in: runs, since: OverviewMetrics.problemWindowStart(from: now))
            .filter { !OverviewMetrics.isHealed($0, in: runs) }
            .max { $0.finishedAt < $1.finishedAt }
    }

    /// Drops the failures a later successful backup of the same plan healed
    /// (`OverviewMetrics.isHealed`, the sidebar's rule): this line leads the
    /// user in, and leading with an old failure forever would read as
    /// permanent breakage. Yields to `hasNoRepositories`, so the
    /// `unconfigured` state is never answered with a removed repository's
    /// failure.
    static func problemLine(
        runs: [RunRecord],
        hasNoRepositories: Bool,
        plans: [BackupPlan] = [],
        repositories: [Repository] = [],
        relative: (Date) -> String = { Format.relative($0) }
    ) -> String? {
        guard !hasNoRepositories else { return nil }
        guard let newest = newestStandingProblem(runs: runs) else { return nil }

        // A check or prune names the repository alone, with its kind first:
        // "NAS failed" would read as the NAS failing.
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
            case .check, .prune:
                subject = "\(newest.kind.displayName) on \(name)"
            }
        }
        // The outcome's own words, as the sidebar, plan page and Activity say
        // it: "NAS failed …", "Photos: some files skipped …".
        let outcome = newest.outcomeName.lowercased()
        let verdict = newest.outcome == .failed ? " \(outcome)" : ": \(outcome)"
        return "\(subject)\(verdict) \(relative(newest.finishedAt))"
    }

    /// `nil` while anything runs: the running lines replace it. Console work
    /// has no running line, so it does not hold the headline back. `nil`
    /// under a hold or while restic is damaged: their own line leads the
    /// menu, and a next-run headline would announce a run the scheduler will
    /// not fire. The plan is named with its repository: two repositories can
    /// hold same-named plans.
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
        if hasNoRepositories { return BackupPlan.noBackupLocationReason }
        guard let nextRun else { return "No backups scheduled" }
        // The plan page's Next backup tile spells the same moment in these
        // words; the scheduler clamps the date to now, so a due run reads
        // "Due now".
        return "Next: " + RunRecordPresentation.nextRunLine(
            plan: nextRun.plan, date: nextRun.date, plans: plans, repositories: repositories
        )
    }

    /// Stop while the plan runs: the tray is the only surface once the
    /// window is closed, so a running backup must keep a working Stop there.
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
                // Disabled while the repository is locked exclusively, as every
                // Back Up Now is: restic would refuse at once.
                let lockReason = plan.repositoryID.flatMap { lockedRepositories[$0] }
                return PlanRow(
                    planID: plan.id,
                    title: "Back Up “\(name)” Now",
                    action: .backUp,
                    isEnabled: plan.isConfigurationComplete && !isResticDamaged && lockReason == nil,
                    // The Backup menu's own words for each reason.
                    disabledReason: !plan.isConfigurationComplete ? BackupPlan.incompleteConfigurationReason
                        : isResticDamaged ? ResticError.damagedInstall.localizedDescription : lockReason
                )
            case .cancelling?:
                return PlanRow(planID: plan.id, title: "Stopping “\(name)”…", action: .none, isEnabled: false)
            case let phase?:
                // No percentage: restic's measure is reading, not uploading, and
                // "Stop (100%)" would make stopping look free. The running line
                // above keeps restic's figure.
                return PlanRow(planID: plan.id, title: stopTitle(for: phase, planName: name), action: .stop, isEnabled: true)
            }
        }
    }

    /// A backup's own retention step, whose snapshot is already written, is
    /// no backup, so its Stop says what it stops. The tray's row passes
    /// `planName`.
    static func stopTitle(for phase: PlanActivity.Phase?, planName: String? = nil) -> String {
        let quoted = planName.map { "“\($0)”" }
        switch phase {
        case .applyingRetention?: return quoted.map { "Stop Removing Old Backups of \($0)" } ?? "Stop Removing Old Backups"
        default: return quoted.map { "Stop \($0) Backup" } ?? "Stop Backup"
        }
    }

    /// One group per repository: a flat list could not tell two
    /// repositories' same-named plans apart. Removing a repository removes
    /// its plans, so no plan is left without a group.
    struct PlanGroup: Equatable {
        var repositoryID: UUID
        var title: String
        /// The repository page's Status line, so the tray answers "did my
        /// backups run?" with the window closed. Nil until the listing has
        /// loaded.
        var protection: String?
        var rows: [PlanRow]
        /// One plan's failure must not hide another's.
        var newsLines: [String] = []

        /// The Status line where no submenu title names the repository.
        var labeledStatus: String? {
            protection.map { "\(title) — \($0)" }
        }
    }

    /// A single repository's rows sit in the menu itself, a hover closer
    /// (the user's call).
    static func showsGroupsAsSubmenus(_ groups: [PlanGroup]) -> Bool {
        groups.count > 1
    }

    /// A standing problem only, in the sidebar caption's words: success is
    /// quiet, and a running plan's line already leads the menu. The menu's
    /// top problem line repeats the newest problem on purpose: a submenu
    /// opened by hover must read on its own.
    static func newsLines(
        for plan: BackupPlan,
        among plans: [BackupPlan],
        activity: PlanActivity?,
        problem: RunRecord?,
        now: Date,
        relative: (Date) -> String = { Format.relative($0) }
    ) -> [String] {
        guard activity == nil else { return [] }
        guard problem != nil, let caption = PlanStatus.sidebarCaption(
            for: plan,
            activity: nil,
            problem: problem,
            existingRepositoryIDs: [],
            now: now,
            relative: relative
        ) else { return [] }
        return ["\(plan.label(among: plans)): \(caption.text)"]
    }

    static func planGroups(
        plans: [BackupPlan],
        repositories: [Repository],
        activity: [UUID: PlanActivity],
        isResticDamaged: Bool,
        lockedRepositories: [UUID: String] = [:],
        problem: (UUID) -> RunRecord? = { _ in nil },
        protection: (UUID) -> UpToDateSummary? = { _ in nil },
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

    /// Plans, upkeep, restore, in that order: the menu reads top-down from
    /// the plan the user most likely came for. `id` is stable because two
    /// lines can share a text, and a `ForEach` over bare strings would
    /// collide.
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
            // Two same-named plans can run at once.
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

    /// There is at most one restore.
    static func restoreLine(progress: OperationProgress?) -> RunningLine? {
        guard let progress else { return nil }
        let percent = Format.percent(progress.fraction)
        return RunningLine(id: "restore", text: "Restoring — \(percent)")
    }

    /// A percentage once restic streams status, the phase's name before
    /// that. Progress arrives beside the activity, not inside it.
    static func progressText(activity: PlanActivity?, progress: OperationProgress?) -> String {
        guard let activity else { return "…" }
        guard activity.phase == .backingUp else { return activity.phase.displayName }
        return Format.percent(progress?.fraction ?? 0)
    }

    /// Leads the tray's menu, before the repository rows.
    enum TrayLine: Equatable {
        case status(String)
        /// The menu's one line that goes somewhere (Show in Activity), so it
        /// carries the run it names.
        case problem(text: String, runID: UUID)
    }

    /// "Am I safe?" in one line. Nil while no plan can be vouched for (a
    /// listing still loading, a first backup running) and while nothing is
    /// set up, where the headline says what to do.
    static func verdict(
        rows: [UpToDateRow],
        isResticDamaged: Bool,
        hasNoRepositories: Bool,
        problemLine: String?,
        problemID: UUID?
    ) -> TrayLine? {
        if isResticDamaged { return .status(ResticError.damagedInstall.localizedDescription) }
        guard !hasNoRepositories else { return nil }
        if let problemLine, let problemID { return .problem(text: problemLine, runID: problemID) }
        if let worst = OverviewMetrics.needingAttention(rows).first {
            return .status("\(worst.planName): \(worst.stateText)")
        }
        guard !rows.isEmpty, rows.allSatisfy(\.isUpToDate) else { return nil }
        return .status(allUpToDateLine)
    }

    static let allUpToDateLine = "All plans up to date"

    /// In the order a menu open reads them; the running lines replace the
    /// idle headline.
    static func trayLines(
        verdict: TrayLine?,
        holdSummary: String?,
        labeledStatus: String?,
        headline: String?,
        running: [RunningLine]
    ) -> [TrayLine] {
        var lines: [TrayLine] = []
        if let verdict { lines.append(verdict) }
        if let holdSummary { lines.append(.status(holdSummary)) }
        if let labeledStatus { lines.append(.status(labeledStatus)) }
        if let headline { lines.append(.status(headline)) }
        else { lines += running.map { .status($0.text) } }
        return lines
    }
}
