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

    // MARK: - Backup

    func backup(
        _ context: RepositoryContext,
        plan: BackupPlan,
        onProgress: (@Sendable (OperationProgress) -> Void)?
    ) async throws -> BackupOutcome

    @discardableResult
    func forget(_ context: RepositoryContext, plan: BackupPlan) async throws -> Int

    // MARK: - Restore

    @discardableResult
    func restore(
        _ context: RepositoryContext,
        snapshotID: String,
        node: SnapshotNode,
        destinationDirectory: URL,
        onProgress: (@Sendable (OperationProgress) -> Void)?
    ) async throws -> ResticSummary?

    @discardableResult
    func restoreWholeSnapshot(
        _ context: RepositoryContext,
        snapshotID: String,
        destinationDirectory: URL,
        onProgress: (@Sendable (OperationProgress) -> Void)?
    ) async throws -> ResticSummary?
}
