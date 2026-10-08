import Foundation

/// Everything one restic command needs to reach a repository: the location, the
/// password and any backend credentials.
struct RepositoryContext: Sendable {
    var repository: Repository
    var password: String
    var providerSecret: String?
    var settings = AppSettings()

    /// Keys the app itself owns — see `ResticRunner.protectedEnvironmentKeys`,
    /// which strips the same set from every child's inherited environment.
    static let protectedEnvironmentKeys = ResticRunner.protectedEnvironmentKeys

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

    init() {}

    init(status: ResticStatus) {
        fraction = status.fractionComplete
        filesDone = status.filesDone ?? 0
        totalFiles = status.totalFiles ?? 0
        bytesDone = status.bytesDone ?? 0
        totalBytes = status.totalBytes ?? 0
        currentFile = status.currentFiles.first
        secondsRemaining = status.secondsRemaining
    }
}

/// The result of one `restic backup`.
struct BackupOutcome: Sendable {
    var summary: ResticSummary?
    /// restic's unreadable items, one line per item — skipped sources first,
    /// then deduplicated error events in arrival order. See
    /// `ResticService.unreadableItems(errors:stderr:)`.
    var itemErrors: [String]
    var exitCode: Int32
    /// A reporting gap: restic messages that failed to decode. Kept apart
    /// from `itemErrors` because nothing restic read was lost — but the run
    /// must not read clean either.
    var decodingWarning: String? = nil
    /// The path each unreadable line names, keyed by the line — where restic
    /// named one. See `ResticService.unreadableItemPaths(errors:stderr:)`.
    var itemPaths: [String: String] = [:]

    /// Sets aside the sources restic skipped because their drive is away
    /// (`isAway`, asked of each skip line's path) when they are all it
    /// could not read: their lines leave `itemErrors` and their paths are
    /// returned. Anything else unread — an error event, a skipped folder
    /// whose drive is here, a reporting gap — leaves everything in place
    /// and returns none.
    mutating func setAsideAwaySources(isAway: (String) -> Bool) -> [String] {
        guard decodingWarning == nil else { return [] }
        var away: [String] = []
        for line in itemErrors {
            guard ResticService.isSkipLine(line), let path = itemPaths[line], isAway(path) else { return [] }
            away.append(path)
        }
        itemErrors = []
        itemPaths = [:]
        return away
    }

    /// True for restic exit 3 — finished but skipped files it could not
    /// read — or when the outcome records unreadable items or a decoding gap.
    var completedWithErrors: Bool {
        exitCode == ResticError.backupPartialSuccessCode || !itemErrors.isEmpty || decodingWarning != nil
    }
}

/// The typed restic commands the app uses, layered over `ResticRunner`.
struct ResticService: ResticClient {
    /// Stall cap for commands that stream NDJSON while they work (`backup`,
    /// `restore`, the index walks): total silence for this long means the
    /// child is hung — a black-holed network path — while a legitimate run of
    /// any length keeps reporting. Not applied to legitimately silent
    /// commands (`prune`, `forget`, `dump`, console `runRaw`).
    static let streamingIdleTimeout: TimeInterval = 15 * 60
    let runner: ResticRunner
    let binary: URL
    /// Whether the located restic streams `restore --json` progress (0.16+):
    /// the restore commands' idle stall cap applies only when it does — an
    /// older, legitimately silent restore must not be killed as hung.
    /// Defaults on: an unreadable version is likelier a transient than an
    /// ancient binary, and decoding is pinned to modern output anyway.
    var streamsRestoreProgress = true
    /// Whether the located restic takes `restore --overwrite` (0.17+).
    /// Defaults on, for the same reason as the stall cap.
    var supportsRestoreOverwrite = true
    /// Whether this restic takes `--exclude-cloud-files` on macOS (0.19+).
    /// Below that a plan's setting passes nothing, and the editor says so.
    var excludesCloudFiles = true

    /// Tag stamped on every snapshot a plan creates, so retention and snapshot
    /// listings can be scoped to that plan without touching anyone else's data.
    static func planTag(_ planID: UUID) -> String {
        Self.planTagPrefix + planID.uuidString.lowercased()
    }

    /// The prefix that identifies a tag as ours. The snapshot index uses it to
    /// decide which chain a snapshot belongs to; keep the two in sync through
    /// this one constant.
    static let planTagPrefix = "swiftrestic-plan-"

    /// The plan a `swiftrestic-plan-` tag names — the inverse of
    /// `planTag(_:)`: it accepts exactly the tags `planTag` writes, so an
    /// upper-case UUID or a mangled tail reads as untagged. Nil for
    /// anything else.
    static func planUUID(fromTag tag: String) -> UUID? {
        guard tag.hasPrefix(Self.planTagPrefix),
              let planID = UUID(uuidString: String(tag.dropFirst(Self.planTagPrefix.count))),
              planTag(planID) == tag
        else { return nil }
        return planID
    }

    /// The hostname restic records for a backup made on this Mac — the app
    /// never passes `--host`, so restic takes gethostname(3). Not
    /// ProcessInfo's hostName, which lowercases it: a backup records
    /// gethostname's mixed-case name. Read once per launch.
    static let localHostname: String = {
        var name = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        precondition(gethostname(&name, name.count) == 0, "gethostname failed: errno \(errno)")
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()

    // MARK: - Repository lifecycle

    func version() async throws -> String {
        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(arguments: ["version"], retainFullOutput: true)
        )
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `restic cache`: the local cache's directories with their sizes — no
    /// repository, no password. restic measures each directory, so a Mac
    /// whose tests left thousands of scratch repositories answers in a
    /// dozen seconds; a user's handful answers at once.
    func cacheReport() async throws -> ResticCacheReport {
        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(arguments: ["cache"], timeout: 120, retainFullOutput: true)
        )
        guard let report = ResticCacheReport.parse(result.stdout) else {
            throw ResticError.commandFailed(
                exitCode: result.exitCode,
                message: "restic cache answered in a form the app does not read: \(result.stdout.prefix(200))"
            )
        }
        return report
    }

    /// `restic cache --cleanup`: removes the directories restic marks old —
    /// unused for `ResticCacheReport.oldAfterDays` days, a repository still
    /// set up here included; restic rebuilds one the next time it opens
    /// that repository. Prints "no old cache dirs found" when none is.
    func cleanupCache() async throws {
        _ = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(arguments: ["cache", "--cleanup"], timeout: 600, retainFullOutput: true)
        )
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
    func repositoryExists(_ context: RepositoryContext, timeout: TimeInterval?) async throws -> Bool {
        do {
            _ = try await runner.run(
                binary: binary,
                invocation: ResticInvocation(
                    arguments: context.globalArguments + ["cat", "config", "--json"],
                    environment: context.environment,
                    timeout: timeout,
                    retainFullOutput: true
                )
            )
            return true
        } catch let ResticError.commandFailed(exitCode, _) where exitCode == 10 {
            return false
        }
    }

    /// The new password reaches restic through a file — it has no other
    /// non-interactive way in — readable by this user alone, in a folder of
    /// its own that goes when the command ends. restic takes an exclusive
    /// lock: under another process's lock it fails at once with exit 11,
    /// and a current password it does not take fails with 12, both leaving
    /// the old key standing (checked on 0.19.1).
    func changePassword(_ context: RepositoryContext, newPassword: String) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftRestic-Key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("new-password")
        guard FileManager.default.createFile(
            atPath: file.path, contents: Data(newPassword.utf8), attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        _ = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: context.globalArguments + ["key", "passwd", "--json", "--new-password-file", file.path],
                environment: context.environment
            )
        )
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

    /// Lock-free, for `find`'s reasons.
    func stats(_ context: RepositoryContext, timeout: TimeInterval? = nil) async throws -> RepositoryStats {
        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: context.globalArguments + ["stats", "--json", "--mode", "raw-data", "--no-lock"],
                environment: context.environment,
                timeout: timeout,
                retainFullOutput: true
            )
        )
        guard let data = result.stdout.data(using: .utf8) else {
            throw ResticError.commandFailed(exitCode: 0, message: "stats produced no output")
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
            invocation: ResticInvocation(
                arguments: args,
                environment: context.environment,
                // restic exits 1 when a check finds damage — that is the check
                // doing its job, not the command failing. The verdict still
                // has to name the damage: an exit 1 without an error count is
                // a broken run, never a clean bill of health.
                allowedExitCodes: [0, 1]
            )
        )
        let summary = result.summary
        if result.exitCode == 1, (summary?.numErrors ?? 0) == 0 {
            let message = result.failureMessage
            throw ResticError.commandFailed(
                exitCode: result.exitCode,
                message: message
            )
        }
        return summary
    }

    /// Reclaims the space that `forget` freed.
    ///
    /// `prune` is one of the commands `--json` does not cover (restic
    /// 0.19.1): it prints human-readable progress, so its output is captured
    /// as text and kept on the run record rather than parsed. `onRawLine`
    /// receives each line as it arrives, so a UI can show the prune is
    /// still moving.
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

    /// Lock-free, for `find`'s reasons.
    func snapshots(
        _ context: RepositoryContext,
        planID: UUID? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> [Snapshot] {
        var args = context.globalArguments + ["snapshots", "--json", "--no-lock"]
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
        return try Self.decodeArray(Snapshot.self, from: result.stdout).sorted { $0.time > $1.time }
    }

    /// Lists the immediate children of `path` inside a snapshot.
    ///
    /// `restic ls <id>` alone walks the whole tree, which is far too much for a
    /// browser; giving it an absolute directory makes it list one level, plus the
    /// directory itself, which we drop here. Lock-free, for `find`'s reasons.
    func listDirectory(
        _ context: RepositoryContext,
        snapshotID: String,
        path: String
    ) async throws -> [SnapshotNode] {
        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: context.globalArguments + ["ls", "--json", "--no-lock", snapshotID, path],
                environment: context.environment
            )
        )
        let normalized = ResticPath.normalized(path)
        var nodes: [SnapshotNode] = []
        for message in result.messages {
            guard case let .node(node) = message else { continue }
            let nodePath = ResticPath.normalized(node.path)
            guard nodePath != normalized else { continue }
            guard ResticPath.parent(of: nodePath) == normalized else { continue }
            nodes.append(node)
        }
        return Self.sortedForBrowser(nodes)
    }

    /// The browser's one row order — directories first, then Finder-style —
    /// shared by the live `ls` path and the browse-cache read, so a cached
    /// listing renders identically to a fetched one.
    static func sortedForBrowser(_ nodes: [SnapshotNode]) -> [SnapshotNode] {
        nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// The full-tree `ls` behind the index backfill. `retainMessages: false`
    /// keeps the runner from accumulating a snapshot's worth of nodes in
    /// memory — the callback is the only delivery. `--no-lock`: a history
    /// walk is long and read-only, and even a shared lock would collide
    /// with retention's exclusive `forget`; a read that trips over a
    /// concurrently pruned pack fails and stays pending for a later pass.
    func walkSnapshot(
        _ context: RepositoryContext,
        snapshotID: String,
        onNode: @Sendable @escaping (SnapshotNode) -> Void
    ) async throws {
        let outcome = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: context.globalArguments + ["ls", "--json", "--no-lock", snapshotID],
                environment: context.environment,
                idleTimeout: Self.streamingIdleTimeout,
                retainMessages: false
            ),
            onMessage: { message in
                if case let .node(node) = message { onNode(node) }
            }
        )
        try Self.requireWhole(outcome, item: "node")
    }

    /// `path` as a `restic find` pattern that matches that path alone: the
    /// metacharacters `*`, `?`, `[` and the escape `\` itself, each escaped
    /// with a backslash. Unescaped, `a[1].txt` matches `a1.txt` and not
    /// itself. A full path also keeps restic's walk to that path's folders,
    /// where a name pattern walks whole trees.
    /// Scalar by scalar, as `ResticPath` cuts paths: a combining mark after
    /// a `[` makes one Character of the two, which a Character scan would
    /// pass unescaped.
    static func globEscaped(_ path: String) -> String {
        var escaped = String.UnicodeScalarView()
        for scalar in path.unicodeScalars {
            if "*?[\\".unicodeScalars.contains(scalar) { escaped.append("\\") }
            escaped.append(scalar)
        }
        return String(escaped)
    }

    /// Searches every snapshot for paths matching any of some globs — one
    /// walk per snapshot however many there are, so a folder's files cost
    /// about what one does.
    ///
    /// `restic find` walks the trees: a real search rather than an index
    /// lookup, slower the more snapshots a repository holds, which is why
    /// the caller can narrow it (none named: every one). A named snapshot
    /// the repository no longer holds is skipped with a warning on stderr;
    /// the rest still answer (restic 0.19.1).
    ///
    /// `--no-lock`, as `listDirectory`, `diff`, `snapshots` and `stats`:
    /// what a click in a Files tab or on Compare with Previous… and a
    /// refresh run. Locked, each would pay restic's 200 ms lock wait, fail
    /// at once with exit 11 while retention's `forget` or a `prune` held
    /// the exclusive lock, and lock a starting `forget` out the same way.
    func find(
        _ context: RepositoryContext,
        patterns: [String],
        ignoreCase: Bool = true,
        snapshotIDs: [String] = []
    ) async throws -> [FindResult] {
        var args = context.globalArguments + ["find", "--json", "--no-lock"]
        if ignoreCase { args.append("--ignore-case") }
        for id in snapshotIDs { args += ["--snapshot", id] }
        args += patterns

        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: args,
                environment: context.environment,
                retainFullOutput: true
            )
        )
        return try Self.decodeArray(FindResult.self, from: result.stdout).filter { !$0.matches.isEmpty }
    }

    /// Compares two snapshots. `+` in the result means present only in `newer`.
    ///
    /// The change stream is unbounded, so it is collected through the message
    /// callback and cut off at `SnapshotDiff.changeLimit` rather than kept whole.
    /// Lock-free, for `find`'s reasons.
    func diff(
        _ context: RepositoryContext,
        olderID: String,
        newerID: String,
        includeMetadata: Bool = false
    ) async throws -> SnapshotDiff {
        var args = context.globalArguments + ["diff", "--json", "--no-lock"]
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

    /// The uncapped diff the index applies after each backup. The stream is
    /// unbounded, so the callback must consume incrementally. `--no-lock`
    /// for the same reason `walkSnapshot` wears it.
    func walkDiff(
        _ context: RepositoryContext,
        olderID: String,
        newerID: String,
        onChange: @Sendable @escaping (ResticDiffChange) -> Void
    ) async throws {
        let outcome = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: context.globalArguments + ["diff", "--json", "--no-lock", olderID, newerID],
                environment: context.environment,
                idleTimeout: Self.streamingIdleTimeout,
                retainMessages: false
            ),
            onMessage: { message in
                if case let .change(change) = message { onChange(change) }
            }
        )
        try Self.requireWhole(outcome, item: "change")
    }

    /// A streamed walk is the whole answer only when every line restic
    /// wrote decoded: a dropped line is an item the callback never saw,
    /// whatever the exit code said. Thrown after the stream, so what did
    /// decode has already been delivered.
    private static func requireWhole(_ outcome: ResticRunResult, item: String) throws {
        let malformed = outcome.malformedCount
        guard malformed > 0 else { return }
        throw ResticError.malformedOutput(
                        detail: "\(malformed) \(item) \(malformed == 1 ? "line" : "lines") did not decode"
        )
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
        if plan.excludeCloudFiles, excludesCloudFiles { args.append("--exclude-cloud-files") }
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
                allowedExitCodes: [0, ResticError.backupPartialSuccessCode],
                idleTimeout: Self.streamingIdleTimeout
            ),
            onMessage: Self.progressHandler(onProgress)
        )

        // A known message that failed to decode is a reporting gap — the
        // run's numbers may be wrong, and "wrong" must not look like "clean".
        // One line, so the run record says so; beside the unreadable items,
        // never counted among them.
        let decodingWarning = result.malformedCount > 0
            ? "\(result.malformedCount) restic \(result.malformedCount == 1 ? "message" : "messages") could not be decoded — a restic update may have changed its output; the run's numbers may be incomplete."
            : nil
        return BackupOutcome(
            summary: result.summary,
            itemErrors: Self.unreadableItems(errors: result.itemErrors, stderr: result.stderr),
            exitCode: result.exitCode,
            decodingWarning: decodingWarning,
            itemPaths: Self.unreadableItemPaths(errors: result.itemErrors, stderr: result.stderr)
        )
    }

    /// What a backup could not read, one line per item: the sources restic
    /// skipped, verbatim, then its error events deduplicated by item (the
    /// first message wins; an event without an item is keyed by its message).
    ///
    /// restic reports the halves differently (0.19.1). A folder it cannot
    /// list arrives twice — once `during: scan`, once `during: archival`,
    /// with the identical item — so events are deduplicated, not counted. A
    /// missing or inaccessible source arrives as no event at all, only plain
    /// stderr text ("… does not exist, skipping" / "… cannot be accessed,
    /// skipping") before it exits 3 — the case that drops a whole top-level
    /// folder, and the only unreadable item restic names outside JSON. Those
    /// lines are written before archival starts, so they always fall inside
    /// the runner's retained head of stderr. The wording is pinned to 0.19.1
    /// like the rest of the decoding; a reworded restic degrades to an
    /// unnamed exit 3, never to a complete snapshot, because the exit code
    /// alone decides that.
    static func unreadableItems(errors: [ResticErrorMessage], stderr: String) -> [String] {
        unreadableEntries(errors: errors, stderr: stderr).map(\.line)
    }

    /// The path each of `unreadableItems`' lines names, keyed by the line:
    /// an event's item, or the source a skip line names. A line naming
    /// none — an event without an item — is absent. Stored on the run so
    /// the fixes that act on an item (Reveal in Finder, Exclude) never
    /// parse restic's free text.
    static func unreadableItemPaths(errors: [ResticErrorMessage], stderr: String) -> [String: String] {
        var paths: [String: String] = [:]
        for entry in unreadableEntries(errors: errors, stderr: stderr) {
            if let path = entry.path { paths[entry.line] = path }
        }
        return paths
    }

    private static let skipSuffixes = [" does not exist, skipping", " cannot be accessed, skipping"]

    /// Whether an unreadable line is restic's word that it skipped a source.
    static func isSkipLine(_ line: String) -> Bool {
        skipSuffixes.contains { line.hasSuffix($0) }
    }

    private static func unreadableEntries(errors: [ResticErrorMessage], stderr: String) -> [(line: String, path: String?)] {
        var seen: Set<String> = []
        var entries: [(line: String, path: String?)] = []
        for line in stderr.split(whereSeparator: \.isNewline).map(String.init) {
            guard let suffix = skipSuffixes.first(where: { line.hasSuffix($0) }) else { continue }
            if seen.insert(line).inserted { entries.append((line, String(line.dropLast(suffix.count)))) }
        }
        for error in errors {
            // Without restic's trailing newline, and keyed by the same text,
            // so an item-less message with and without one is one line.
            let line = RunRecord.storedItemError(error.item.map { "\($0): \(error.message)" } ?? error.message)
            if seen.insert(error.item ?? line).inserted { entries.append((line, error.item)) }
        }
        return entries
    }

    /// The one argument list for a plan's retention, dry or real, so the
    /// preview can never evaluate different rules from the forget it
    /// previews. The dry run adds `--no-lock`: without it a dry forget
    /// needs the exclusive lock (exit 11 while a backup holds its shared
    /// one), and restic refuses `--no-lock` on a real forget (exit 1). A
    /// dry run never prunes: `--prune` would prune for real.
    static func forgetArguments(plan: BackupPlan, dryRun: Bool) -> [String] {
        var args = ["forget", "--json", "--tag", planTag(plan.id)] + plan.retention.forgetArguments
        if dryRun {
            args += ["--dry-run", "--no-lock"]
        } else if plan.retention.runPrune {
            args.append("--prune")
        }
        return args
    }

    /// Applies a plan's retention policy. Refuses to run when the policy has no
    /// `--keep-*` rule, which restic would read as "delete everything".
    @discardableResult
    func forget(_ context: RepositoryContext, plan: BackupPlan) async throws -> Int {
        guard plan.retention.isSafeToRun else { return 0 }
        let args = context.globalArguments + Self.forgetArguments(plan: plan, dryRun: false)

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
        return try Self.countRemoved(forgetOutput: result.stdout)
    }

    /// What the plan's retention would remove right now, without removing
    /// it or locking the repository — Apply Retention Now…'s preview, safe
    /// to run beside a backup. The same refusal as `forget`: a policy with
    /// no rule previews nothing rather than "everything".
    func forgetPreview(_ context: RepositoryContext, plan: BackupPlan) async throws -> RetentionPreview {
        guard plan.retention.isSafeToRun else { return RetentionPreview(kept: [], removed: []) }
        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: context.globalArguments + Self.forgetArguments(plan: plan, dryRun: true),
                environment: context.environment,
                retainFullOutput: true
            )
        )
        return try RetentionPreview(forgetOutput: result.stdout)
    }

    /// `forget --json` answers with an array of per-group keep/remove lists.
    ///
    /// Undecodable output throws rather than reading as zero: "removed 0
    /// snapshots" is a claim about the user's history, and a restic update
    /// that changed the shape must surface, not silently delete the count.
    /// Empty output stays zero — that is restic having nothing to report.
    static func countRemoved(forgetOutput: String) throws -> Int {
        let trimmed = forgetOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        guard let data = trimmed.data(using: .utf8),
              let groups = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            throw ResticError.malformedOutput(
                                detail: "could not read the removal count from restic's answer"
            )
        }
        return groups.reduce(0) { total, group in
            total + ((group["remove"] as? [Any])?.count ?? 0)
        }
    }

    // MARK: - Restore

    /// Restores one node into `destinationDirectory`, without recreating the
    /// original absolute path above it.
    ///
    /// Directories go through `restic restore <id>:<path>`, which makes the
    /// given subtree the root of the output. Single files go through
    /// `restic dump`, which writes exactly one file and nothing else.
    ///
    /// `overwrite` always reaches restic explicitly, even for Replace, whose
    /// `always` is restic's default (0.17+): the command line in the run's
    /// log then says what was asked (older restic: `overwriteArguments`).
    /// Replace is `always`, never `if-changed`, which trusts size and
    /// modification time. Keep is `never`, and not an absolute keep: it
    /// deletes a file that stands where the backup has a folder of the same
    /// name, and gives a folder that already exists the backed-up
    /// permissions and dates. The landing itself is safe —
    /// `createDirectory` below fails on a file there before restic runs.
    /// `restic dump` has no overwrite option, so the file branch keeps
    /// in-app: an existing landing skips the dump entirely, and the
    /// runner's commit refuses a name that appeared while it ran.
    @discardableResult
    func restore(
        _ context: RepositoryContext,
        snapshotID: String,
        node: SnapshotNode,
        destinationDirectory: URL,
        overwrite: RestoreOverwritePolicy,
        onProgress: (@Sendable (OperationProgress) -> Void)? = nil
    ) async throws -> ResticSummary? {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let target = Self.restoredItemURL(for: node, in: destinationDirectory)
        if node.isDirectory {
            // Judged before the folder below exists: it is what Keep keeps.
            let overwriteArguments = try overwriteArguments(overwrite, landings: [target])
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let result = try await runner.run(
                binary: binary,
                invocation: ResticInvocation(
                    arguments: context.globalArguments
                        + ["restore", "--json", "\(snapshotID):\(node.path)", "--target", target.path]
                        + overwriteArguments,
                    environment: context.environment,
                    idleTimeout: streamsRestoreProgress ? Self.streamingIdleTimeout : nil
                ),
                onMessage: Self.progressHandler(onProgress)
            )
            return result.summary
        }

        // lstat, not fileExists: a dangling symlink holds the name too. The
        // check spares the download; the commit below closes the window.
        if overwrite == .keepExisting, RestoreDestinationRules.itemExists(at: target) {
            RunTranscript.current?.note("Kept the file already at \(target.path); restic dump did not run.")
            return Self.keptFileSummary(node: node)
        }
        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: context.globalArguments + ["dump", snapshotID, node.path],
                environment: context.environment,
                stdoutFile: target,
                stdoutFileReplacesExisting: overwrite == .replaceExisting
            )
        )
        if result.keptExistingStdoutFile {
            RunTranscript.current?.note("Kept the file that appeared at \(target.path) during the dump; the dump was discarded.")
            return Self.keptFileSummary(node: node)
        }
        // A node the index synthesized (a search hit) carries no size; the
        // committed file says what landed.
        let written = node.size ?? (
            try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber
        )?.int64Value
        var summary = ResticSummary()
        summary.totalFiles = 1
        summary.filesRestored = 1
        summary.bytesRestored = written
        return summary
    }

    /// Restores several items that share one folder of the backup into
    /// `destinationDirectory`, each landing directly inside it where
    /// `restore(node:)` would put it alone — in one `restic restore
    /// <id>:<parent> --include …` call. One restic process for the lot is
    /// the point: each process reloads the repository's index, so per-item
    /// processes are far slower — a remote index most of all. The target
    /// directory keeps its own permissions and dates: restic gives
    /// `<parent>`'s to nothing.
    ///
    /// The landings are checked before restic runs, as `restore(node:)`'s
    /// are. restic deletes a file standing where a restored folder goes,
    /// under Keep too, so each folder's landing is created first, which
    /// fails on a file there. Under Replace it fails on a folder standing
    /// where a restored file goes — after taking that folder's permissions
    /// away — so that is refused; under Keep it leaves the folder and counts
    /// the file kept, as `restore(node:)` does.
    @discardableResult
    func restoreItems(
        _ context: RepositoryContext,
        snapshotID: String,
        parent: String,
        nodes: [SnapshotNode],
        destinationDirectory: URL,
        overwrite: RestoreOverwritePolicy,
        onProgress: (@Sendable (OperationProgress) -> Void)? = nil
    ) async throws -> ResticSummary? {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let landings = nodes.map { Self.restoredItemURL(for: $0, in: destinationDirectory) }
        // Judged before the folders below exist: they are what Keep keeps.
        let overwriteArguments = try overwriteArguments(overwrite, landings: landings)
        for (node, landing) in zip(nodes, landings) {
            if node.isDirectory {
                try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
            } else if overwrite == .replaceExisting,
                      (try? FileManager.default.attributesOfItem(atPath: landing.path)[.type] as? FileAttributeType) == .typeDirectory {
                throw ResticError.folderInTheWay(path: landing.path)
            }
        }
        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: context.globalArguments
                    + ["restore", "--json", "\(snapshotID):\(parent)", "--target", destinationDirectory.path]
                    + nodes.flatMap { ["--include", RestoreBatch.includePattern(forName: $0.name)] }
                    + overwriteArguments,
                environment: context.environment,
                idleTimeout: streamsRestoreProgress ? Self.streamingIdleTimeout : nil
            ),
            onMessage: Self.progressHandler(onProgress)
        )
        return result.summary
    }

    /// The `--overwrite` arguments for a restore into `landings`. A restic
    /// older than 0.17 rejects the flag and always replaces: Replace needs
    /// nothing there, and Keep is honest only where there is nothing to
    /// keep — folders that do not exist yet or are empty, as a drag's fresh
    /// UUID directory is. Anything else is refused before restic runs, not
    /// replaced; something appearing between this look and restic's start
    /// is the one gap.
    private func overwriteArguments(_ policy: RestoreOverwritePolicy, landings: [URL]) throws -> [String] {
        if supportsRestoreOverwrite { return ["--overwrite", policy.resticValue] }
        guard policy == .keepExisting, let held = landings.first(where: Self.holdsAnything) else { return [] }
        throw ResticError.keepNeedsNewerRestic(path: held.path)
    }

    /// Anything at `url` a restore could replace: a file or link (lstat), or
    /// a folder with entries. A folder that cannot be listed counts as full.
    private static func holdsAnything(_ url: URL) -> Bool {
        guard RestoreDestinationRules.itemExists(at: url) else { return false }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return true }
        return !entries.isEmpty
    }

    /// A single file Keep left alone, with the counters a restore summary
    /// carries (one file seen, none restored, one skipped). The callers also
    /// note it in the run's log, which would otherwise hold no command at
    /// all.
    private static func keptFileSummary(node: SnapshotNode) -> ResticSummary {
        var summary = ResticSummary()
        summary.totalFiles = 1
        summary.filesRestored = 0
        summary.filesSkipped = 1
        return summary
    }

    /// Restores an entire snapshot, keeping the original directory layout below
    /// `destinationDirectory`.
    @discardableResult
    func restoreWholeSnapshot(
        _ context: RepositoryContext,
        snapshotID: String,
        destinationDirectory: URL,
        overwrite: RestoreOverwritePolicy,
        onProgress: (@Sendable (OperationProgress) -> Void)? = nil
    ) async throws -> ResticSummary? {
        let overwriteArguments = try overwriteArguments(overwrite, landings: [destinationDirectory])
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(
                arguments: context.globalArguments
                    + ["restore", "--json", snapshotID, "--target", destinationDirectory.path]
                    + overwriteArguments,
                environment: context.environment,
                idleTimeout: streamsRestoreProgress ? Self.streamingIdleTimeout : nil
            ),
            onMessage: Self.progressHandler(onProgress)
        )
        return result.summary
    }

    // MARK: - Helpers

    /// restic answers an empty line — or a bare `null` — where a JSON list
    /// command has nothing to report, so both spellings decode as no entries.
    private static func decodeArray<T: Decodable>(_ type: T.Type, from stdout: String) throws -> [T] {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null", let data = trimmed.data(using: .utf8) else { return [] }
        let decoded = try ResticMessageDecoder.jsonDecoder.decode([T]?.self, from: data)
        return decoded ?? []
    }

    /// The message-to-progress adapter the streaming commands share: restic's
    /// periodic `status` lines become `OperationProgress` callbacks.
    private static func progressHandler(
        _ onProgress: (@Sendable (OperationProgress) -> Void)?
    ) -> @Sendable (ResticMessage) -> Void {
        { message in
            if case let .status(status) = message {
                onProgress?(OperationProgress(status: status))
            }
        }
    }

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

    /// Where a restored item lands inside the directory it was restored
    /// into — the one landing rule, shared by both restore branches, the
    /// drag path and the run record's destination, so Reveal in Finder
    /// selects exactly what the restore wrote.
    static func restoredItemURL(named name: String, in directory: URL) -> URL {
        directory.appendingPathComponent(sanitizedRestoreName(name))
    }

    static func restoredItemURL(for node: SnapshotNode, in directory: URL) -> URL {
        restoredItemURL(named: node.name, in: directory)
    }

    /// A snapshot node's name as a local file name to create. The names
    /// come from the snapshot — which a hostile writer to a shared
    /// repository can fill with anything — and `appendingPathComponent`
    /// would walk out of the destination on `/` or `..`, so the name is
    /// never trusted: reduced to its last component, with the traversal
    /// spellings replaced.
    static func sanitizedRestoreName(_ name: String) -> String {
        var component = (name as NSString).lastPathComponent
        // Foundation answers "/" for "/" — a name that would aim the write at
        // the destination directory itself rather than inside it.
        if component.isEmpty || component == "." || component == ".." || component == "/" {
            component = "restored"
        }
        return component
    }

    /// restic does not expand `~`; the shell normally would. NSString, not
    /// pure Swift: `~user` semantics have no pure-Swift spelling.
    static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return (path as NSString).expandingTildeInPath
    }
}
