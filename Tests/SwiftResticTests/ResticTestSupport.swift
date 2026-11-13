import Foundation

extension ResticService {
    /// Restores an entire snapshot, keeping the original directory layout below
    /// `destinationDirectory`. No production surface offers a whole-backup
    /// restore (the user's call, 2026-10-24: the tree's top rows are the
    /// backed-up folders, so selecting them restores everything) — the
    /// integration tests restore through it to check that a whole backup
    /// round-trips, so it lives here, not in the app.
    @discardableResult
    func restoreWholeSnapshot(
        _ context: RepositoryContext,
        snapshotID: String,
        destinationDirectory: URL,
        overwrite: RestoreOverwritePolicy,
        onProgress: (@Sendable (OperationProgress) -> Void)? = nil
    ) async throws -> ResticSummary? {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        return try await runRestore(
            context,
            arguments: [snapshotID, "--target", destinationDirectory.path] + overwrite.resticArguments,
            onProgress: onProgress
        )
    }
}

extension ResticBinary {
    /// An executable *file*. `FileManager.isExecutableFile` alone also accepts
    /// directories — 0755 has the execute bit — and spawning one fails later
    /// with an opaque launch error. No production caller since the bundled
    /// rclone left (2155f10); the test that pins it lives on here.
    static func isExecutableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}
