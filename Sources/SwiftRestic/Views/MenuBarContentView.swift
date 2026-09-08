import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// Identifier of the main `Window` scene, so the window can be brought back
    /// after the user closed it — the app keeps running either way; this is the
    /// way back into its UI.
    let mainWindowID: String

    var body: some View {
        // The failure line leads: the menu's first job is answering "did the
        // last run succeed?" before it answers "what happens next?".
        if let problem = MenuBarStatus.problemLine(runs: model.configuration.runs) {
            Text(problem)
        }
        if let headline = MenuBarStatus.headline(activity: model.activity, nextRun: model.nextScheduledRun) {
            Text(headline)
        } else {
            ForEach(MenuBarStatus.runningLines(plans: model.configuration.plans, activity: model.activity)) { line in
                Text(line.text)
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
