import Foundation

/// Everything the app asks a restic engine to do, collected behind one line.
///
/// The live implementation is `ResticService` over the real binary. The model
/// and the views hold `any ResticClient`, never the concrete type, so the
/// engine can be swapped whole without touching anything above it. (The
/// engine tests substitute `MockResticClient`; `AppModel.service()` is the
/// one place production picks the concrete type.) Requirements carry no
/// default arguments (a protocol cannot), so calls through the existential
/// spell every parameter; the pure statics (`planTag`, `expandTilde`,
/// `countRemoved`) stay on `ResticService` — no state to abstract behind
/// a protocol.
protocol ResticClient: Sendable {
    // MARK: - Repository lifecycle

    func version() async throws -> String

    @discardableResult
    func initializeRepository(_ context: RepositoryContext) async throws -> String?

    func repositoryExists(_ context: RepositoryContext) async throws -> Bool

    func unlock(_ context: RepositoryContext) async throws

    /// `restic key passwd`: the repository opens with `newPassword` from
    /// now on, and no longer with the context's.
    func changePassword(_ context: RepositoryContext, newPassword: String) async throws

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
    /// Throws `ResticError.malformedOutput` after the stream when any line
    /// did not decode: such a stream is not the whole snapshot, whatever
    /// the exit code said.
    func walkSnapshot(
        _ context: RepositoryContext,
        snapshotID: String,
        onNode: @Sendable @escaping (SnapshotNode) -> Void
    ) async throws

    func find(
        _ context: RepositoryContext,
        patterns: [String],
        ignoreCase: Bool,
        snapshotIDs: [String]
    ) async throws -> [FindResult]

    func diff(
        _ context: RepositoryContext,
        olderID: String,
        newerID: String,
        includeMetadata: Bool
    ) async throws -> SnapshotDiff

    /// Streams every `message_type: change` line of a `restic diff` — the
    /// uncapped variant of `diff`: the index needs all changed paths, so
    /// nothing is limited or retained. Throws on lines that did not decode,
    /// as `walkSnapshot` does: a change the decoder dropped is one the
    /// caller never saw.
    func walkDiff(
        _ context: RepositoryContext,
        olderID: String,
        newerID: String,
        onChange: @Sendable @escaping (ResticDiffChange) -> Void
    ) async throws

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

    /// Several items sharing one folder of the backup, in one restic call;
    /// each lands in `destinationDirectory` as `restore` would put it.
    @discardableResult
    func restoreItems(
        _ context: RepositoryContext,
        snapshotID: String,
        parent: String,
        nodes: [SnapshotNode],
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
