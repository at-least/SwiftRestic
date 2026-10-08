import Foundation

// Shared scaffolding for the AppModel suites, stub and real restic alike.

/// Restores run as detached tasks with no `waitFor` API; watch the flag.
@MainActor
func waitUntilRestoreFinishes(in model: AppModel, within seconds: TimeInterval = 10) async {
    let deadline = Date.now.addingTimeInterval(seconds)
    while model.isRestoring, Date.now < deadline {
        try? await Task.sleep(for: .milliseconds(50))
    }
}
