import Foundation

/// A scriptable `ResticClient` for engine-level tests: canned results and
/// faults, plus a call log. Covers sequencing and outcome mapping in
/// milliseconds, where the stub binary costs a process per case; the
/// stub-shell and real-restic suites stay the integration layer.
final class MockResticClient: ResticClient, @unchecked Sendable {
    private let lock = NSLock()

    /// One canned answer per method; the last setter wins until replaced.
    private var backupScript: Result<BackupOutcome, Error> =
        .success(BackupOutcome(summary: nil, itemErrors: [], exitCode: 0))
    private var forgetScript: Result<Int, Error> = .success(0)
    private var forgetPreviewScript: Result<RetentionPreview, Error> =
        .success(RetentionPreview(kept: [], removed: []))
    private var checkScript: Result<ResticSummary?, Error> = .success(nil)
    private var pruneScript: Result<String, Error> = .success("")
    private var snapshotsScript: Result<[Snapshot], Error> = .success([])
    private var statsScript: Result<RepositoryStats, Error> =
        .success(RepositoryStats(totalSize: 0))

    /// Order of arrival across every method, for sequencing assertions.
    private var log: [String] = []
    /// Whether a run's transcript was bound when each transcribed method
    /// ran — the engines bind one around restic calls only.
    private var bound: [String: Bool] = [:]
    /// The exit code each method writes into a bound transcript, standing in
    /// for the runner, which is what records exits for real.
    private var exits: [String: Int32] = [:]

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

    func onForgetPreview(_ result: Result<RetentionPreview, Error>) -> Self {
        locked { forgetPreviewScript = result }
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

    /// Scripts the exit code `method` leaves in the run's transcript.
    func onExit(_ method: String, _ code: Int32) -> Self {
        locked { exits[method] = code }
        return self
    }

    private func record(_ name: String) {
        locked { log.append(name) }
    }

    // MARK: - Index streams

    /// The index backfill's two streams, scripted per snapshot ID: what
    /// `ls` lists, which snapshots restic cannot read (both streams fail
    /// for them), which walks hang until cancelled, and how often each
    /// snapshot was walked.
    private var listings: [String: [SnapshotNode]] = [:]
    private var unreadableIDs: Set<String> = []
    private var hangingIDs: Set<String> = []
    private var walks: [String: Int] = [:]
    private var diffWalks: [String: Int] = [:]
    private var malformedLines: [String: Int] = [:]
    private var scriptedDiffs: [String: [ResticDiffChange]] = [:]
    private var walkStartHook: (@Sendable (String) async -> Void)?

    /// Each snapshot's `ls`: path → isDirectory, streamed in restic's order
    /// (`IndexTestData.ls`: depth-first, siblings by their bytes), which is
    /// the order the index's streaming ingest meets for real. Ancestors are
    /// not added; list them explicitly, as restic does.
    func onListings(_ contents: [String: [String: Bool]]) -> Self {
        locked {
            for (id, content) in contents {
                listings[id] = IndexTestData.ls(content).map { entry in
                    SnapshotNode(
                        name: ResticPath.basename(of: entry.path),
                        type: entry.isDirectory ? .dir : .file,
                        path: entry.path,
                        size: entry.isDirectory ? nil : 1,
                        mtime: nil
                    )
                }
            }
        }
        return self
    }

    /// Snapshots whose `ls` and `diff` fail as restic would on a pack it
    /// cannot read.
    func onUnreadable(_ ids: Set<String>) -> Self {
        locked { unreadableIDs = ids }
        return self
    }

    /// Snapshots whose `ls` streams nothing and never ends until the task
    /// is cancelled — then fails as the runner does, with `cancelled`.
    func onHangingWalks(_ ids: Set<String>) -> Self {
        locked { hangingIDs = ids }
        return self
    }

    /// Lines that did not decode in the `ls` of that snapshot and in every
    /// `diff` that targets it: the walk streams what it has, then throws as
    /// `ResticService` does.
    func onMalformed(_ counts: [String: Int]) -> Self {
        locked { malformedLines = counts }
        return self
    }

    /// Verbatim change lines for the `diff` that targets a snapshot, in
    /// place of the computed set-difference — for spellings the computed
    /// diff never produces, such as a kind change written as a bare add.
    func onDiffLines(_ lines: [String: [ResticDiffChange]]) -> Self {
        locked { scriptedDiffs = lines }
        return self
    }

    /// Runs at the start of every `ls`, after the index has begun that
    /// snapshot's stream — where a test lands a reconcile mid-stream.
    func onWalkStart(_ hook: @escaping @Sendable (String) async -> Void) -> Self {
        locked { walkStartHook = hook }
        return self
    }

    /// `ls` runs per snapshot ID.
    var walkCounts: [String: Int] { locked { walks } }
    /// `diff` runs per target snapshot ID.
    var diffCounts: [String: Int] { locked { diffWalks } }

    /// For the methods a run engine transcribes: notes whether a transcript
    /// was bound, and writes the scripted exit into it the way the runner
    /// would.
    private func transcribe(_ name: String) {
        let transcript = RunTranscript.current
        let code = locked {
            bound[name] = transcript != nil
            return exits[name]
        }
        if let code { transcript?.exited(code) }
    }

    var callLog: [String] { locked { log } }
    var transcriptBound: [String: Bool] { locked { bound } }

    // MARK: - ResticClient

    func version() async throws -> String {
        record("version")
        return "restic 0.0.0-mock"
    }

    func initializeRepository(_ context: RepositoryContext) async throws -> String? {
        record("init")
        return nil
    }

    func repositoryExists(_ context: RepositoryContext, timeout: TimeInterval?) async throws -> Bool {
        record("exists")
        return true
    }

    func unlock(_ context: RepositoryContext) async throws {
        record("unlock")
    }

    func changePassword(_ context: RepositoryContext, newPassword: String) async throws {
        record("changePassword")
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
        transcribe("check")
        return try locked { checkScript }.get()
    }

    func prune(
        _ context: RepositoryContext,
        dryRun: Bool,
        onRawLine: (@Sendable (String) -> Void)?
    ) async throws -> String {
        record("prune")
        transcribe("prune")
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
        let (nodes, unreadable, hangs, malformed, hook) = locked {
            walks[snapshotID, default: 0] += 1
            return (
                listings[snapshotID] ?? [], unreadableIDs.contains(snapshotID), hangingIDs.contains(snapshotID),
                malformedLines[snapshotID] ?? 0, walkStartHook
            )
        }
        await hook?(snapshotID)
        if hangs {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw ResticError.cancelled
        }
        if unreadable { throw Self.unreadableError(snapshotID) }
        for node in nodes { onNode(node) }
        try Self.requireWhole(malformed)
    }

    func find(
        _ context: RepositoryContext,
        patterns: [String],
        ignoreCase: Bool,
        snapshotIDs: [String]
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

    /// A complete set-difference in restic's spelling (a trailing `/` on
    /// directories), `+` for paths only in `newerID`; a path whose kind
    /// differs is one `T` line, as restic 0.19.1 writes it.
    func walkDiff(
        _ context: RepositoryContext,
        olderID: String,
        newerID: String,
        onChange: @Sendable @escaping (ResticDiffChange) -> Void
    ) async throws {
        record("walkDiff")
        let (base, target, unreadable, malformed, scripted) = locked {
            diffWalks[newerID, default: 0] += 1
            return (
                listings[olderID] ?? [],
                listings[newerID] ?? [],
                unreadableIDs.intersection([olderID, newerID]).first,
                malformedLines[newerID] ?? 0,
                scriptedDiffs[newerID]
            )
        }
        if let unreadable { throw Self.unreadableError(unreadable) }
        if let scripted {
            for change in scripted { onChange(change) }
            try Self.requireWhole(malformed)
            return
        }
        func spelled(_ node: SnapshotNode) -> String { IndexTestData.diffSpelling(node.path, isDirectory: node.isDirectory) }
        let before = Dictionary(base.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(target.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for node in base where after[node.path] == nil {
            onChange(ResticDiffChange(path: spelled(node), modifier: "-"))
        }
        for node in target {
            if let old = before[node.path] {
                if old.isDirectory != node.isDirectory {
                    onChange(ResticDiffChange(path: spelled(node), modifier: "T"))
                }
            } else {
                onChange(ResticDiffChange(path: spelled(node), modifier: "+"))
            }
        }
        try Self.requireWhole(malformed)
    }

    private static func requireWhole(_ malformed: Int) throws {
        guard malformed > 0 else { return }
        throw ResticError.malformedOutput(detail: "scripted: \(malformed) line(s) did not decode")
    }

    private static func unreadableError(_ snapshotID: String) -> ResticError {
        .commandFailed(exitCode: 1, message: "scripted: cannot read \(snapshotID)")
    }

    func backup(
        _ context: RepositoryContext,
        plan: BackupPlan,
        onProgress: (@Sendable (OperationProgress) -> Void)?
    ) async throws -> BackupOutcome {
        record("backup")
        transcribe("backup")
        onProgress?(OperationProgress())
        return try locked { backupScript }.get()
    }

    func forget(_ context: RepositoryContext, plan: BackupPlan) async throws -> Int {
        record("forget")
        transcribe("forget")
        return try locked { forgetScript }.get()
    }

    /// Not transcribed: the preview is a read the sheet asks for, not a run.
    func forgetPreview(_ context: RepositoryContext, plan: BackupPlan) async throws -> RetentionPreview {
        record("forgetPreview")
        return try locked { forgetPreviewScript }.get()
    }

    func restore(
        _ context: RepositoryContext,
        snapshotID: String,
        node: SnapshotNode,
        destinationDirectory: URL,
        overwrite: RestoreOverwritePolicy,
        onProgress: (@Sendable (OperationProgress) -> Void)?
    ) async throws -> ResticSummary? {
        record("restore:\(overwrite.resticValue)")
        return nil
    }

    func restoreItems(
        _ context: RepositoryContext,
        snapshotID: String,
        parent: String,
        nodes: [SnapshotNode],
        destinationDirectory: URL,
        overwrite: RestoreOverwritePolicy,
        onProgress: (@Sendable (OperationProgress) -> Void)?
    ) async throws -> ResticSummary? {
        record("restoreItems:\(overwrite.resticValue):\(parent):\(nodes.map(\.name).joined(separator: ","))")
        return nil
    }

    func restoreWholeSnapshot(
        _ context: RepositoryContext,
        snapshotID: String,
        destinationDirectory: URL,
        overwrite: RestoreOverwritePolicy,
        onProgress: (@Sendable (OperationProgress) -> Void)?
    ) async throws -> ResticSummary? {
        record("restoreWhole:\(overwrite.resticValue)")
        return nil
    }
}
