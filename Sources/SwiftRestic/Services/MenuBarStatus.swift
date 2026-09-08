import Foundation

/// The menu bar's headline, derived from observable state.
///
/// Pure and view-free so the idle → running → finished transitions can be
/// tested by handing it snapshots of the model's state, the way backrest tests
/// its tray icon by appending operations one at a time.
enum MenuBarStatus {
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
    /// the running lines replace it rather than sitting underneath.
    static func headline(
        activity: [UUID: PlanActivity],
        nextRun: (plan: BackupPlan, date: Date)?
    ) -> String? {
        guard activity.isEmpty else { return nil }
        guard let nextRun else { return "No backups scheduled" }
        return "Next: \(nextRun.plan.name) \(Format.relative(nextRun.date))"
    }

    /// One line per plan that is currently running, in configuration order.
    /// Identified by plan ID: two plans can share a name, and a `ForEach` over
    /// bare strings would collide.
    struct RunningLine: Equatable, Identifiable {
        var planID: UUID
        var text: String
        var id: UUID { planID }
    }

    static func runningLines(
        plans: [BackupPlan],
        activity: [UUID: PlanActivity]
    ) -> [RunningLine] {
        plans.filter { activity[$0.id] != nil }.map {
            RunningLine(planID: $0.id, text: "\($0.name) — \(progressText(activity[$0.id]))")
        }
    }

    /// Progress as the menu bar shows it: a percentage once restic is streaming
    /// status, the phase's name before that.
    static func progressText(_ activity: PlanActivity?) -> String {
        guard let activity else { return "…" }
        guard activity.phase == .backingUp else { return activity.phase.displayName }
        return activity.progress.fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}
