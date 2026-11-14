import Foundation

struct RepositoryContext: Sendable {
    var repository: Repository
    var password: String
    var providerSecret: String?

    var environment: [String: String] {
        var env = repository.credentialEnvironment(secret: providerSecret)
        env.merge(repository.extraEnvironment) { _, new in new }
        // The keys the runner strips from the inherited environment, less
        // the location, which is replaced below: restic ranks
        // PASSWORD_COMMAND and PASSWORD_FILE above PASSWORD, so overriding
        // the password alone is not enough.
        for key in ResticRunner.protectedEnvironmentKeys where key != "RESTIC_REPOSITORY" {
            env.removeValue(forKey: key)
        }
        // Only set when non-empty: the console can legitimately reach a
        // repository the plan editor would call incomplete.
        let repositoryString = repository.resticRepositoryString
        if !repositoryString.isEmpty { env["RESTIC_REPOSITORY"] = repositoryString }
        // Another process of this user can read it with `ps -E`: accepted
        // on a single-user Mac. A password command or a file-descriptor
        // handoff would close it.
        env["RESTIC_PASSWORD"] = password
        return env
    }

    /// restic runs ssh without a terminal, so ssh cannot ask about an
    /// unknown server: accept-new takes a new server's key on first contact
    /// and still refuses one that changed (measured with restic 0.19.1
    /// against a fresh and a mismatched known_hosts).
    var globalArguments: [String] {
        repository.kind == .sftp ? ["-o", "sftp.args=-o StrictHostKeyChecking=accept-new"] : []
    }
}

struct OperationProgress: Sendable, Equatable {
    var fraction: Double = 0
    var filesDone: Int = 0
    var totalFiles: Int = 0
    var bytesDone: Int64 = 0
    var totalBytes: Int64 = 0
    var secondsRemaining: Int?

    init() {}

    init(status: ResticStatus) {
        fraction = status.fractionComplete
        filesDone = status.filesDone ?? 0
        totalFiles = status.totalFiles ?? 0
        bytesDone = status.bytesDone ?? 0
        totalBytes = status.totalBytes ?? 0
        secondsRemaining = status.secondsRemaining
    }
}

struct BackupOutcome: Sendable {
    var summary: ResticSummary?
    /// One line per item: skipped sources first, then deduplicated error
    /// events in arrival order (`ResticService.unreadableItems`).
    var itemErrors: [String]
    var exitCode: Int32
    /// A reporting gap: restic messages that failed to decode, or no
    /// summary. Apart from `itemErrors` because nothing restic read was
    /// lost, but the run must not read clean either.
    var decodingWarning: String? = nil
    /// Keyed by line, where restic named a path
    /// (`ResticService.unreadableItemPaths`).
    var itemPaths: [PathKey: String] = [:]

    var completedWithErrors: Bool {
        exitCode == ResticError.backupPartialSuccessCode || !itemErrors.isEmpty || decodingWarning != nil
    }
}

struct ResticService: ResticClient {
    /// For commands that stream NDJSON while they work (`backup`,
    /// `restore`, the index walks): total silence this long means the child
    /// is hung (a black-holed network path), while a legitimate run of any
    /// length keeps reporting. Not for legitimately silent commands
    /// (`prune`, `forget`, console `runRaw`).
    private static let streamingIdleTimeout: TimeInterval = 15 * 60
    /// `restic check`'s exit when it finds damage.
    private static let checkFoundDamageCode: Int32 = 1
    /// `restic forget`'s "failed to remove one or more snapshots".
    private static let forgetRemovalRefusedCode: Int32 = 3
    let runner: ResticRunner
    let binary: URL
    /// The home folder `~` expands against in the plan's path, its exclude
    /// patterns and the developer rules. Tests re-root it over a scratch
    /// tree.
    var home = NSHomeDirectory()

    /// Stamped on every snapshot a plan creates, so retention and listings
    /// are scoped to that plan without touching anyone else's data.
    static func planTag(_ planID: UUID) -> String {
        Self.planTagPrefix + planID.uuidString.lowercased()
    }

    /// `SnapshotLineage` tells a snapshot's plan tags from its user tags by
    /// this prefix; this one constant keeps the two in sync.
    static let planTagPrefix = "swiftrestic-plan-"

    /// Accepts exactly the tags `planTag` writes, so an upper-case UUID or
    /// a mangled tail reads as untagged.
    static func planUUID(fromTag tag: String) -> UUID? {
        guard tag.hasPrefix(Self.planTagPrefix),
              let planID = UUID(uuidString: String(tag.dropFirst(Self.planTagPrefix.count))),
              planTag(planID) == tag
        else { return nil }
        return planID
    }

    /// The app never passes `--host`, so restic records gethostname(3). Not
    /// ProcessInfo's hostName, which lowercases it.
    static let localHostname: String = {
        var name = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        precondition(gethostname(&name, name.count) == 0, "gethostname failed: errno \(errno)")
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()

    private func run(
        _ context: RepositoryContext,
        _ invocation: ResticInvocation,
        onMessage: (@Sendable (ResticMessage) -> Void)? = nil,
        onRawLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ResticRunResult {
        var invocation = invocation
        invocation.arguments = context.globalArguments + invocation.arguments
        invocation.environment = context.environment
        return try await runner.run(binary: binary, invocation: invocation, onMessage: onMessage, onRawLine: onRawLine)
    }

    func version() async throws -> String {
        let result = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(arguments: ["version"], retainFullOutput: true)
        )
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `restic cache --cleanup` removes cache directories unused for 30
    /// days, a repository still set up here included; restic rebuilds one
    /// on next open. Not `--cleanup-cache check`: a check runs on a
    /// temporary cache and left an old directory in place (restic 0.19.1,
    /// probed), and a cleanup beside a running reader exited 0.
    func cleanupCache() async throws {
        _ = try await runner.run(
            binary: binary,
            invocation: ResticInvocation(arguments: ["cache", "--cleanup"], timeout: 600, retainFullOutput: true)
        )
    }

    /// Fails if a repository already exists at the location.
    @discardableResult
    func initializeRepository(_ context: RepositoryContext) async throws -> String? {
        let result = try await run(context, ResticInvocation(arguments: ["init", "--json"]))
        for message in result.messages {
            if case let .initialized(info) = message { return info.id }
        }
        return nil
    }

    func resticID(_ context: RepositoryContext, timeout: TimeInterval?) async throws -> String {
        let result = try await run(
            context,
            ResticInvocation(arguments: ["cat", "config", "--json"], timeout: timeout, retainFullOutput: true)
        )
        struct Config: Decodable { let id: String }
        do {
            return try JSONDecoder().decode(Config.self, from: Data(result.stdout.utf8)).id
        } catch {
            throw ResticError.malformedOutput(detail: "cat config: \(error.localizedDescription)")
        }
    }

    /// Validates credentials when adding a repository. `false` when the
    /// repository does not exist yet.
    func repositoryExists(_ context: RepositoryContext, timeout: TimeInterval?) async throws -> Bool {
        do {
            _ = try await run(
                context,
                ResticInvocation(
                    arguments: ["cat", "config", "--json"],
                    timeout: timeout,
                    retainFullOutput: true
                )
            )
            return true
        } catch let ResticError.commandFailed(exitCode, _) where exitCode == ResticError.repositoryMissingCode {
            return false
        }
    }

    /// The new password goes through a file (restic has no other
    /// non-interactive way in), readable by this user alone, in a folder
    /// removed when the command ends. restic takes an exclusive lock: under
    /// another process's lock it fails at once with exit 11, and a current
    /// password it does not take fails with 12, both leaving the old key
    /// standing (checked on 0.19.1).
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
        _ = try await run(context, ResticInvocation(arguments: ["key", "passwd", "--json", "--new-password-file", file.path]))
    }

    func unlock(_ context: RepositoryContext) async throws {
        _ = try await run(context, ResticInvocation(arguments: ["unlock", "--json"]))
    }

    /// Lock-free, for `find`'s reasons.
    func stats(_ context: RepositoryContext, timeout: TimeInterval?) async throws -> RepositoryStats {
        let result = try await run(
            context,
            ResticInvocation(
                arguments: ["stats", "--json", "--mode", "raw-data", "--no-lock"],
                timeout: timeout,
                retainFullOutput: true
            )
        )
        return try Self.decoded("the size answer") {
            try ResticMessageDecoder.jsonDecoder.decode(RepositoryStats.self, from: Data(result.stdout.utf8))
        }
    }

    func check(_ context: RepositoryContext, readDataSubset: CheckDataSubset?) async throws -> ResticSummary? {
        var args = ["check", "--json"]
        if let readDataSubset {
            args += ["--read-data-subset=\(readDataSubset.argument)"]
        }
        let result = try await run(
            context,
            ResticInvocation(
                arguments: args,
                // A check that finds damage is the check doing its job. The
                // verdict must still name the damage: without an error count
                // the exit is a broken run, never a clean bill of health.
                allowedExitCodes: [0, Self.checkFoundDamageCode]
            )
        )
        let summary = result.summary
        if result.exitCode == Self.checkFoundDamageCode, (summary?.numErrors ?? 0) == 0 {
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
    /// `--json` does not cover `prune` (restic 0.19.1): its human-readable
    /// output is returned as text, which the run's log keeps and
    /// `pruneFreedBytes(in:)` reads. `onRawLine` gets each line as it
    /// arrives, so a UI can show the prune is still moving.
    func prune(
        _ context: RepositoryContext,
        onRawLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let args = ["prune"]
        let result = try await run(
            context,
            ResticInvocation(
                arguments: args,
                retainFullOutput: true
            ),
            onRawLine: onRawLine
        )
        return (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// From the "total prune:  12 blobs / 2.864 MiB" line (restic 0.19.1,
    /// binary units).
    static func pruneFreedBytes(in output: String) -> Int64? {
        let units: [String: Double] = ["B": 1, "KiB": 0x1p10, "MiB": 0x1p20, "GiB": 0x1p30, "TiB": 0x1p40]
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("total prune:") {
            guard let amount = line.split(separator: "/").last?.split(separator: " "),
                  amount.count == 2,
                  let value = Double(amount[0]),
                  let unit = units[String(amount[1])]
            else { return nil }
            return Int64((value * unit).rounded())
        }
        return nil
    }

    /// Any exit code is returned rather than thrown: the console shows
    /// whatever restic said, including its complaints.
    func runRaw(_ context: RepositoryContext, arguments: [String]) async throws -> String {
        let result = try await run(
            context,
            ResticInvocation(
                arguments: arguments,
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

    /// Lock-free, for `find`'s reasons.
    func snapshots(
        _ context: RepositoryContext,
        planID: UUID? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> [Snapshot] {
        var args = ["snapshots", "--json", "--no-lock"]
        if let planID { args += ["--tag", Self.planTag(planID)] }
        let result = try await run(
            context,
            ResticInvocation(
                arguments: args,
                timeout: timeout,
                retainFullOutput: true
            )
        )
        return try Self.decoded("the snapshot list") {
            try ResticMessageDecoder.decodeArray(Snapshot.self, from: result.stdout).sorted { $0.time > $1.time }
        }
    }

    /// `restic ls <id>` alone walks the whole tree; an absolute directory
    /// makes it list one level plus the directory itself, which is dropped
    /// here. Lock-free, for `find`'s reasons.
    func listDirectory(
        _ context: RepositoryContext,
        snapshotID: String,
        path: String
    ) async throws -> [SnapshotNode] {
        let result = try await run(context, ResticInvocation(arguments: ["ls", "--json", "--no-lock", snapshotID, path]))
        // The browse cache keeps a listing for good: a lost line must not
        // become a missing item.
        try Self.requireWhole(result, item: "node")
        let normalized = PathKey(ResticPath.normalized(path))
        var nodes: [SnapshotNode] = []
        for message in result.messages {
            guard case let .node(node) = message else { continue }
            let nodePath = ResticPath.normalized(node.path)
            guard PathKey(nodePath) != normalized else { continue }
            guard PathKey(ResticPath.parent(of: nodePath)) == normalized else { continue }
            nodes.append(node)
        }
        return Self.sortedForBrowser(nodes)
    }

    /// Shared by the live `ls` path and the browse-cache read, so a cached
    /// listing renders identically to a fetched one.
    static func sortedForBrowser(_ nodes: [SnapshotNode]) -> [SnapshotNode] {
        nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// The full-tree `ls` behind the index backfill. `retainMessages: false`
    /// keeps a snapshot's worth of nodes out of memory: the callback is the
    /// only delivery. `--no-lock`: a history walk is long and read-only, and
    /// even a shared lock would collide with retention's exclusive `forget`;
    /// a read that trips over a concurrently pruned pack fails and stays
    /// pending for a later pass.
    func walkSnapshot(
        _ context: RepositoryContext,
        snapshotID: String,
        onNode: @Sendable @escaping (SnapshotNode) -> Void
    ) async throws {
        let outcome = try await run(
            context,
            ResticInvocation(
                arguments: ["ls", "--json", "--no-lock", snapshotID],
                idleTimeout: Self.streamingIdleTimeout,
                retainMessages: false
            ),
            onMessage: { message in
                if case let .node(node) = message { onNode(node) }
            }
        )
        try Self.requireWhole(outcome, item: "node")
    }

    /// A `restic find` pattern matching `path` alone: unescaped, `a[1].txt`
    /// matches `a1.txt` and not itself. A full path also keeps restic's walk
    /// to that path's folders, where a name pattern walks whole trees.
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

    /// One walk per snapshot however many patterns, so a folder's files cost
    /// about what one does. `restic find` walks the trees, slower the more
    /// snapshots a repository holds, so the caller can narrow it (none
    /// named: every one). A named snapshot the repository no longer holds is
    /// skipped with a warning on stderr; the rest still answer (restic
    /// 0.19.1).
    ///
    /// `--no-lock`, as `listDirectory`, `walkDiff`, `snapshots` and `stats`,
    /// the reads a click runs. Locked, each would pay restic's 200 ms lock
    /// wait, fail at once with exit 11 while `forget` or `prune` held the
    /// exclusive lock, and lock a starting `forget` out the same way.
    func find(
        _ context: RepositoryContext,
        patterns: [String],
        ignoreCase: Bool = true,
        snapshotIDs: [String] = []
    ) async throws -> [FindResult] {
        var args = ["find", "--json", "--no-lock"]
        if ignoreCase { args.append("--ignore-case") }
        for id in snapshotIDs { args += ["--snapshot", id] }
        // A pattern starting with "-" is a pattern, not a flag.
        args.append("--")
        args += patterns

        let result = try await run(
            context,
            ResticInvocation(
                arguments: args,
                retainFullOutput: true
            )
        )
        return try Self.decoded("the find results") {
            try ResticMessageDecoder.decodeArray(FindResult.self, from: result.stdout).filter { !$0.matches.isEmpty }
        }
    }

    /// Feeds the index after each backup and the restore pane's Change
    /// column. The stream is unbounded, so the callback must consume
    /// incrementally. `+` means present only in `newer`. `--no-lock` for
    /// `walkSnapshot`'s reason.
    func walkDiff(
        _ context: RepositoryContext,
        olderID: String,
        newerID: String,
        onChange: @Sendable @escaping (ResticDiffChange) -> Void
    ) async throws {
        let outcome = try await run(
            context,
            ResticInvocation(
                arguments: ["diff", "--json", "--no-lock", olderID, newerID],
                idleTimeout: Self.streamingIdleTimeout,
                retainMessages: false
            ),
            onMessage: { message in
                if case let .change(change) = message { onChange(change) }
            }
        )
        try Self.requireWhole(outcome, item: "change")
    }

    /// A dropped line is an item the callback never saw, whatever the exit
    /// code said. Thrown after the stream, so what did decode has already
    /// been delivered.
    private static func requireWhole(_ outcome: ResticRunResult, item: String) throws {
        let malformed = outcome.malformedCount
        guard malformed > 0 else { return }
        throw ResticError.malformedOutput(
                        detail: "\(malformed) \(item) \(malformed == 1 ? "line" : "lines") did not decode"
        )
    }

    /// Blanks dropped, tilde expanded, each once, less any naming the source
    /// itself or a folder above it.
    private static func passedExcludes(_ stored: [String], source: String, home: String) -> [String] {
        let nonBlank = stored.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return BackupPlan.withoutDuplicates(nonBlank.map { expandTilde($0, home: home) })
            .filter { !pattern($0, covers: source) }
    }

    /// Component by component, `*` within one, as the rules the app offers
    /// are drawn. Such a pattern passed would leave nothing to back up: the
    /// startup disk's `/private/var/folders` over a plan inside it,
    /// `~/Library/Caches` over a plan of that folder. Against the path as
    /// given, as restic matches it (0.19.1, probed: `/private/var/folders`
    /// empties a backup of `/private/var/folders/…`, not one of
    /// `/var/folders/…`).
    static func pattern(_ pattern: String, covers source: String) -> Bool {
        guard pattern.hasPrefix("/") else { return false }
        let patternParts = pattern.split(separator: "/")
        let sourceParts = source.split(separator: "/")
        return patternParts.count <= sourceParts.count
            && zip(patternParts, sourceParts).allSatisfy { fnmatch(String($0), String($1), 0) == 0 }
    }

    func backup(
        _ context: RepositoryContext,
        plan: BackupPlan,
        onProgress: (@Sendable (OperationProgress) -> Void)? = nil
    ) async throws -> BackupOutcome {
        var args = ["backup", "--json"]
        let source = Self.expandTilde(plan.path, home: home)
        args.append(source)
        for pattern in Self.passedExcludes(plan.excludesToPass, source: source, home: home) {
            args += ["--exclude", pattern]
        }
        // As arguments, not an --exclude-file: restic expands $VAR in a
        // file's lines (0.19.1, probed: a folder named "a$HOME" stayed in).
        for marker in BackupPlan.excludeMarkers {
            args += ["--exclude-if-present", marker]
        }
        args += ["--exclude-caches", "--exclude-cloud-files"]
        args += ["--tag", Self.planTag(plan.id)]
        for tag in plan.tags where !tag.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["--tag", tag]
        }

        let result = try await run(
            context,
            ResticInvocation(
                arguments: args,
                allowedExitCodes: [0, ResticError.backupPartialSuccessCode],
                idleTimeout: Self.streamingIdleTimeout
            ),
            onMessage: Self.progressHandler(onProgress)
        )

        // A known message that failed to decode, or a missing summary, is a
        // reporting gap: the numbers may be wrong or unknown, and that must
        // not look clean. One line on the run record, beside the unreadable
        // items, never counted among them.
        let decodingWarning: String? = if result.malformedCount > 0 {
            "SwiftRestic couldn’t read \(result.malformedCount) of restic’s messages, so this backup’s numbers may be incomplete."
        } else if result.summary == nil {
            "The backup gave no summary, so its numbers are unknown."
        } else {
            nil
        }
        return BackupOutcome(
            summary: result.summary,
            itemErrors: Self.unreadableItems(errors: result.itemErrors, stderr: result.stderr),
            exitCode: result.exitCode,
            decodingWarning: decodingWarning,
            itemPaths: Self.unreadableItemPaths(errors: result.itemErrors, stderr: result.stderr)
        )
    }

    /// The sources restic skipped, verbatim, then its error events
    /// deduplicated by item (first message wins; an event without an item is
    /// keyed by its message).
    ///
    /// Observed on restic 0.19.1: a folder it cannot list arrives twice,
    /// `during: scan` and `during: archival`, with the identical item, so
    /// events are deduplicated, not counted. A missing or inaccessible
    /// source arrives as no event at all, only stderr text (the
    /// `skipSuffixes`) before exit 3: the case that drops a whole top-level
    /// folder, and the only unreadable item restic names outside JSON. Those
    /// lines are written before archival starts, so they always fall inside
    /// the runner's retained head of stderr. A reworded restic degrades to
    /// an unnamed exit 3, never to a complete snapshot, because the exit
    /// code alone decides that.
    static func unreadableItems(errors: [ResticErrorMessage], stderr: String) -> [String] {
        unreadableEntries(errors: errors, stderr: stderr).map(\.line)
    }

    /// An event's item, or the source a skip line names; a line naming none
    /// is absent. Stored on the run so the fixes that act on an item (Show
    /// in Finder, Exclude) never parse restic's free text.
    static func unreadableItemPaths(errors: [ResticErrorMessage], stderr: String) -> [PathKey: String] {
        var paths: [PathKey: String] = [:]
        for entry in unreadableEntries(errors: errors, stderr: stderr) {
            if let path = entry.path { paths[PathKey(entry.line)] = path }
        }
        return paths
    }

    /// restic's words after a source it skipped (0.19.1).
    static let missingSourceSuffix = " does not exist, skipping"
    static let inaccessibleSourceSuffix = " cannot be accessed, skipping"
    private static let skipSuffixes = [missingSourceSuffix, inaccessibleSourceSuffix]

    private static func unreadableEntries(errors: [ResticErrorMessage], stderr: String) -> [(line: String, path: String?)] {
        // By bytes, as the index keys paths: an NFC and an NFD spelling of
        // one name are two items.
        var seen: Set<PathKey> = []
        var entries: [(line: String, path: String?)] = []
        for line in stderr.split(whereSeparator: \.isNewline).map(String.init) {
            guard let path = skipSuffixes.lazy.compactMap({ line.removingByteSuffix($0) }).first else { continue }
            if seen.insert(PathKey(line)).inserted { entries.append((line, path)) }
        }
        for error in errors {
            // Without restic's trailing newline, and keyed by the same text,
            // so an item-less message with and without one is one line.
            let line = RunRecord.storedItemError(error.item.map { "\($0): \(error.message)" } ?? error.message)
            if seen.insert(PathKey(error.item ?? line)).inserted { entries.append((line, error.item)) }
        }
        return entries
    }

    static func forgetArguments(plan: BackupPlan) -> [String] {
        let keep = plan.retention.forgetArguments
        // restic reads `forget` with no `--keep-*` rule as "delete every
        // snapshot".
        precondition(!keep.isEmpty, "retention has no --keep-* rule")
        return ["forget", "--json", "--tag", planTag(plan.id)] + keep
    }

    @discardableResult
    func forget(_ context: RepositoryContext, plan: BackupPlan) async throws -> Int {
        let args = Self.forgetArguments(plan: plan)

        let result = try await run(
            context,
            ResticInvocation(
                arguments: args,
                // Read below, never a success.
                allowedExitCodes: [0, Self.forgetRemovalRefusedCode],
                retainFullOutput: true
            )
        )
        guard result.exitCode == 0 else { throw Self.removalFailure(result) }
        return try Self.countRemoved(forgetOutput: result.stdout)
    }

    /// restic 0.19.1 prints its JSON first (every snapshot retention chose
    /// under "remove", deleted or not), then one "unable to remove
    /// snapshot/<id> from the repository" line per snapshot it could not
    /// delete, so the ones that went are the difference; its `--prune` is
    /// then skipped, so the space waits for the next Free Up Space. Without
    /// those lines, or with JSON that does not decode, it stays restic's
    /// failure: no count is claimed unread.
    static func removalFailure(_ result: ResticRunResult) -> ResticError {
        let lines = result.stderr.split(separator: "\n")
        let refused = lines.filter { $0.hasPrefix("unable to remove snapshot/") }.count
        guard refused > 0, let chosen = try? countRemoved(forgetOutput: result.stdout) else {
            return .commandFailed(exitCode: result.exitCode, message: result.failureMessage)
        }
        // "Remove(<snapshot/860f8ac74b>) failed: unexpected HTTP response
        // (403): 403 Forbidden": its last part names the cause.
        let reason = lines.first { $0.hasPrefix("Remove(") && $0.contains(") failed: ") }
            .flatMap { $0.components(separatedBy: ": ").last } ?? ""
        return .snapshotsNotRemoved(removed: max(0, chosen - refused), refused: refused, reason: reason)
    }

    /// Undecodable output throws rather than reading as zero: "removed 0
    /// snapshots" is a claim about the user's history, and a restic update
    /// that changed the shape must surface. Empty output is zero: restic had
    /// nothing to report.
    static func countRemoved(forgetOutput: String) throws -> Int {
        let trimmed = forgetOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let unreadable = ResticError.malformedOutput(detail: "couldn’t read the removal count from restic’s answer")
        guard let data = trimmed.data(using: .utf8),
              let groups = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { throw unreadable }
        // restic's nothing-removed is `"remove":null` (NSNull here); a group
        // with no key at all is a changed shape.
        return try groups.reduce(0) { total, group in
            guard let remove = group["remove"] else { throw unreadable }
            return total + ((remove as? [Any])?.count ?? 0)
        }
    }

    enum StagedFileCommit: Equatable {
        case committed
        /// The target was taken; the staged output is left for the caller
        /// to remove.
        case keptExisting
    }

    /// `rename(2)` when it may replace what is there,
    /// `renamex_np(RENAME_EXCL)` otherwise. `renameExclusive` answers 0 or
    /// the errno; a parameter so tests reach the volumes that refuse the
    /// flag without mounting one.
    static func commitStagedFile(
        _ staging: URL,
        to target: URL,
        replacingExisting: Bool,
        renameExclusive: (String, String) -> Int32 = { from, to in
            renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : Darwin.errno
        }
    ) throws -> StagedFileCommit {
        func moveFailed(_ failure: Int32) -> ResticError {
            .stagedFileMoveFailed(path: target.path, reason: String(cString: Darwin.strerror(failure)))
        }
        if replacingExisting {
            guard Darwin.rename(staging.path, target.path) == 0 else { throw moveFailed(Darwin.errno) }
            return .committed
        }
        switch renameExclusive(staging.path, target.path) {
        case 0:
            return .committed
        case EEXIST:
            return .keptExisting
        case ENOTSUP:
            // A volume without VOL_CAP_INT_RENAME_EXCL refuses the flag even
            // for a free name (exFAT does). Look, then rename; lstat, so a
            // dangling symlink counts as taken. The gap between the two is
            // the one non-atomic window, and only on such volumes.
            if (try? FileManager.default.attributesOfItem(atPath: target.path)) != nil {
                return .keptExisting
            }
            guard Darwin.rename(staging.path, target.path) == 0 else { throw moveFailed(Darwin.errno) }
            return .committed
        case let failure:
            throw moveFailed(failure)
        }
    }


    /// Restores one node into `destinationDirectory`, without recreating the
    /// original absolute path above it.
    ///
    /// A directory goes through `restic restore <id>:<path>`, which makes
    /// the subtree the output's root. A single file goes through
    /// `restoreItems` into a hidden folder beside its landing, so it keeps
    /// the dates, permissions and extended attributes restic recorded. Not
    /// `restic dump`: it writes the bytes alone, with the restore's own time
    /// as modified date.
    ///
    /// `overwrite` always reaches restic explicitly, even Replace's `always`
    /// (restic's default), so the logged command line says what was asked.
    /// Replace is `always`, never `if-changed`, which trusts size and
    /// modification time. Keep is `never`, not an absolute keep: it deletes
    /// a file standing where the backup has a same-named folder, and gives
    /// an existing folder the backed-up permissions and dates. The landing
    /// itself is safe: a file there is refused before restic runs.
    ///
    /// The file branch keeps and replaces in-app: restic rewrites an
    /// existing file in place, so a failed or cancelled restore straight
    /// onto the landing would leave a file that is neither the user's nor
    /// the backed-up one. Under Keep an existing landing skips restic
    /// entirely, and the rename after restic refuses a name that appeared
    /// while it ran.
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

        let target = Self.restoredItemURL(named: node.name, in: destinationDirectory)
        if node.isDirectory {
            try Self.refuseFileInTheWay(of: target)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            return try await runRestore(
                context,
                arguments: ["\(snapshotID):\(node.path)", "--target", target.path] + overwrite.resticArguments,
                onProgress: onProgress
            )
        }

        // lstat, not fileExists: a dangling symlink holds the name too. The
        // check spares the download; the commit below closes the window.
        if overwrite == .keepExisting, RestoreDestinationRules.itemExists(at: target) {
            RunTranscript.current?.note("Kept the file already at \(target.path); restic did not run.")
            return Self.keptFileSummary()
        }
        // As `restoreItems` refuses before its restic runs: a folder at the
        // landing would otherwise cost the whole transfer and fail only at
        // the commit, with "Is a directory".
        if overwrite == .replaceExisting, RestoreDestinationRules.isFolder(at: target) {
            throw ResticError.folderInTheWay(path: target.path)
        }
        // Beside the landing, so the commit is a rename on one volume; what
        // the commit did not take goes with the folder. Not named after the
        // file: a name near APFS's 255-byte limit would leave no room for
        // the rest.
        let staging = destinationDirectory.appendingPathComponent(
            ".\(UUID().uuidString).partial",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: staging) }
        let summary = try await restoreItems(
            context,
            snapshotID: snapshotID,
            parent: ResticPath.parent(of: node.path),
            nodes: [node],
            destinationDirectory: staging,
            overwrite: overwrite,
            onProgress: onProgress
        )
        switch try Self.commitStagedFile(
            Self.restoredItemURL(named: node.name, in: staging),
            to: target,
            replacingExisting: overwrite == .replaceExisting
        ) {
        case .committed:
            return summary
        case .keptExisting:
            RunTranscript.current?.note("Kept the file that appeared at \(target.path) during the restore; the restored copy was discarded.")
            return Self.keptFileSummary()
        }
    }

    /// Each item lands directly inside `destinationDirectory`, where
    /// `restore(node:)` would put it alone, in one `restic restore
    /// <id>:<parent> --include …` call. One process is the point: each
    /// process reloads the repository's index, so per-item processes are far
    /// slower, a remote index most of all. The target directory keeps its
    /// own permissions and dates: restic gives `<parent>`'s to nothing.
    ///
    /// Landings are checked before restic runs. restic deletes a file
    /// standing where a restored folder goes, under Keep too, so that is
    /// refused, and each folder's landing is created first. Under Replace
    /// restic fails on a folder standing where a restored file goes, after
    /// taking that folder's permissions away, so that is refused; under Keep
    /// it leaves the folder and counts the file kept, as `restore(node:)`
    /// does.
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
        let landings = nodes.map { Self.restoredItemURL(named: $0.name, in: destinationDirectory) }
        // Two passes: every refusal comes before any landing is created, so
        // a refused restore leaves the destination as it stood.
        for (node, landing) in zip(nodes, landings) {
            if node.isDirectory {
                try Self.refuseFileInTheWay(of: landing)
                continue
            }
            guard overwrite == .replaceExisting else { continue }
            if RestoreDestinationRules.isFolder(at: landing) {
                throw ResticError.folderInTheWay(path: landing.path)
            }
        }
        for (node, landing) in zip(nodes, landings) where node.isDirectory {
            try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        }
        let summary = try await runRestore(
            context,
            arguments: ["\(snapshotID):\(parent)", "--target", destinationDirectory.path]
                + nodes.flatMap { ["--include", RestoreBatch.includePattern(forName: $0.name)] }
                + overwrite.resticArguments,
            onProgress: onProgress
        )
        // restic 0.19.1 exits 0 when an --include matches nothing, as the
        // U+FFFD spelling `ls --json` gives a name that is not UTF-8 does.
        let missing = landings.filter { !RestoreDestinationRules.itemExists(at: $0) }
        guard missing.isEmpty else { throw ResticError.notRestored(paths: missing.map(\.path)) }
        return summary
    }

    private static func decoded<T>(_ what: String, _ decode: () throws -> T) throws -> T {
        do {
            return try decode()
        } catch {
            throw ResticError.malformedOutput(detail: "\(what) couldn’t be read: \(ResticMessageDecoder.briefFailure(error))")
        }
    }

    /// Refuses a folder's landing held (lstat) by anything but a folder.
    /// A symlink counts even when it resolves to a folder: restic 0.19.1
    /// replaces the link with a new folder, under `--overwrite never` too.
    private static func refuseFileInTheWay(of landing: URL) throws {
        if RestoreDestinationRules.itemExists(at: landing), !RestoreDestinationRules.isFolder(at: landing) {
            throw ResticError.fileInTheWay(path: landing.path)
        }
    }

    /// The callers also note it in the run's log, which would otherwise hold
    /// no command at all.
    private static func keptFileSummary() -> ResticSummary {
        var summary = ResticSummary()
        summary.filesRestored = 0
        summary.filesSkipped = 1
        return summary
    }

    /// Internal for the test target's `restoreWholeSnapshot`; production
    /// restores all go through `restore` and `restoreItems`.
    func runRestore(
        _ context: RepositoryContext,
        arguments: [String],
        onProgress: (@Sendable (OperationProgress) -> Void)?
    ) async throws -> ResticSummary? {
        let result = try await run(
            context,
            ResticInvocation(
                arguments: ["restore", "--json"] + arguments,
                idleTimeout: Self.streamingIdleTimeout
            ),
            onMessage: Self.progressHandler(onProgress)
        )
        return result.summary
    }

    private static func progressHandler(
        _ onProgress: (@Sendable (OperationProgress) -> Void)?
    ) -> @Sendable (ResticMessage) -> Void {
        { message in
            if case let .status(status) = message {
                onProgress?(OperationProgress(status: status))
            }
        }
    }

    /// The one landing rule, shared by both restore branches, the drag path
    /// and the run record's destination, so Show in Finder selects exactly
    /// what the restore wrote.
    static func restoredItemURL(named name: String, in directory: URL) -> URL {
        directory.appendingPathComponent(sanitizedRestoreName(name))
    }

    /// The names come from the snapshot, which a hostile writer to a shared
    /// repository can fill with anything, and `appendingPathComponent` would
    /// walk out of the destination on `/` or `..`: reduced to the last
    /// component, with the traversal spellings replaced.
    static func sanitizedRestoreName(_ name: String) -> String {
        var component = (name as NSString).lastPathComponent
        // Foundation answers "/" for "/", which would aim the write at the
        // destination directory itself.
        if component.isEmpty || component == "." || component == ".." || component == "/" {
            component = "restored"
        }
        return component
    }

    /// restic does not expand `~`; the shell normally would. NSString, not
    /// pure Swift: `~user` has no pure-Swift spelling, and its tidying (a
    /// trailing or doubled slash dropped) is what every caller compares. A
    /// `home` other than the real one re-roots `~` and `~/…` for the tests;
    /// a typed `~user/…` stays NSString's.
    static func expandTilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard path.hasPrefix("~") else { return path }
        let expanded = (path as NSString).expandingTildeInPath
        let realHome = NSHomeDirectory()
        guard home != realHome, path == "~" || path.hasPrefix("~/") else { return expanded }
        precondition(expanded.hasPrefix(realHome), "NSString expanded \(path) to \(expanded), outside \(realHome)")
        return home + expanded.dropFirst(realHome.count)
    }
}
