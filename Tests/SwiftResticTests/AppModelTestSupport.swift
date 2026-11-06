import Foundation
import Testing

/// Restores run as detached tasks with no `waitFor` API; watch the flag.
/// A restore still running at the deadline is an issue of its own, so the
/// caller's checks never read a run that has not ended.
@MainActor
func waitUntilRestoreFinishes(in model: AppModel, within seconds: TimeInterval = 60) async {
    let deadline = Date.now.addingTimeInterval(seconds)
    while model.isRestoring, Date.now < deadline {
        try? await Task.sleep(for: .milliseconds(50))
    }
    if model.isRestoring {
        Issue.record("the restore was still running after \(Int(seconds)) s")
    }
}

extension AppModel {
    var holdsOffSleep: Bool { sleepActivity != nil }

    func waitForRun(planID: UUID) async {
        await tasks.task(in: .plan(planID))?.value
    }

    func waitForMaintenance(repositoryID: UUID) async {
        await tasks.task(in: .maintenance(repositoryID))?.value
    }
}

extension BackupPlan {
    /// So a fixture's tree is backed up as planted, but for the rules every
    /// plan passes.
    mutating func skipNothing() {
        excludePatterns = []
        skipsDeveloperFiles = false
        skipsMachines = false
    }
}
