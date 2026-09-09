import Foundation

/// The menu bar's headline, derived from observable state.
///
/// Pure and view-free so the idle → running → finished transitions can be
/// tested by handing it snapshots of the model's state, the way backrest tests
/// its tray icon by appending operations one at a time.
enum MenuBarStatus {
    /// The three faces the menu bar icon can wear. Running beats problem: while
    /// work is in flight the icon says so, and the menu's problem line carries
    /// the news — an animated-then-failing glyph would flicker between the two
    /// on every run that follows a failure.
    enum IconState: Equatable {
        case idle
        case running
        case problem
    }

    /// Which face the icon wears right now. Every kind of restic work counts
    /// as running — the menu bar is the only surface that exists when the
    /// window is closed, so a restore or a prune invisible there is invisible
    /// everywhere. Problems are the same seven-day window `problemLine` uses.
    static func iconState(
        activity: [UUID: PlanActivity],
        maintenance: [UUID: MaintenanceActivity],
        isRestoring: Bool,
        isConsoleRunning: Bool,
        runs: [RunRecord],
        now: Date = .now
    ) -> IconState {
        let isRunning = !activity.isEmpty || !maintenance.isEmpty || isRestoring || isConsoleRunning
        if isRunning { return .running }
        return problemLine(runs: runs, now: now) == nil ? .idle : .problem
    }

    /// The icon glyph for a state, and what VoiceOver calls it.
    static func symbolName(for state: IconState) -> String {
        switch state {
        case .idle: "clock.arrow.circlepath"
        case .running: "arrow.triangle.2.circlepath"
        case .problem: "exclamationmark.triangle"
        }
    }

    static func accessibilityDescription(for state: IconState) -> String {
        switch state {
        case .idle: "SwiftRestic"
        case .running: "SwiftRestic, work in progress"
        case .problem: "SwiftRestic, a recent run had a problem"
        }
    }

    /// The newest problem in the run history as one sentence, or `nil` while
    /// the window is clean. Same seven-day window the dashboard's Problems
    /// tile counts: a failure older than that is old news, and leading with
    /// it forever would read as permanent breakage. Runs count from when they
    /// finished — a backup that ran all night and failed at dawn is the
    /// newest news, not the stalest.
    static func problemLine(
        runs: [RunRecord],
        now: Date = .now,
        relative: (Date) -> String = { Format.relative($0) }
    ) -> String? {
        let windowStart = now.addingTimeInterval(-7 * 86_400)
        let problems = runs.filter {
            $0.finishedAt >= windowStart
                && ($0.outcome == .failed || $0.outcome == .completedWithErrors)
        }
        guard let newest = problems.max(by: { $0.finishedAt < $1.finishedAt }) else { return nil }

        // A backup names its plan the way Activity does; a restore names what
        // it restored; check and prune name the repository, because "NAS
        // failed" would read as the NAS failing.
        let subject: String
        if newest.planName.isEmpty {
            subject = newest.kind.rawValue.capitalized
        } else {
            switch newest.kind {
            case .backup:
                subject = newest.planName
            case .restore:
                subject = "Restore of \(newest.planName)"
            case .check, .prune, .forget, .initialize:
                subject = "\(newest.kind.rawValue.capitalized) on \(newest.planName)"
            }
        }
        let verb = newest.outcome == .failed ? "failed" : "finished with errors"
        return "\(subject) \(verb) \(relative(newest.finishedAt))"
    }

    /// The single line above the plan buttons. `nil` while anything is running:
    /// the running lines replace it rather than sitting underneath. Restores
    /// and repository upkeep count as running — a "Next: Nightly" headline
    /// over a running restore reads as if the restore is not happening.
    static func headline(
        activity: [UUID: PlanActivity],
        maintenance: [UUID: MaintenanceActivity] = [:],
        isRestoring: Bool = false,
        isConsoleRunning: Bool = false,
        nextRun: (plan: BackupPlan, date: Date)?
    ) -> String? {
        guard activity.isEmpty, maintenance.isEmpty, !isRestoring, !isConsoleRunning else { return nil }
        guard let nextRun else { return "No backups scheduled" }
        return "Next: \(nextRun.plan.name) \(Format.relative(nextRun.date))"
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
        activity: [UUID: PlanActivity]
    ) -> [RunningLine] {
        plans.filter { activity[$0.id] != nil }.map {
            RunningLine(id: $0.id.uuidString, text: "\($0.name) — \(progressText(activity[$0.id]))")
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

    /// A console command in flight. Short commands never render it long enough
    /// to matter; a long `prune` typed there deserves the same visibility as
    /// any other restic work.
    static func consoleLine(isRunning: Bool) -> RunningLine? {
        guard isRunning else { return nil }
        return RunningLine(id: "console", text: "Console — command running")
    }

    /// Progress as the menu bar shows it: a percentage once restic is streaming
    /// status, the phase's name before that.
    static func progressText(_ activity: PlanActivity?) -> String {
        guard let activity else { return "…" }
        guard activity.phase == .backingUp else { return activity.phase.displayName }
        return activity.progress.fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}
