import Foundation

/// The menu bar's headline, derived from observable state.
///
/// Pure and view-free so the idle → running → finished transitions can be
/// tested by handing it snapshots of the model's state, the way backrest tests
/// its tray icon by appending operations one at a time.
enum MenuBarStatus {
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
    static func runningLines(
        plans: [BackupPlan],
        activity: [UUID: PlanActivity]
    ) -> [String] {
        plans.filter { activity[$0.id] != nil }.map { "\($0.name) — \(progressText(activity[$0.id]))" }
    }

    /// Progress as the menu bar shows it: a percentage once restic is streaming
    /// status, the phase's name before that.
    static func progressText(_ activity: PlanActivity?) -> String {
        guard let activity else { return "…" }
        guard activity.phase == .backingUp else { return activity.phase.displayName }
        return activity.progress.fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}
