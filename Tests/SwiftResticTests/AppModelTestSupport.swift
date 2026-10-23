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
