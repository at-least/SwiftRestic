import Foundation

extension ResticService {
    /// Keeps the original directory layout below `destinationDirectory`. No
    /// production surface offers a whole-backup restore (user decision: the
    /// tree's top rows are the backed-up folders, so selecting them restores
    /// everything); integration tests use this to check a whole backup
    /// round-trips.
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
    /// with an opaque launch error.
    static func isExecutableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}
