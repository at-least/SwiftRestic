import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// Identifier of the main `WindowGroup`, so the window can be brought back
    /// after the user closed it — with a menu bar item the app is still running.
    let mainWindowID: String

    var body: some View {
        if model.activity.isEmpty {
            if let next = model.nextScheduledRun {
                Text("Next: \(next.plan.name) \(Format.relative(next.date))")
            } else {
                Text("No backups scheduled")
            }
        } else {
            ForEach(runningPlans, id: \.id) { plan in
                let activity = model.activity[plan.id]
                Text("\(plan.name) — \(percent(activity))")
            }
        }

        Divider()

        ForEach(model.configuration.plans) { plan in
            Button(planLabel(plan)) { model.runBackup(planID: plan.id) }
                .disabled(model.isRunning(planID: plan.id) || !plan.isConfigurationComplete)
        }

        Divider()

        Button("Open SwiftRestic") {
            // `NSApp.windows` is empty once the main window has been closed, so
            // reopening has to go through the scene's identifier.
            openWindow(id: mainWindowID)
            NSApp.activate(ignoringOtherApps: true)
        }
        // Terminating goes through the app delegate, which flushes pending saves
        // and stops any running restic first.
        Button("Quit SwiftRestic") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var runningPlans: [BackupPlan] {
        model.configuration.plans.filter { model.activity[$0.id] != nil }
    }

    private func planLabel(_ plan: BackupPlan) -> String {
        let name = plan.name.isEmpty ? "Untitled Plan" : plan.name
        return "Back Up “\(name)” Now"
    }

    private func percent(_ activity: PlanActivity?) -> String {
        guard let activity else { return "…" }
        guard activity.phase == .backingUp else { return activity.phase.displayName }
        return activity.progress.fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}
