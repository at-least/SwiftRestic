import Foundation

/// Everything one restic command needs to reach a repository: the location, the
/// password and any backend credentials.
struct RepositoryContext: Sendable {
    var repository: Repository
    var password: String
    var providerSecret: String?
    var settings = AppSettings()

    /// Keys the app itself owns: the repository location and every form of the
    /// password restic can read. Letting `extraEnvironment` override these would
    /// silently point restic at another repository or break authentication — the
    /// class of bug behind backrest's issue #1139 — so they are applied last,
    /// whatever the user added.
    static let protectedEnvironmentKeys: Set<String> = [
        "RESTIC_REPOSITORY", "RESTIC_PASSWORD", "RESTIC_PASSWORD_FILE", "RESTIC_PASSWORD_COMMAND",
    ]

    var environment: [String: String] {
        var env = repository.credentialEnvironment(secret: providerSecret)
        env.merge(repository.extraEnvironment) { _, new in new }
        // restic ranks PASSWORD_COMMAND and PASSWORD_FILE above PASSWORD, so
        // overriding the password alone is not enough — they must not reach it.
        env.removeValue(forKey: "RESTIC_PASSWORD_COMMAND")
        env.removeValue(forKey: "RESTIC_PASSWORD_FILE")
        // Only claimed when there is a value: the console can legitimately reach
        // a repository the plan editor would call incomplete.
        let repositoryString = repository.resticRepositoryString
        if !repositoryString.isEmpty { env["RESTIC_REPOSITORY"] = repositoryString }
        env["RESTIC_PASSWORD"] = password
        return env
    }

    /// Entries in `extraEnvironment` that this context overwrites anyway, so an
    /// editor screen can tell the user their setting has no effect.
    var overriddenExtraEnvironmentKeys: [String] {
        repository.extraEnvironment.keys
            .filter { Self.protectedEnvironmentKeys.contains($0) }
            .sorted()
    }

    /// Flags that apply to every command, not just one.
    var globalArguments: [String] {
        var args: [String] = []
        if settings.uploadLimitKiBps > 0 {
            args += ["--limit-upload", String(settings.uploadLimitKiBps)]
        }
        if settings.downloadLimitKiBps > 0 {
            args += ["--limit-download", String(settings.downloadLimitKiBps)]
        }
        return args
    }
}

/// Live progress of a running backup or restore.
struct OperationProgress: Sendable, Equatable {
    var fraction: Double = 0
    var filesDone: Int = 0
    var totalFiles: Int = 0
    var bytesDone: Int64 = 0
    var totalBytes: Int64 = 0
    var currentFile: String?
    var secondsRemaining: Int?
    var errorCount: Int = 0

    init() {}

    init(status: ResticStatus) {
        fraction = status.fractionComplete
        filesDone = status.filesDone ?? 0
        totalFiles = status.totalFiles ?? 0
        bytesDone = status.bytesDone ?? 0
        totalBytes = status.totalBytes ?? 0
        currentFile = status.currentFiles.first
        secondsRemaining = status.secondsRemaining
        errorCount = status.errorCount ?? 0
    }
}

/// The result of one `restic backup`.
struct BackupOutcome: Sendable {
    var summary: ResticSummary?
    var itemErrors: [String]
    var exitCode: Int32

    /// Exit code 3 means restic finished but skipped files it could not read.
    var completedWithErrors: Bool {
        exitCode == ResticError.backupPartialSuccessCode || !itemErrors.isEmpty
    }
}

/// The typed restic commands the app uses, layered over `ResticRunner`.
struct ResticService: ResticClient {
    let runner: ResticRunner
    let binary: URL

    /// Tag stamped on every snapshot a plan creates, so retention and snapshot
    /// listings can be scoped to that plan without touching anyone else's data.
    static func planTag(_ planID: UUID) -> String {
        "swiftrestic-plan-\(planID.uuidString.lowercased())"
    }

    // MARK: - Repository lifecycle

    func version() async throws -> String {
        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(arguments: ["version"], retainFullOutput: true)
        )
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates a new repository. Fails if one already exists at the location.
    @discardableResult
    func initializeRepository(_ context: RepositoryContext) async throws -> String? {
        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: context.globalArguments + ["init", "--json"],
                environment: context.environment
            )
        )
        for message in result.messages {
            if case let .initialized(info) = message { return info.id }
        }
        return nil
    }

    /// Cheap probe used to validate credentials when adding a repository.
    /// Returns `false` when the repository does not exist yet (exit code 10).
    func repositoryExists(_ context: RepositoryContext) async throws -> Bool {
        do {
            _ = try await runner.run(
                binary: binary,
                invocation: ResticInvocation(
                    arguments: context.globalArguments + ["cat", "config", "--json"],
                    environment: context.environment,
                    retainFullOutput: true
                )
            )
            return true
        } catch let ResticError.commandFailed(exitCode, _, _) where exitCode == 10 {
            return false
        }
    }

    func unlock(_ context: RepositoryContext) async throws {
        _ = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: context.globalArguments + ["unlock", "--json"],
                environment: context.environment
            )
        )
    }

    func stats(_ context: RepositoryContext, timeout: TimeInterval? = nil) async throws -> RepositoryStats {
        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: context.globalArguments + ["stats", "--json", "--mode", "raw-data"],
                environment: context.environment,
                timeout: timeout,
                retainFullOutput: true
            )
        )
        guard let data = result.stdout.data(using: .utf8) else {
            throw ResticError.commandFailed(exitCode: 0, message: "stats produced no output", command: "stats")
        }
        return try ResticMessageDecoder.jsonDecoder.decode(RepositoryStats.self, from: data)
    }

    func check(_ context: RepositoryContext, readDataSubsetPercent: Int?) async throws -> ResticSummary? {
        var args = context.globalArguments + ["check", "--json"]
        if let percent = readDataSubsetPercent, percent > 0 {
            args += ["--read-data-subset=\(percent)%"]
        }
        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(arguments: args, environment: context.environment)
        )
        return result.summary
    }

    /// Reclaims the space that `forget` freed.
    ///
    /// `prune` is one of the commands `--json` does not cover in restic 0.19.1 —
    /// it prints human-readable progress — so its output is captured as text and
    /// kept on the run record rather than parsed. `onRawLine` receives each line
    /// as it arrives so a UI can show that the prune is still moving.
    func prune(
        _ context: RepositoryContext,
        dryRun: Bool = false,
        onRawLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        var args = context.globalArguments + ["prune"]
        if dryRun { args.append("--dry-run") }
        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: args,
                environment: context.environment,
                retainFullOutput: true
            ),
            onRawLine: onRawLine
        )
        let combined = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return ResticRunner.tail(of: combined, limit: 4000)
    }

    /// Runs an arbitrary restic command, returning stdout and stderr together.
    ///
    /// Any exit code is returned rather than thrown: the console shows whatever
    /// restic said, including its complaints.
    func runRaw(_ context: RepositoryContext, arguments: [String]) async throws -> String {
        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: context.globalArguments + arguments,
                environment: context.environment,
                allowedExitCodes: nil,
                retainFullOutput: true
            )
        )
        var output = result.stdout
        if !result.stderr.isEmpty {
            if !output.isEmpty { output += "\n" }
            output += result.stderr
        }
        if result.exitCode != 0 {
            let known = ResticError.knownExitCodeDescription(result.exitCode)
            output += "\n\n[exit \(result.exitCode)\(known.map { ": \($0)" } ?? "")]"
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Snapshots

    func snapshots(
        _ context: RepositoryContext,
        planID: UUID? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> [Snapshot] {
        var args = context.globalArguments + ["snapshots", "--json"]
        if let planID { args += ["--tag", Self.planTag(planID)] }
        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: args,
                environment: context.environment,
                timeout: timeout,
                retainFullOutput: true
            )
        )
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null", let data = trimmed.data(using: .utf8) else { return [] }
        let decoded = try ResticMessageDecoder.jsonDecoder.decode([Snapshot]?.self, from: data)
        return (decoded ?? []).sorted { $0.time > $1.time }
    }

    /// Lists the immediate children of `path` inside a snapshot.
    ///
    /// `restic ls <id>` alone walks the whole tree, which is far too much for a
    /// browser; giving it an absolute directory makes it list one level, plus the
    /// directory itself, which we drop here.
    func listDirectory(
        _ context: RepositoryContext,
        snapshotID: String,
        path: String
    ) async throws -> [SnapshotNode] {
        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: context.globalArguments + ["ls", "--json", snapshotID, path],
                environment: context.environment
            )
        )
        let normalized = Self.normalize(path)
        var nodes: [SnapshotNode] = []
        for message in result.messages {
            guard case let .node(node) = message else { continue }
            let nodePath = Self.normalize(node.path)
            guard nodePath != normalized else { continue }
            guard Self.parent(of: nodePath) == normalized else { continue }
            nodes.append(node)
        }
        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func normalize(_ path: String) -> String {
        guard path != "/" else { return "/" }
        var value = path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// The directory containing `path`, in pure String arithmetic rather
    /// than NSString's `deletingLastPathComponent`, so the tree-filtering
    /// here spells the same on any Foundation. The scan is over unicode
    /// scalars, not Characters: a name beginning with a combining mark
    /// merges the separator into one grapheme ("/a/´x"), and a Character
    /// scan would miss it and drop the node from the listing. The cut
    /// stays inside the scalars view too — a String subscript re-aligns
    /// to grapheme boundaries, and a Prepend character (U+0600 and
    /// friends) puts the slash mid-cluster, so slicing through the
    /// Character view would round down and shed the character. Paths are
    /// absolute and already trailing-slash-stripped by `normalize`, so
    /// slicing at the last separator is the whole rule. (`expandTilde`
    /// below remains the one NSString use: `~user` semantics have no
    /// pure-Swift spelling.)
    private static func parent(of path: String) -> String {
        guard let separator = path.unicodeScalars.lastIndex(of: "/") else { return path }
        return separator == path.unicodeScalars.startIndex ? "/" : String(path.unicodeScalars[..<separator])
    }

    /// Searches every snapshot for paths matching a glob.
    ///
    /// `restic find` walks the trees, so this is a real search rather than an
    /// index lookup — it gets slower the more snapshots a repository holds, which
    /// is why the caller can narrow it to one snapshot.
    func find(
        _ context: RepositoryContext,
        pattern: String,
        ignoreCase: Bool = true,
        snapshotID: String? = nil
    ) async throws -> [FindResult] {
        var args = context.globalArguments + ["find", "--json"]
        if ignoreCase { args.append("--ignore-case") }
        if let snapshotID { args += ["--snapshot", snapshotID] }
        args.append(pattern)

        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: args,
                environment: context.environment,
                retainFullOutput: true
            )
        )
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null", let data = trimmed.data(using: .utf8) else {
            return []
        }
        let decoded = try ResticMessageDecoder.jsonDecoder.decode([FindResult]?.self, from: data)
        return (decoded ?? []).filter { !$0.matches.isEmpty }
    }

    /// Compares two snapshots. `+` in the result means present only in `newer`.
    ///
    /// The change stream is unbounded, so it is collected through the message
    /// callback and cut off at `SnapshotDiff.changeLimit` rather than kept whole.
    func diff(
        _ context: RepositoryContext,
        olderID: String,
        newerID: String,
        includeMetadata: Bool = false
    ) async throws -> SnapshotDiff {
        var args = context.globalArguments + ["diff", "--json"]
        if includeMetadata { args.append("--metadata") }
        args += [olderID, newerID]

        let collector = DiffCollector(limit: SnapshotDiff.changeLimit)
        _ = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: args,
                environment: context.environment,
                retainMessages: false
            ),
            onMessage: { message in collector.consume(message) }
        )
        var result = collector.result
        result.olderID = olderID
        result.newerID = newerID
        return result
    }

    // MARK: - Backup

    func backup(
        _ context: RepositoryContext,
        plan: BackupPlan,
        onProgress: (@Sendable (OperationProgress) -> Void)? = nil
    ) async throws -> BackupOutcome {
        var args = context.globalArguments + ["backup", "--json"]
        for source in plan.sources { args.append(Self.expandTilde(source)) }
        for pattern in plan.excludePatterns where !pattern.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["--exclude", Self.expandTilde(pattern)]
        }
        if plan.excludeCaches { args.append("--exclude-caches") }
        if plan.oneFileSystem { args.append("--one-file-system") }
        args += ["--tag", Self.planTag(plan.id)]
        for tag in plan.tags where !tag.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["--tag", tag]
        }

        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: args,
                environment: context.environment,
                // 3 = finished, but some source files were unreadable.
                allowedExitCodes: [0, ResticError.backupPartialSuccessCode]
            ),
            onMessage: { message in
                if case let .status(status) = message {
                    onProgress?(OperationProgress(status: status))
                }
            }
        )

        return BackupOutcome(
            summary: result.summary,
            itemErrors: result.itemErrors.map { error in
                if let item = error.item { "\(item): \(error.message)" } else { error.message }
            },
            exitCode: result.exitCode
        )
    }

    /// Applies a plan's retention policy. Refuses to run when the policy has no
    /// `--keep-*` rule, which restic would read as "delete everything".
    @discardableResult
    func forget(_ context: RepositoryContext, plan: BackupPlan) async throws -> Int {
        guard plan.retention.isSafeToRun else { return 0 }
        var args = context.globalArguments + ["forget", "--json", "--tag", Self.planTag(plan.id)]
        args += plan.retention.forgetArguments
        if plan.retention.runPrune { args.append("--prune") }

        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: args,
                environment: context.environment,
                // `forget`, like `backup`, uses 3 for "finished with data access issues".
                allowedExitCodes: [0, ResticError.backupPartialSuccessCode],
                retainFullOutput: true
            )
        )
        return Self.countRemoved(forgetOutput: result.stdout)
    }

    /// `forget --json` answers with an array of per-group keep/remove lists.
    static func countRemoved(forgetOutput: String) -> Int {
        guard let data = forgetOutput.data(using: .utf8) else { return 0 }
        guard let groups = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return 0 }
        return groups.reduce(0) { total, group in
            total + ((group["remove"] as? [Any])?.count ?? 0)
        }
    }

    // MARK: - Restore

    /// Restores one node into `destinationDirectory`, without recreating the
    /// original absolute path above it.
    ///
    /// Directories go through `restic restore <id>:<path>`, which makes the given
    /// subtree the root of the output. Single files go through `restic dump`,
    /// which writes exactly one file and nothing else.
    @discardableResult
    func restore(
        _ context: RepositoryContext,
        snapshotID: String,
        node: SnapshotNode,
        destinationDirectory: URL,
        onProgress: (@Sendable (OperationProgress) -> Void)? = nil
    ) async throws -> ResticSummary? {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        if node.isDirectory {
            let target = destinationDirectory.appendingPathComponent(node.name.isEmpty ? "restored" : node.name)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let result = try await runner.run(
                binary: binary,
                invocation: ResticInvocation(
                    arguments: context.globalArguments
                        + ["restore", "--json", "\(snapshotID):\(node.path)", "--target", target.path],
                    environment: context.environment
                ),
                onMessage: { message in
                    if case let .status(status) = message {
                        onProgress?(OperationProgress(status: status))
                    }
                }
            )
            return result.summary
        }

        let target = destinationDirectory.appendingPathComponent(node.name)
        _ = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: context.globalArguments + ["dump", snapshotID, node.path],
                environment: context.environment,
                stdoutFile: target
            )
        )
        var summary = ResticSummary()
        summary.totalFiles = 1
        summary.filesRestored = 1
        summary.totalBytes = node.size
        summary.bytesRestored = node.size
        return summary
    }

    /// Restores an entire snapshot, keeping the original directory layout below
    /// `destinationDirectory`.
    @discardableResult
    func restoreWholeSnapshot(
        _ context: RepositoryContext,
        snapshotID: String,
        destinationDirectory: URL,
        onProgress: (@Sendable (OperationProgress) -> Void)? = nil
    ) async throws -> ResticSummary? {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: context.globalArguments
                    + ["restore", "--json", snapshotID, "--target", destinationDirectory.path],
                environment: context.environment
            ),
            onMessage: { message in
                if case let .status(status) = message {
                    onProgress?(OperationProgress(status: status))
                }
            }
        )
        return result.summary
    }

    // MARK: - Helpers

    /// Gathers `diff` output as it streams, off the main actor, keeping only the
    /// first `limit` changes.
    private final class DiffCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var diff = SnapshotDiff(olderID: "", newerID: "")

        init(limit: Int) { self.limit = limit }

        func consume(_ message: ResticMessage) {
            lock.lock()
            defer { lock.unlock() }
            switch message {
            case let .change(change):
                if diff.changes.count < limit { diff.changes.append(change) }
                else { diff.isTruncated = true }
            case let .statistics(statistics):
                diff.statistics = statistics
            default:
                break
            }
        }

        var result: SnapshotDiff {
            lock.lock()
            defer { lock.unlock() }
            return diff
        }
    }

    /// restic does not expand `~`; the shell normally would.
    static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return (path as NSString).expandingTildeInPath
    }
}
