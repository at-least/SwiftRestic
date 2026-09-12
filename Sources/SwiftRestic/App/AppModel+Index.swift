import Foundation

extension AppModel {
    /// Hands a freshly loaded listing to the index and keeps its backfill
    /// moving. Everything here is best-effort: the index is a cache whose
    /// failure never fails the refresh that fed it — the coordinator records
    /// the error and the app reads snapshots through restic as before.
    ///
    /// This is also how a fresh backup reaches the index: the backup flow's
    /// closing refresh lands here, after retention has released the
    /// repository's exclusive lock, and the backfill loop picks the cheap
    /// diff route or the full read per snapshot.
    func indexReconcile(repositoryID: UUID, listing: [Snapshot]) {
        Task {
            await indexCoordinator.reconcile(repositoryID: repositoryID, snapshots: listing)
            // Backfill needs the repository and its credentials; if either is
            // gone mid-refresh, the next refresh retries the whole pass.
            guard let repository = repository(id: repositoryID),
                  let service = try? service(),
                  let context = try? await context(for: repository)
            else { return }
            await indexCoordinator.startBackfill(repositoryID: repositoryID, service: service, context: context)
        }
    }
}
