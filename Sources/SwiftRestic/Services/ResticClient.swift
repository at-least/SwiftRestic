import Foundation

/// Everything the app asks a restic engine to do, collected behind one line.
///
/// The live implementation is `ResticService` over the real binary. The model
/// and the views hold `any ResticClient`, never the concrete type, so the
/// engine can be swapped whole — another platform's client reusing this
/// protocol, an in-process engine — without touching anything above it.
/// (Nothing substitutes for it today: `AppModel.service()` is the one place
/// the concrete type is chosen, and that is where a replacement would plug
/// in.) Requirements carry no default arguments (a protocol cannot), so calls
/// through the existential spell every parameter; the pure statics (`planTag`,
/// `expandTilde`, `countRemoved`) stay on `ResticService`, with no state to
/// abstract behind a protocol.
protocol ResticClient: Sendable {
    // MARK: - Repository lifecycle

    func version() async throws -> String

    @discardableResult
    func initializeRepository(_ context: RepositoryContext) async throws -> String?

    func repositoryExists(_ context: RepositoryContext) async throws -> Bool

    func unlock(_ context: RepositoryContext) async throws

    func stats(_ context: RepositoryContext, timeout: TimeInterval?) async throws -> RepositoryStats

    func check(_ context: RepositoryContext, readDataSubsetPercent: Int?) async throws -> ResticSummary?

    func prune(
        _ context: RepositoryContext,
        dryRun: Bool,
        onRawLine: (@Sendable (String) -> Void)?
    ) async throws -> String

    /// Any exit code is returned rather than thrown: the console shows
    /// whatever restic said, including its complaints.
    func runRaw(_ context: RepositoryContext, arguments: [String]) async throws -> String

    // MARK: - Snapshots

    func snapshots(
        _ context: RepositoryContext,
        planID: UUID?,
        timeout: TimeInterval?
    ) async throws -> [Snapshot]

    func listDirectory(
        _ context: RepositoryContext,
        snapshotID: String,
        path: String
    ) async throws -> [SnapshotNode]

    /// Streams every node of one snapshot — the unbounded full-tree
    /// `restic ls <id>`. One callback per node as it arrives, off the main
    /// actor; callers must consume incrementally, never retain wholesale.
    /// Returns how many lines restic wrote that did not decode: a stream
    /// with any is not the whole snapshot, whatever the exit code said.
    @discardableResult
    func walkSnapshot(
        _ context: RepositoryContext,
        snapshotID: String,
        onNode: @Sendable @escaping (SnapshotNode) -> Void
    ) async throws -> Int

    func find(
        _ context: RepositoryContext,
        pattern: String,
        ignoreCase: Bool,
        snapshotID: String?
    ) async throws -> [FindResult]

    func diff(
        _ context: RepositoryContext,
        olderID: String,
        newerID: String,
        includeMetadata: Bool
    ) async throws -> SnapshotDiff

    /// Streams every `message_type: change` line of a `restic diff` — the
    /// uncapped variant of `diff`: the index needs all changed paths, so
    /// there is no change limit and nothing is retained. Returns how many
    /// lines did not decode, as `walkSnapshot` does: a change the decoder
    /// dropped is a change the caller never saw.
    @discardableResult
    func walkDiff(
        _ context: RepositoryContext,
        olderID: String,
        newerID: String,
        onChange: @Sendable @escaping (ResticDiffChange) -> Void
    ) async throws -> Int

    // MARK: - Backup

    func backup(
        _ context: RepositoryContext,
        plan: BackupPlan,
        onProgress: (@Sendable (OperationProgress) -> Void)?
    ) async throws -> BackupOutcome

    @discardableResult
    func forget(_ context: RepositoryContext, plan: BackupPlan) async throws -> Int

    /// `forget --dry-run --no-lock` with the same rules: what `forget` would
    /// remove, read without a lock.
    func forgetPreview(_ context: RepositoryContext, plan: BackupPlan) async throws -> RetentionPreview

    // MARK: - Restore

    /// `overwrite` has no default, here or below: every caller states what
    /// happens to a file already at the destination.
    @discardableResult
    func restore(
        _ context: RepositoryContext,
        snapshotID: String,
        node: SnapshotNode,
        destinationDirectory: URL,
        overwrite: RestoreOverwritePolicy,
        onProgress: (@Sendable (OperationProgress) -> Void)?
    ) async throws -> ResticSummary?

    @discardableResult
    func restoreWholeSnapshot(
        _ context: RepositoryContext,
        snapshotID: String,
        destinationDirectory: URL,
        overwrite: RestoreOverwritePolicy,
        onProgress: (@Sendable (OperationProgress) -> Void)?
    ) async throws -> ResticSummary?
}
