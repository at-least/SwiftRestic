import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// Identifier of the main `WindowGroup`, so the window can be brought back
    /// after the user closed it — with a menu bar item the app is still running.
    let mainWindowID: String

    var body: some View {
        if let headline = MenuBarStatus.headline(activity: model.activity, nextRun: model.nextScheduledRun) {
            Text(headline)
        } else {
            ForEach(
                MenuBarStatus.runningLines(plans: model.configuration.plans, activity: model.activity),
                id: \.self
            ) { line in
                Text(line)
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

    private func planLabel(_ plan: BackupPlan) -> String {
        let name = plan.name.isEmpty ? "Untitled Plan" : plan.name
        return "Back Up “\(name)” Now"
    }
}
