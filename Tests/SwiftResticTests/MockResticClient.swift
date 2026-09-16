import Foundation

/// A scriptable `ResticClient` for engine-level tests: canned results and
/// faults, plus a call log. The `ResticClient` seam existed since 680696e but
/// nothing substituted for it — the stub binary covered everything at the
/// cost of a process per case. This covers sequencing and outcome mapping
/// in milliseconds; the stub-shell and real-restic suites stay the
/// integration layer.
final class MockResticClient: ResticClient, @unchecked Sendable {
    private let lock = NSLock()

    /// One canned answer per method; the last setter wins until replaced.
    private var backupScript: Result<BackupOutcome, Error> =
        .success(BackupOutcome(summary: nil, itemErrors: [], exitCode: 0))
    private var forgetScript: Result<Int, Error> = .success(0)
    private var checkScript: Result<ResticSummary?, Error> = .success(nil)
    private var pruneScript: Result<String, Error> = .success("")
    private var snapshotsScript: Result<[Snapshot], Error> = .success([])
    private var statsScript: Result<RepositoryStats, Error> =
        .success(RepositoryStats(totalSize: 0))

    /// Order of arrival across every method, for sequencing assertions.
    private var log: [String] = []

    /// All lock use lives in synchronous helpers: `NSLock` is unavailable in
    /// async contexts, and every `ResticClient` method is async.
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func onBackup(_ result: Result<BackupOutcome, Error>) -> Self {
        locked { backupScript = result }
        return self
    }

    func onForget(_ result: Result<Int, Error>) -> Self {
        locked { forgetScript = result }
        return self
    }

    func onCheck(_ result: Result<ResticSummary?, Error>) -> Self {
        locked { checkScript = result }
        return self
    }

    func onPrune(_ result: Result<String, Error>) -> Self {
        locked { pruneScript = result }
        return self
    }

    private func record(_ name: String) {
        locked { log.append(name) }
    }

    var callLog: [String] { locked { log } }

    // MARK: - ResticClient

    func version() async throws -> String {
        record("version")
        return "restic 0.0.0-mock"
    }

    func initializeRepository(_ context: RepositoryContext) async throws -> String? {
        record("init")
        return nil
    }

    func repositoryExists(_ context: RepositoryContext) async throws -> Bool {
        record("exists")
        return true
    }

    func unlock(_ context: RepositoryContext) async throws {
        record("unlock")
    }

    func stats(_ context: RepositoryContext, timeout: TimeInterval?) async throws -> RepositoryStats {
        record("stats")
        return try locked { statsScript }.get()
    }

    func check(
        _ context: RepositoryContext,
        readDataSubsetPercent: Int?
    ) async throws -> ResticSummary? {
        record("check")
        return try locked { checkScript }.get()
    }

    func prune(
        _ context: RepositoryContext,
        dryRun: Bool,
        onRawLine: (@Sendable (String) -> Void)?
    ) async throws -> String {
        record("prune")
        return try locked { pruneScript }.get()
    }

    func runRaw(_ context: RepositoryContext, arguments: [String]) async throws -> String {
        record("raw:\(arguments.first ?? "")")
        return ""
    }

    func snapshots(
        _ context: RepositoryContext,
        planID: UUID?,
        timeout: TimeInterval?
    ) async throws -> [Snapshot] {
        record("snapshots")
        return try locked { snapshotsScript }.get()
    }

    func listDirectory(
        _ context: RepositoryContext,
        snapshotID: String,
        path: String
    ) async throws -> [SnapshotNode] {
        record("ls")
        return []
    }

    func walkSnapshot(
        _ context: RepositoryContext,
        snapshotID: String,
        onNode: @Sendable @escaping (SnapshotNode) -> Void
    ) async throws {
        record("walk")
    }

    func find(
        _ context: RepositoryContext,
        pattern: String,
        ignoreCase: Bool,
        snapshotID: String?
    ) async throws -> [FindResult] {
        record("find")
        return []
    }

    func diff(
        _ context: RepositoryContext,
        olderID: String,
        newerID: String,
        includeMetadata: Bool
    ) async throws -> SnapshotDiff {
        record("diff")
        return SnapshotDiff(olderID: olderID, newerID: newerID)
    }

    func walkDiff(
        _ context: RepositoryContext,
        olderID: String,
        newerID: String,
        onChange: @Sendable @escaping (ResticDiffChange) -> Void
    ) async throws {
        record("walkDiff")
    }

    func backup(
        _ context: RepositoryContext,
        plan: BackupPlan,
        onProgress: (@Sendable (OperationProgress) -> Void)?
    ) async throws -> BackupOutcome {
        record("backup")
        onProgress?(OperationProgress())
        return try locked { backupScript }.get()
    }

    func forget(_ context: RepositoryContext, plan: BackupPlan) async throws -> Int {
        record("forget")
        return try locked { forgetScript }.get()
    }

    func restore(
        _ context: RepositoryContext,
        snapshotID: String,
        node: SnapshotNode,
        destinationDirectory: URL,
        onProgress: (@Sendable (OperationProgress) -> Void)?
    ) async throws -> ResticSummary? {
        record("restore")
        return nil
    }

    func restoreWholeSnapshot(
        _ context: RepositoryContext,
        snapshotID: String,
        destinationDirectory: URL,
        onProgress: (@Sendable (OperationProgress) -> Void)?
    ) async throws -> ResticSummary? {
        record("restoreWhole")
        return nil
    }
}
