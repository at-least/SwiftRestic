import Foundation
import Testing

// Shared scaffolding for the AppModel suites, stub and real restic alike.

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

/// Time Machine's preferences as a scratch file at `file`.
func writeTimeMachinePreferences(_ contents: Any, to file: URL) throws {
    try PropertyListSerialization.data(fromPropertyList: contents, format: .binary, options: 0).write(to: file)
}

extension AppModel {
    /// Whether the Mac is kept from idle sleep for running work.
    var holdsOffSleep: Bool { sleepActivity != nil }

    /// Waits for a plan's in-flight run to finish, if there is one.
    func waitForRun(planID: UUID) async {
        await tasks.task(in: .plan(planID))?.value
    }

    /// Waits for a repository's in-flight upkeep to finish, if there is one.
    func waitForMaintenance(repositoryID: UUID) async {
        await tasks.task(in: .maintenance(repositoryID))?.value
    }
}

extension BackupPlan {
    /// A plan that leaves nothing out by pattern: no switch's rules, no
    /// marker, no pattern of its own — so a fixture's tree is backed up as
    /// planted.
    mutating func skipNothing() {
        excludePatterns = []
        skipsFinderFiles = false
        skipsSystemFiles = false
        developerGroups = []
        skipsTimeMachineExclusions = false
    }
}
