import Foundation
import Testing

/// The restic the app ships. `Tools/fetch-restic.sh`, run by build.sh and the
/// app's build phase, puts it in `.build`.
enum PinnedRestic {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func version() throws -> String {
        let script = try String(contentsOf: repositoryRoot.appendingPathComponent("Tools/fetch-restic.sh"), encoding: .utf8)
        let line = try #require(script.split(separator: "\n").first { $0.hasPrefix("version=") })
        return String(line.dropFirst("version=".count))
    }

    static func binary() throws -> ResticBinary {
        ResticBinary(url: repositoryRoot.appendingPathComponent(".build/restic/\(try version())/restic"))
    }

    static func service() throws -> ResticService {
        ResticService(runner: ResticRunner(), binary: try binary().url)
    }
}

@Suite("restic under test")
struct ResticUnderTestTests {
    @Test("the restic under test is the pinned release")
    func versionIsThePinnedOne() async throws {
        let output = try await PinnedRestic.service().version()
        #expect(output.hasPrefix("restic \(try PinnedRestic.version()) "), "\(output)")
    }
}

/// The repository is not initialized — each suite does that itself, so a
/// test can pin the not-yet-a-repository state first. Each suite keeps its
/// own prefix and password, so a leaked directory or a cross-suite password
/// mixup stays attributable.
struct ResticFixture {
    var root: URL
    var sourceDirectory: URL
    var context: RepositoryContext
    var service: ResticService
    var plan: BackupPlan
}

func makeResticFixture(
    prefix: String,
    password: String,
    plant: (URL) throws -> Void = { _ in }
) throws -> ResticFixture {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftRestic\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    // /var/folders is a symlink to /private/var/folders; restic records the
    // resolved path, so resolve here or every path comparison is off by one.
    let root = base.resolvingSymlinksInPath()

    let sourceDirectory = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try plant(sourceDirectory)

    var repository = Repository()
    repository.kind = .local
    repository.localPath = root.appendingPathComponent("repo").path

    var plan = BackupPlan()
    plan.repositoryID = repository.id
    plan.path = sourceDirectory.path
    plan.skipNothing()

    return ResticFixture(
        root: root,
        sourceDirectory: sourceDirectory,
        context: RepositoryContext(repository: repository, password: password),
        service: try PinnedRestic.service(),
        plan: plan
    )
}

@Suite("restic integration", .serialized)
struct ResticIntegrationTests {
    private static let password = "integration-test-password"

    private func makeFixture() throws -> ResticFixture {
        try makeResticFixture(prefix: "Tests", password: Self.password) { source in
            let subDirectory = source.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: subDirectory, withIntermediateDirectories: true)
            try "hello world".write(
                to: source.appendingPathComponent("a.txt"),
                atomically: true,
                encoding: .utf8
            )
            try Data(repeating: 7, count: 200_000).write(
                to: source.appendingPathComponent("big.bin")
            )
            try "nested".write(
                to: subDirectory.appendingPathComponent("b.txt"),
                atomically: true,
                encoding: .utf8
            )
            // A name whose first character is a combining mark: the separator
            // before it merges into one grapheme, so any Character-level path
            // arithmetic silently drops the file from a directory listing.
            try "combining".write(
                to: source.appendingPathComponent("\u{0301}leading.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    @Test("init, backup, list, browse and restore against a real repository")
    func endToEnd() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(try await fixture.service.repositoryExists(fixture.context, timeout: nil) == false)

        let repositoryID = try await fixture.service.initializeRepository(fixture.context)
        #expect(repositoryID != nil)
        #expect(try await fixture.service.repositoryExists(fixture.context, timeout: nil))

        let outcome = try await fixture.service.backup(fixture.context, plan: fixture.plan)
        #expect(outcome.exitCode == 0)
        #expect(outcome.summary?.snapshotID != nil)
        #expect(outcome.summary?.filesNew == 4)
        #expect(outcome.summary?.totalBytesProcessed == 200_026)

        // The plan tag has to survive the round trip, or per-plan retention would
        // operate on the wrong snapshots.
        let snapshots = try await fixture.service.snapshots(fixture.context, planID: fixture.plan.id)
        #expect(snapshots.count == 1)
        let snapshot = try #require(snapshots.first)
        #expect(snapshot.tags.contains(ResticService.planTag(fixture.plan.id)))
        #expect(snapshot.paths == [fixture.sourceDirectory.path])

        // Browsing must yield exactly one level, not the whole recursive tree.
        let children = try await fixture.service.listDirectory(
            fixture.context,
            snapshotID: snapshot.id,
            path: fixture.sourceDirectory.path
        )
        // The combining-mark name sorts after the plain letters — the order
        // localizedStandardCompare actually produces, pinned here so a
        // collation change is seen, not silently absorbed.
        #expect(children.map(\.name) == ["sub", "a.txt", "big.bin", "\u{0301}leading.txt"])
        #expect(children.first { $0.name == "\u{0301}leading.txt" } != nil)
        #expect(children.first { $0.name == "a.txt" }?.size == 11)
        #expect(children.first { $0.name == "sub" }?.isDirectory == true)

        // Restoring one file writes exactly that file, with no path prefix above it.
        let fileDestination = fixture.root.appendingPathComponent("restore-file")
        let fileNode = try #require(children.first { $0.name == "a.txt" })
        _ = try await fixture.service.restore(
            fixture.context,
            snapshotID: snapshot.id,
            node: fileNode,
            destinationDirectory: fileDestination,
            overwrite: .replaceExisting
        )
        let restoredFile = fileDestination.appendingPathComponent("a.txt")
        #expect(try String(contentsOf: restoredFile, encoding: .utf8) == "hello world")

        let dirDestination = fixture.root.appendingPathComponent("restore-dir")
        let dirNode = try #require(children.first { $0.name == "sub" })
        let summary = try await fixture.service.restore(
            fixture.context,
            snapshotID: snapshot.id,
            node: dirNode,
            destinationDirectory: dirDestination,
            overwrite: .replaceExisting
        )
        #expect(summary?.filesRestored == 1)
        let restoredNested = dirDestination
            .appendingPathComponent("sub")
            .appendingPathComponent("b.txt")
        #expect(try String(contentsOf: restoredNested, encoding: .utf8) == "nested")

        // Whole-snapshot restore keeps the original absolute layout instead.
        let wholeDestination = fixture.root.appendingPathComponent("restore-all")
        _ = try await fixture.service.restoreWholeSnapshot(
            fixture.context,
            snapshotID: snapshot.id,
            destinationDirectory: wholeDestination,
            overwrite: .replaceExisting
        )
        let rebuilt = wholeDestination.appendingPathComponent(
            fixture.sourceDirectory.path
        ).appendingPathComponent("a.txt")
        #expect(FileManager.default.fileExists(atPath: rebuilt.path))
    }

    @Test("a backup's snapshot carries the plan tag and the plan's own tags")
    func planTagsReachTheSnapshot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)
        var plan = fixture.plan
        plan.tags = ["work"]

        _ = try await fixture.service.backup(fixture.context, plan: plan)

        let snapshot = try #require(try await fixture.service.snapshots(fixture.context).first)
        #expect(snapshot.tags.sorted() == [ResticService.planTag(plan.id), "work"].sorted(), "the snapshot's tags: \(snapshot.tags)")
    }

    @Test("retention deletes only the plan's own extra snapshots")
    func retention() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        for index in 0 ..< 3 {
            try "change \(index)".write(
                to: fixture.sourceDirectory.appendingPathComponent("a.txt"),
                atomically: true,
                encoding: .utf8
            )
            _ = try await fixture.service.backup(fixture.context, plan: fixture.plan)
        }
        var otherPlan = fixture.plan
        otherPlan.id = UUID()
        _ = try await fixture.service.backup(fixture.context, plan: otherPlan)

        var plan = fixture.plan
        plan.retention = RetentionPolicy(
            isEnabled: true,
            keepLast: 1,
            keepHourly: 0,
            keepDaily: 0,
            keepWeekly: 0,
            keepMonthly: 0,
            keepYearly: 0
        )
        let removed = try await fixture.service.forget(fixture.context, plan: plan)
        #expect(removed == 2)

        #expect(try await fixture.service.snapshots(fixture.context, planID: plan.id).count == 1)
        #expect(try await fixture.service.snapshots(fixture.context, planID: otherPlan.id).count == 1)
        #expect(try await fixture.service.snapshots(fixture.context).count == 2)
    }

    @Test("a forget the repository refuses reads as refused, never as removed")
    func refusedForgetIsNotARemoval() async throws {
        let fixture = try makeFixture()
        let snapshotsFolder = URL(fileURLWithPath: fixture.context.repository.localPath).appendingPathComponent("snapshots")
        var lockedFile: URL?
        defer {
            // Undone before the cleanup, which neither can get past.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snapshotsFolder.path)
            if let lockedFile { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: lockedFile.path) }
            try? FileManager.default.removeItem(at: fixture.root)
        }
        _ = try await fixture.service.initializeRepository(fixture.context)
        for index in 0 ..< 3 {
            try "change \(index)".write(
                to: fixture.sourceDirectory.appendingPathComponent("a.txt"),
                atomically: true,
                encoding: .utf8
            )
            _ = try await fixture.service.backup(fixture.context, plan: fixture.plan)
        }
        var plan = fixture.plan
        plan.retention = RetentionPolicy(
            isEnabled: true, keepLast: 1, keepHourly: 0, keepDaily: 0,
            keepWeekly: 0, keepMonthly: 0, keepYearly: 0
        )

        // Every deletion refused, as an append-only server's 403 refuses
        // them: restic 0.19.1 prints its JSON, which still lists both as
        // removed, then exits 3, "failed to remove one or more snapshots".
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: snapshotsFolder.path)
        // restic 0.19.1 races when two refusals land at once: "fatal error:
        // concurrent map writes" (cmd_forget.go:318), exit 2, its lock left
        // behind. Fixed upstream in restic 9da3b87b, in no release yet. Both
        // refused, nothing was removed, so the forget runs again.
        func forgetPastRacingRefusals() async throws {
            for _ in 1 ..< 3 {
                do {
                    try await fixture.service.forget(fixture.context, plan: plan)
                    return
                } catch let ResticError.commandFailed(_, message) where message.contains("fatal error: concurrent map writes") {
                    try await fixture.service.unlock(fixture.context)
                }
            }
            try await fixture.service.forget(fixture.context, plan: plan)
        }
        await #expect(throws: ResticError.snapshotsNotRemoved(removed: 0, refused: 2, reason: "permission denied")) {
            try await forgetPastRacingRefusals()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snapshotsFolder.path)
        #expect(try await fixture.service.snapshots(fixture.context, planID: plan.id).count == 3)

        // One of the two refused, as an object lock keeps a recent snapshot:
        // the other goes, and the count says so.
        let oldest = try #require(
            try await fixture.service.snapshots(fixture.context, planID: plan.id).min { $0.time < $1.time }
        )
        lockedFile = snapshotsFolder.appendingPathComponent(oldest.id)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: snapshotsFolder.appendingPathComponent(oldest.id).path)
        await #expect(throws: ResticError.snapshotsNotRemoved(removed: 1, refused: 1, reason: "operation not permitted")) {
            try await fixture.service.forget(fixture.context, plan: plan)
        }
        #expect(try await fixture.service.snapshots(fixture.context, planID: plan.id).map(\.id).contains(oldest.id))
        #expect(try await fixture.service.snapshots(fixture.context, planID: plan.id).count == 2)
    }

    @Test("keep-last 1 per plan keeps exactly each plan's newest snapshot ID")
    func retentionKeepsExactIDs() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        func runPlan(_ plan: BackupPlan) async throws -> String {
            try "change \(UUID().uuidString)".write(
                to: fixture.sourceDirectory.appendingPathComponent("a.txt"),
                atomically: true,
                encoding: .utf8
            )
            let outcome = try await fixture.service.backup(fixture.context, plan: plan)
            return try #require(outcome.summary?.snapshotID)
        }

        var planB = fixture.plan
        planB.id = UUID()
        planB.tags = ["other"]

        var newest: [BackupPlan: String] = [:]
        for plan in [fixture.plan, planB] {
            for _ in 0 ..< 3 {
                newest[plan] = try await runPlan(plan)
            }
        }

        // keep-last 1 applied to each plan in turn: the two survivors must be
        // exactly the newest snapshot of each group, not just some two snapshots.
        let keepOne = RetentionPolicy(
            isEnabled: true, keepLast: 1, keepHourly: 0, keepDaily: 0,
            keepWeekly: 0, keepMonthly: 0, keepYearly: 0
        )
        var trimming = fixture.plan
        var trimmingB = planB
        trimming.retention = keepOne
        trimmingB.retention = keepOne
        #expect(try await fixture.service.forget(fixture.context, plan: trimming) == 2)
        #expect(try await fixture.service.forget(fixture.context, plan: trimmingB) == 2)

        let survivors = try await fixture.service.snapshots(fixture.context).map(\.id).sorted()
        #expect(survivors == [newest[fixture.plan], newest[planB]].compactMap { $0 }.sorted())
    }

    @Test("an empty retention policy is refused before restic ever sees it")
    func emptyRetentionIsNotRun() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)
        _ = try await fixture.service.backup(fixture.context, plan: fixture.plan)

        var plan = fixture.plan
        plan.retention = RetentionPolicy(
            isEnabled: true,
            keepLast: 0, keepHourly: 0, keepDaily: 0,
            keepWeekly: 0, keepMonthly: 0, keepYearly: 0
        )
        #expect(try await fixture.service.forget(fixture.context, plan: plan) == 0)
        #expect(try await fixture.service.snapshots(fixture.context).count == 1)
    }

    @Test("the retention preview is a dry run that works while a backup holds the lock")
    func retentionPreviewIsDryAndLockFree() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        var planIDs: [String] = []
        for index in 0 ..< 3 {
            try "change \(index)".write(
                to: fixture.sourceDirectory.appendingPathComponent("a.txt"),
                atomically: true,
                encoding: .utf8
            )
            let outcome = try await fixture.service.backup(fixture.context, plan: fixture.plan)
            planIDs.append(try #require(outcome.summary?.snapshotID))
        }
        var otherPlan = fixture.plan
        otherPlan.id = UUID()
        let otherOutcome = try await fixture.service.backup(fixture.context, plan: otherPlan)
        let other = try #require(otherOutcome.summary?.snapshotID)

        var plan = fixture.plan
        plan.retention = RetentionPolicy(
            isEnabled: true, keepLast: 1, keepHourly: 0, keepDaily: 0,
            keepWeekly: 0, keepMonthly: 0, keepYearly: 0
        )

        // A backup of its own holds a lock while the preview runs — the
        // situation a user opening the sheet mid-backup is in.
        let holder = try await Self.holdLock(on: fixture)
        // A failed expectation must not leave restic holding the lock.
        defer { holder.stop() }

        let preview = try await fixture.service.forgetPreview(fixture.context, plan: plan)
        #expect(Set(preview.removed.map(\.id)) == Set(planIDs.prefix(2)))
        #expect(preview.kept.map(\.id) == [planIDs[2]])
        #expect(!(preview.kept + preview.removed).contains { $0.id == other })

        // The control: the real forget needs the exclusive lock, so the lock
        // the preview read past is real.
        do {
            try await fixture.service.forget(fixture.context, plan: plan)
            Issue.record("forget ran while a backup held the repository")
        } catch let error as ResticError {
            guard case let .commandFailed(code, _) = error, code == 11 else {
                Issue.record("expected commandFailed(11), got \(error)")
                return
            }
        }

        // Let the holder finish: at the end of its input restic writes its
        // untagged snapshot and releases the lock on its own.
        try holder.feed.fileHandleForWriting.close()
        await Self.waitForExit(holder.process, within: 120)
        #expect(!holder.process.isRunning, "the holder did not finish after its input ended")
        #expect(try await fixture.service.snapshots(fixture.context, planID: plan.id).count == 3)
    }

    @MainActor
    private func adoptableModel(fixture: ResticFixture, repository: Repository) async throws -> AppModel {
        let model = AppModel(
            store: ConfigStore(directory: fixture.root.appendingPathComponent("config")),
            secrets: .inMemory([repository.id: (password: Self.password, providerSecret: nil)])
        )
        model.resticState = .ready(try PinnedRestic.binary(), version: "")
        model.configuration.repositories = [repository]
        model.snapshots[repository.id] = try await fixture.service.snapshots(fixture.context)
        return model
    }

    @MainActor
    @Test("adopting a group writes nothing to the repository and reshelves it under the new plan")
    func adoptingWritesNothingAndReshelves() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        // Two backups one plan made, and no plan configured anywhere — the
        // group sits under Other backups waiting to be adopted.
        let plan = fixture.plan
        for index in 0 ..< 2 {
            try "change \(index)".write(
                to: fixture.sourceDirectory.appendingPathComponent("a.txt"),
                atomically: true,
                encoding: .utf8
            )
            _ = try await fixture.service.backup(fixture.context, plan: plan)
            try await Task.sleep(for: .milliseconds(1100))
        }

        var repository = Repository()
        repository.kind = .local
        repository.localPath = fixture.root.appendingPathComponent("repo").path
        let model = try await adoptableModel(fixture: fixture, repository: repository)

        // The repository's own answer, read raw: adopting must leave this
        // byte-identical.
        func rawSnapshots() async throws -> String {
            try await fixture.service.runner.run(
                binary: fixture.service.binary,
                invocation: ResticInvocation(
                    arguments: fixture.context.globalArguments + ["snapshots", "--json"],
                    environment: fixture.context.environment,
                    retainFullOutput: true
                )
            ).stdout
        }
        let before = try await rawSnapshots()

        #expect(model.shelves(for: repository.id).orphanPlanGroup(plan.id) != nil)
        let draft = try #require(await model.adoptDraft(repositoryID: repository.id, planID: plan.id))
        // A plan is called by its path: the backup's own folder.
        #expect(model.label(of: draft) == "source")
        #expect(draft.path == fixture.sourceDirectory.path)
        // The folder exists on this Mac, so the schedule dares to be Daily.
        #expect(draft.schedule.frequency == .daily)

        model.adopt(draft: draft)

        #expect(model.configuration.plans.map(\.id) == [plan.id])
        #expect(model.configuration.runs.isEmpty)
        let shelves = model.shelves(for: repository.id)
        #expect(shelves.others.isEmpty)
        #expect(shelves.byPlan[plan.id]?.count == 2)

        let after = try await rawSnapshots()
        #expect(after == before)
    }

    @MainActor
    @Test("a dry run answers with the plan it is given, unsaved, and removes nothing")
    func adoptDraftPreviewAnswersForTheDraft() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        let plan = fixture.plan
        for index in 0 ..< 2 {
            try "change \(index)".write(
                to: fixture.sourceDirectory.appendingPathComponent("a.txt"),
                atomically: true,
                encoding: .utf8
            )
            _ = try await fixture.service.backup(fixture.context, plan: plan)
            try await Task.sleep(for: .milliseconds(1100))
        }

        var repository = Repository()
        repository.kind = .local
        repository.localPath = fixture.root.appendingPathComponent("repo").path
        let model = try await adoptableModel(fixture: fixture, repository: repository)

        var draft = try #require(await model.adoptDraft(repositoryID: repository.id, planID: plan.id))
        // The policy is set in the draft alone: the plan is not saved, so the
        // draft itself travels to restic.
        #expect(draft.retention == BackupPlan().retention)
        draft.retention = RetentionPolicy(
            isEnabled: true, keepLast: 1, keepHourly: 0, keepDaily: 0,
            keepWeekly: 0, keepMonthly: 0, keepYearly: 0
        )
        let preview = try await model.previewRetention(plan: draft)
        #expect(preview.kept.count == 1)
        #expect(preview.removed.count == 1)
        #expect(preview.outcomeLine == "At the next backup, 2 backups become 1.")
        #expect(try await fixture.service.snapshots(fixture.context, planID: plan.id).count == 2)
    }

    /// A restic backup holding the fixture repository's lock. It reads its
    /// file from a pipe the test holds open, so the lock stays for as long as
    /// the test takes, however slowly restic runs.
    private struct LockHolder {
        var process: Process
        var feed: Pipe

        func stop() {
            try? feed.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
    }

    private static func holdLock(on fixture: ResticFixture) async throws -> LockHolder {
        let process = Process()
        process.executableURL = try PinnedRestic.binary().url
        process.arguments = ["backup", "--stdin", "--stdin-filename", "hold"]
        var environment = ProcessInfo.processInfo.environment
        environment["RESTIC_REPOSITORY"] = fixture.root.appendingPathComponent("repo").path
        environment["RESTIC_PASSWORD"] = Self.password
        process.environment = environment
        let feed = Pipe()
        process.standardInput = feed
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let holder = LockHolder(process: process, feed: feed)
        // One byte: with none, restic reports "no data read" (exit 3) at
        // the end of input, though it still saves and unlocks.
        do {
            try feed.fileHandleForWriting.write(contentsOf: Data("x".utf8))
            let locks = fixture.root.appendingPathComponent("repo/locks")
            // Waits on restic's own start — key derivation and the repository
            // open — which load stretches.
            let lockDeadline = Date.now.addingTimeInterval(120)
            while ((try? FileManager.default.contentsOfDirectory(atPath: locks.path)) ?? []).isEmpty, Date.now < lockDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(!((try? FileManager.default.contentsOfDirectory(atPath: locks.path)) ?? []).isEmpty,
                         "the holder never took its lock")
        } catch {
            holder.stop()
            throw error
        }
        return holder
    }

    /// Polls rather than `waitUntilExit()`: from this suite's async tests
    /// that call can hang for minutes after the process is gone, while
    /// `isRunning` turns false promptly.
    private static func waitForExit(_ process: Process, within seconds: TimeInterval = 30) async {
        let deadline = Date.now.addingTimeInterval(seconds)
        while process.isRunning, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test("restic reads an SFTP repository string with a port where the editor meant it")
    func sftpPortStringLandsWhereMeant() async throws {
        // macOS's own sftp-server stands in for ssh and the NAS: restic
        // speaks SFTP to it over a pipe, so the parsed path is what lands on
        // disk, and the port in the string is parsed but never dialed.
        let server = "/usr/libexec/sftp-server"
        try #require(FileManager.default.isExecutableFile(atPath: server))
        let binary = try PinnedRestic.binary()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func initialize(_ repository: Repository) async throws -> Int32 {
            let process = Process()
            process.executableURL = binary.url
            process.arguments = ["-r", repository.resticRepositoryString, "-o", "sftp.command=\(server)", "init"]
            process.environment = ["RESTIC_PASSWORD": Self.password, "HOME": NSHomeDirectory()]
            // The server's working directory is where a relative path lands.
            process.currentDirectoryURL = root
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            await Self.waitForExit(process)
            try #require(!process.isRunning, "restic init was still running after 30 s")
            return process.terminationStatus
        }

        var repository = Repository()
        repository.kind = .sftp
        repository.sftpHost = "backup@nas.example:2222"
        // A space and a `#`: unencoded, restic 0.19.1 reads the `#` as the
        // URL's fragment and the path ends before it (probed).
        repository.sftpPath = root.path + "/Mac #1"
        #expect(try await initialize(repository) == 0)
        #expect(FileManager.default.fileExists(atPath: root.path + "/Mac #1/config"))

        repository.sftpPath = "relative-repo"
        #expect(try await initialize(repository) == 0)
        #expect(FileManager.default.fileExists(atPath: root.path + "/relative-repo/config"))
    }

    @Test("the editor's connection check gives up at its timeout on a server that refuses connections")
    func repositoryExistsTimesOut() async throws {
        let service = try PinnedRestic.service()
        var repository = Repository()
        repository.kind = .s3
        // Port 1 refuses; without the timeout restic 0.19.1 kept retrying it
        // for over ten minutes (probed).
        repository.s3Endpoint = "http://127.0.0.1:1"
        repository.s3Bucket = "bucket"
        repository.s3AccessKeyID = "key"
        let started = Date.now
        do {
            _ = try await service.repositoryExists(
                RepositoryContext(repository: repository, password: Self.password, providerSecret: "secret"), timeout: 3
            )
            Issue.record("expected the check to time out")
        } catch ResticError.timedOut {
            #expect(Date.now.timeIntervalSince(started) < 30)
        }
    }

    @Test("a wrong password surfaces restic's exit code 12")
    func wrongPassword() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        var badContext = fixture.context
        badContext.password = "not-the-password"

        await #expect(throws: ResticError.self) {
            _ = try await fixture.service.snapshots(badContext)
        }
        do {
            _ = try await fixture.service.snapshots(badContext)
        } catch let ResticError.commandFailed(code, message) {
            #expect(code == 12)
            #expect(message.localizedCaseInsensitiveContains("password"))
        }
    }

    @Test("a missing repository surfaces exit code 10, not a generic failure")
    func missingRepository() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            _ = try await fixture.service.snapshots(fixture.context)
            Issue.record("expected the command to fail")
        } catch let ResticError.commandFailed(code, _) {
            #expect(code == 10)
        }
    }

    @Test("a hostile RESTIC_PASSWORD in the environment cannot override the stored one")
    func hostileEnvironmentPassword() async throws {
        // The runner inherits the parent environment, so the context's own
        // value is the only thing standing between restic and a stale shell
        // variable.
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        setenv("RESTIC_PASSWORD", "hostile-from-environment", 1)
        setenv("RESTIC_PASSWORD_COMMAND", "echo hostile-from-command", 1)
        defer {
            unsetenv("RESTIC_PASSWORD")
            unsetenv("RESTIC_PASSWORD_COMMAND")
        }

        let snapshots = try await fixture.service.snapshots(fixture.context)
        #expect(snapshots.isEmpty, "the repository exists but is empty; a password failure would have thrown instead")
    }

    @Test("a password change locks the old password out, opens with the new one, and leaves no password file behind")
    func changePasswordRotatesTheKey() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        try await fixture.service.changePassword(fixture.context, newPassword: "rotated")

        do {
            _ = try await fixture.service.snapshots(fixture.context)
            Issue.record("the old password still opened the repository")
        } catch let ResticError.commandFailed(code, message) {
            #expect(code == 12)
            #expect(message.localizedCaseInsensitiveContains("password"))
        }

        var rotated = fixture.context
        rotated.password = "rotated"
        let snapshots = try await fixture.service.snapshots(rotated)
        #expect(snapshots.isEmpty, "the repository exists but is empty; a password failure would have thrown instead")

        // The folder that carried the new password to restic went with the
        // command.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("SwiftRestic-Key-") }
        #expect(leftovers.isEmpty, "left behind: \(leftovers)")
    }

    @Test("unlock runs against the real repository, tolerating an unreadable lock file")
    func unlockRunsOnARealRepository() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        // What a crashed writer leaves: a file in locks/ no key opens. restic
        // 0.19.1 tolerates it and leaves it alone (probed), so what is pinned
        // here is the service's command itself running against this restic —
        // not a removal.
        let locks = fixture.root.appendingPathComponent("repo/locks")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: locks.appendingPathComponent(String(repeating: "0", count: 64)))

        try await fixture.service.unlock(fixture.context)
    }

    @Test("unlock removes the lock a killed backup left, and keeps a running backup's")
    func unlockRemovesOnlyAStaleLock() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)
        let locks = fixture.root.appendingPathComponent("repo/locks")

        let holder = try await Self.holdLock(on: fixture)
        defer { holder.stop() }
        try await fixture.service.unlock(fixture.context)
        #expect(try FileManager.default.contentsOfDirectory(atPath: locks.path).count == 1,
                "unlock removed a lock its backup still holds")

        // What a crash leaves: the lock, with no process of this Mac behind
        // it. SIGKILL, which no restic version can clean up after.
        kill(holder.process.processIdentifier, SIGKILL)
        await Self.waitForExit(holder.process)
        try #require(!holder.process.isRunning, "the killed backup was still running after 30 s")
        #expect(try FileManager.default.contentsOfDirectory(atPath: locks.path).count == 1)
        try await fixture.service.unlock(fixture.context)
        #expect(try FileManager.default.contentsOfDirectory(atPath: locks.path).isEmpty)
    }

    @Test("an unreadable file yields exit 3 with the file named, and the snapshot still lands")
    func partialBackup() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        // 0000 keeps the owner out too.
        let unreadable = fixture.sourceDirectory.appendingPathComponent("locked.dat")
        try "secret".write(to: unreadable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }

        let outcome = try await fixture.service.backup(fixture.context, plan: fixture.plan)

        #expect(outcome.exitCode == ResticError.backupPartialSuccessCode)
        #expect(outcome.completedWithErrors)
        // restic skipped the file but still wrote everything else.
        let snapshotID = try #require(outcome.summary?.snapshotID, "a partial backup must still produce a snapshot")
        #expect(outcome.itemErrors.contains { $0.contains("locked.dat") })

        let snapshots = try await fixture.service.snapshots(fixture.context, planID: fixture.plan.id)
        #expect(snapshots.map(\.id) == [snapshotID])
    }

    @Test("an unreadable folder is one unreadable item, though restic reports it twice")
    func unreadableDirectoryIsOneItem() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        // restic names a folder it cannot list once while scanning and again
        // while archiving, with the identical item string — one item, two
        // events. The folder needs a child, or there is nothing to withhold.
        let locked = fixture.sourceDirectory.appendingPathComponent("lockeddir")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try "inside".write(to: locked.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let outcome = try await fixture.service.backup(fixture.context, plan: fixture.plan)

        #expect(outcome.exitCode == ResticError.backupPartialSuccessCode)
        #expect(outcome.itemErrors.count == 1, "the outcome's lines were: \(outcome.itemErrors)")
        #expect(outcome.itemErrors.first?.hasPrefix(locked.path + ":") == true)
    }

    @Test("a plan whose folder is missing writes no snapshot: restic fails with every source missing")
    func missingPathWritesNothing() async throws {
        var fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        // An unmounted volume or a renamed folder. A plan is one path, so
        // nothing is left to back up: restic exits 1 and writes nothing.
        fixture.plan.path = fixture.root.appendingPathComponent("does-not-exist").path

        await #expect {
            try await fixture.service.backup(fixture.context, plan: fixture.plan)
        } throws: { error in
            guard case let ResticError.commandFailed(exitCode, message) = error else { return false }
            return exitCode == 1 && message.hasPrefix(RunRecord.everySourceMissingMessage)
        }
        #expect(try await fixture.service.snapshots(fixture.context).isEmpty)
    }

    @Test("a missing folder's run keeps restic's words in the transcript, its skip line and its exit")
    func missingPathIsTranscribed() async throws {
        var fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        fixture.plan.path = fixture.root.appendingPathComponent("gone").path
        let transcript = RunTranscript()
        let service = fixture.service
        let context = fixture.context
        let plan = fixture.plan
        await #expect(throws: ResticError.self) {
            try await RunTranscript.$current.withValue(transcript) {
                try await service.backup(context, plan: plan)
            }
        }

        let entries = transcript.contents.entries
        #expect(entries.first?.kind == .command)
        #expect(entries.first?.text.hasPrefix("restic backup --json") == true, "first entry was \(entries.first?.text ?? "none")")
        #expect(entries.contains { entry in
            if case .output = entry.kind { entry.text.contains("gone does not exist, skipping") } else { false }
        }, "entries were \(entries.map(\.text))")
        #expect(entries.contains { $0.kind == .exit(1) })
    }

    @Test("a repeat restore reports skipped files, not restored ones")
    func repeatRestoreReportsSkippedFiles() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)
        let outcome = try await fixture.service.backup(fixture.context, plan: fixture.plan)
        let snapshotID = try #require(outcome.summary?.snapshotID)
        let children = try await fixture.service.listDirectory(
            fixture.context,
            snapshotID: snapshotID,
            path: fixture.sourceDirectory.path
        )
        let sub = try #require(children.first { $0.name == "sub" })
        let destination = fixture.root.appendingPathComponent("restore-twice")

        let first = try await fixture.service.restore(
            fixture.context,
            snapshotID: snapshotID,
            node: sub,
            destinationDirectory: destination,
            overwrite: .replaceExisting
        )
        #expect(first?.filesRestored == 1)
        // Replace (restic's `always`, also its default) skips an identical
        // file, and the summary then carries no files_restored key at all.
        let second = try await fixture.service.restore(
            fixture.context,
            snapshotID: snapshotID,
            node: sub,
            destinationDirectory: destination,
            overwrite: .replaceExisting
        )
        #expect(second?.filesRestored == nil)
        #expect(second?.filesSkipped == 1)
    }

    private func backedUpChildren(_ fixture: ResticFixture) async throws -> (snapshotID: String, children: [SnapshotNode]) {
        _ = try await fixture.service.initializeRepository(fixture.context)
        let outcome = try await fixture.service.backup(fixture.context, plan: fixture.plan)
        let snapshotID = try #require(outcome.summary?.snapshotID)
        let children = try await fixture.service.listDirectory(
            fixture.context,
            snapshotID: snapshotID,
            path: fixture.sourceDirectory.path
        )
        return (snapshotID, children)
    }

    @Test("keep-existing restore leaves files already at the destination as they were")
    func keepExistingFolderRestore() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (snapshotID, children) = try await backedUpChildren(fixture)
        let sub = try #require(children.first { $0.name == "sub" })
        let destination = fixture.root.appendingPathComponent("restore-keep")
        let restored = destination.appendingPathComponent("sub/b.txt")

        _ = try await fixture.service.restore(
            fixture.context, snapshotID: snapshotID, node: sub,
            destinationDirectory: destination, overwrite: .replaceExisting
        )
        try "local edit".write(to: restored, atomically: false, encoding: .utf8)

        let kept = try await fixture.service.restore(
            fixture.context, snapshotID: snapshotID, node: sub,
            destinationDirectory: destination, overwrite: .keepExisting
        )
        #expect(try String(contentsOf: restored, encoding: .utf8) == "local edit", "Keep replaced the user's file")
        #expect(kept?.filesSkipped == 1)

        _ = try await fixture.service.restore(
            fixture.context, snapshotID: snapshotID, node: sub,
            destinationDirectory: destination, overwrite: .replaceExisting
        )
        #expect(try String(contentsOf: restored, encoding: .utf8) == "nested", "Replace left the edited file")
    }

    @Test("keep-existing single-file restore keeps an existing file and reports it skipped, without running restic")
    func keepExistingFileRestore() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (snapshotID, children) = try await backedUpChildren(fixture)
        let file = try #require(children.first { $0.name == "a.txt" })
        let destination = fixture.root.appendingPathComponent("restore-keep-file")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = destination.appendingPathComponent("a.txt")
        try "mine".write(to: existing, atomically: false, encoding: .utf8)

        let transcript = RunTranscript()
        let summary = try await RunTranscript.$current.withValue(transcript) {
            try await fixture.service.restore(
                fixture.context, snapshotID: snapshotID, node: file,
                destinationDirectory: destination, overwrite: .keepExisting
            )
        }

        #expect(try String(contentsOf: existing, encoding: .utf8) == "mine", "Keep replaced the user's file")
        // The file in the way is seen before the download, which it spares.
        let commands = transcript.contents.entries.filter { $0.kind == .command }.map(\.text)
        #expect(commands.isEmpty, "restic ran for a file Keep leaves alone: \(commands)")
        #expect(summary?.filesSkipped == 1)
        #expect(summary?.filesRestored == 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(!names.contains { $0.hasSuffix(".partial") }, "left behind: \(names)")
    }

    @Test("a file restored alone keeps its modification time, permissions and extended attributes")
    func fileRestoredAloneKeepsItsMetadata() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // What restic recorded beside the bytes: owner-only permissions, an
        // extended attribute, and a modification time to the nanosecond.
        let source = fixture.sourceDirectory.appendingPathComponent("key.txt")
        try "secret".write(to: source, atomically: false, encoding: .utf8)
        #expect(chmod(source.path, 0o600) == 0)
        let attribute = Array("kept".utf8)
        #expect(setxattr(source.path, "com.example.swiftrestic", attribute, attribute.count, 0, XATTR_NOFOLLOW) == 0)
        let stamp = [timespec](repeating: timespec(tv_sec: 1_767_357_296, tv_nsec: 123_456_789), count: 2)
        #expect(utimensat(AT_FDCWD, source.path, stamp, AT_SYMLINK_NOFOLLOW) == 0)
        let (snapshotID, children) = try await backedUpChildren(fixture)
        let node = try #require(children.first { $0.name == "key.txt" })

        // Into an empty folder, and over another file of that name.
        let fresh = fixture.root.appendingPathComponent("restore-metadata")
        let occupied = fixture.root.appendingPathComponent("restore-metadata-over")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try "mine".write(to: occupied.appendingPathComponent("key.txt"), atomically: false, encoding: .utf8)
        for (destination, policy) in [(fresh, RestoreOverwritePolicy.keepExisting), (occupied, .replaceExisting)] {
            _ = try await fixture.service.restore(
                fixture.context, snapshotID: snapshotID, node: node,
                destinationDirectory: destination, overwrite: policy
            )
            let restored = destination.appendingPathComponent("key.txt")
            let place = destination.lastPathComponent
            #expect(try String(contentsOf: restored, encoding: .utf8) == "secret")
            var status = stat()
            #expect(lstat(restored.path, &status) == 0)
            #expect(status.st_mode & 0o7777 == 0o600, "permissions \(String(status.st_mode & 0o7777, radix: 8)) in \(place)")
            #expect(
                status.st_mtimespec.tv_sec == 1_767_357_296 && status.st_mtimespec.tv_nsec == 123_456_789,
                "modified at \(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec) in \(place)"
            )
            var value = [UInt8](repeating: 0, count: 16)
            let length = getxattr(restored.path, "com.example.swiftrestic", &value, value.count, 0, XATTR_NOFOLLOW)
            #expect(length == 4 && value.prefix(4).elementsEqual(attribute), "extended attribute: \(length) bytes in \(place)")
            let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            #expect(names == ["key.txt"], "left in \(place): \(names)")
        }
    }

    @Test("several items of one folder restore in one call, each where it would land alone, matched by its exact name")
    func restoreItemsLandsEachByName() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Names restic's patterns read as patterns, and one only a pattern
        // would match: "star*.txt" unescaped brings "starfish.txt" along.
        for name in ["a[1].txt", "star*.txt", "starfish.txt"] {
            try name.write(to: fixture.sourceDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let (snapshotID, children) = try await backedUpChildren(fixture)
        let picked = ["a.txt", "sub", "a[1].txt", "star*.txt", "\u{0301}leading.txt"]
        let nodes = try picked.map { name in try #require(children.first { $0.name == name }, "no \(name)") }
        let destination = fixture.root.appendingPathComponent("restore-items")

        let summary = try await fixture.service.restoreItems(
            fixture.context, snapshotID: snapshotID, parent: fixture.sourceDirectory.path, nodes: nodes,
            destinationDirectory: destination, overwrite: .keepExisting
        )

        let landed = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(Set(landed.map { Array($0.unicodeScalars) }) == Set(picked.map { Array($0.unicodeScalars) }), "landed: \(landed)")
        #expect(try String(contentsOf: destination.appendingPathComponent("sub/b.txt"), encoding: .utf8) == "nested")
        #expect(try String(contentsOf: destination.appendingPathComponent("star*.txt"), encoding: .utf8) == "star*.txt")
        #expect((summary?.filesRestored ?? 0) > 0)
    }

    @Test("a restore of several items refuses a landing restic would damage, before restic runs")
    func restoreItemsGuardsLandings() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (snapshotID, children) = try await backedUpChildren(fixture)
        let sub = try #require(children.first { $0.name == "sub" })
        let file = try #require(children.first { $0.name == "a.txt" })
        let restore = { (nodes: [SnapshotNode], destination: URL, policy: RestoreOverwritePolicy) in
            try await fixture.service.restoreItems(
                fixture.context, snapshotID: snapshotID, parent: fixture.sourceDirectory.path, nodes: nodes,
                destinationDirectory: destination, overwrite: policy
            )
        }

        // A file where the folder goes: restic deletes it, under Keep too.
        let fileThere = fixture.root.appendingPathComponent("file-there")
        try FileManager.default.createDirectory(at: fileThere, withIntermediateDirectories: true)
        try "mine".write(to: fileThere.appendingPathComponent("sub"), atomically: true, encoding: .utf8)
        await #expect(throws: ResticError.fileInTheWay(path: fileThere.appendingPathComponent("sub").path)) {
            try await restore([sub, file], fileThere, .keepExisting)
        }
        #expect(try String(contentsOf: fileThere.appendingPathComponent("sub"), encoding: .utf8) == "mine")

        // A symlink to a folder where the folder goes: restic replaces the
        // link with a new folder, under Keep too, alone or with others.
        let linkThere = fixture.root.appendingPathComponent("link-there")
        let elsewhere = fixture.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: linkThere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = linkThere.appendingPathComponent("sub")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        await #expect(throws: ResticError.fileInTheWay(path: link.path)) {
            try await restore([sub, file], linkThere, .keepExisting)
        }
        await #expect(throws: ResticError.fileInTheWay(path: link.path)) {
            try await fixture.service.restore(
                fixture.context, snapshotID: snapshotID, node: sub,
                destinationDirectory: linkThere, overwrite: .keepExisting
            )
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == elsewhere.path)

        // A folder where the file goes, under Replace: restic fails on it
        // after taking its permissions away.
        let folderThere = fixture.root.appendingPathComponent("folder-there")
        let inside = folderThere.appendingPathComponent("a.txt/inside.txt")
        try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "mine".write(to: inside, atomically: true, encoding: .utf8)
        await #expect(throws: ResticError.folderInTheWay(path: folderThere.appendingPathComponent("a.txt").path)) {
            try await restore([sub, file], folderThere, .replaceExisting)
        }
        #expect(try String(contentsOf: inside, encoding: .utf8) == "mine")
        // Nothing but the standing folder is here: the refusal comes before
        // any landing is created, so "sub" was never made.
        let left = try FileManager.default.contentsOfDirectory(atPath: folderThere.path)
        #expect(left.map { Array($0.unicodeScalars) } == [Array("a.txt".unicodeScalars)], "left behind: \(left)")

        // Under Keep the folder stays and the file counts as kept, as a
        // single file's restore keeps it.
        let kept = try await restore([sub, file], folderThere, .keepExisting)
        #expect(kept?.filesSkipped == 1)
        #expect(try String(contentsOf: inside, encoding: .utf8) == "mine")
        #expect(try String(contentsOf: folderThere.appendingPathComponent("sub/b.txt"), encoding: .utf8) == "nested")
    }

    @Test("whole-snapshot keep-existing restore passes the policy to restic")
    func keepExistingWholeRestore() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (snapshotID, _) = try await backedUpChildren(fixture)
        let destination = fixture.root.appendingPathComponent("restore-keep-all")
        let existing = destination
            .appendingPathComponent(fixture.sourceDirectory.path)
            .appendingPathComponent("a.txt")
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "mine".write(to: existing, atomically: false, encoding: .utf8)

        let summary = try await fixture.service.restoreWholeSnapshot(
            fixture.context, snapshotID: snapshotID,
            destinationDirectory: destination, overwrite: .keepExisting
        )

        #expect(try String(contentsOf: existing, encoding: .utf8) == "mine", "Keep replaced the user's file")
        #expect((summary?.filesSkipped ?? 0) >= 1)
    }

    @Test("replace restores a file whose size and modification time match the backup")
    func replaceChecksContentNotSizeAndTime() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Same length, same modification time, different bytes: what
        // `if-changed` trusts and `always` does not.
        let stamp = Date(timeIntervalSince1970: 1_767_225_600)
        let twin = fixture.sourceDirectory.appendingPathComponent("sub/twin.txt")
        try "same-size-A".write(to: twin, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: twin.path)
        let (snapshotID, children) = try await backedUpChildren(fixture)
        let sub = try #require(children.first { $0.name == "sub" })

        let destination = fixture.root.appendingPathComponent("restore-twin")
        let restored = destination.appendingPathComponent("sub/twin.txt")
        try FileManager.default.createDirectory(at: restored.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "same-size-B".write(to: restored, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: restored.path)

        _ = try await fixture.service.restore(
            fixture.context, snapshotID: snapshotID, node: sub,
            destinationDirectory: destination, overwrite: .replaceExisting
        )
        #expect(try String(contentsOf: restored, encoding: .utf8) == "same-size-A", "Replace trusted size and time over content")
    }

    @Test("the default excludes keep a Git repository restorable, object store included")
    func defaultExcludesKeepGitHistory() async throws {
        var fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        // The shape `git init` + one commit leaves: loose objects under
        // .git/objects are the history itself — without them a restored
        // working copy answers every git command with "not a git repository".
        let git = fixture.sourceDirectory.appendingPathComponent("project/.git")
        let object = git.appendingPathComponent("objects/ab/cdef0123456789")
        try FileManager.default.createDirectory(at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "loose object".write(to: object, atomically: true, encoding: .utf8)
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        // A default that must still apply, so this test cannot pass merely
        // because no exclude reached restic.
        let finderFile = fixture.sourceDirectory.appendingPathComponent("project/.DS_Store")
        try "finder".write(to: finderFile, atomically: true, encoding: .utf8)
        // The source spelled with its symlinks resolved: the scratch tree lies
        // under /private/var/folders, itself one of the startup disk's
        // defaults, and the run must not pass a rule that names the source
        // or a folder above it, or this backup would hold nothing.
        let resolved = fixture.sourceDirectory.path.replacingOccurrences(of: "/var/", with: "/private/var/", options: .anchored)
        fixture.plan.path = resolved
        #expect(ResticService.pattern("/private/var/folders", covers: resolved))

        let outcome = try await fixture.service.backup(fixture.context, plan: fixture.plan)
        let snapshotID = try #require(outcome.summary?.snapshotID)

        let destination = fixture.root.appendingPathComponent("restore-all")
        _ = try await fixture.service.restoreWholeSnapshot(
            fixture.context,
            snapshotID: snapshotID,
            destinationDirectory: destination,
            overwrite: .replaceExisting
        )
        let restored = { (url: URL) in
            destination.appendingPathComponent(resolved + url.path.dropFirst(fixture.sourceDirectory.path.count))
        }
        #expect(FileManager.default.fileExists(atPath: restored(object).path))
        #expect(FileManager.default.fileExists(atPath: restored(git.appendingPathComponent("HEAD")).path))
        #expect(!FileManager.default.fileExists(atPath: restored(finderFile).path))
    }

    @Test("the folder-fitted defaults' glob shapes skip what the system rebuilds, re-rooted over a scratch tree")
    func reRootedDefaultsSkipRegeneratedState() async throws {
        var fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        // The defaults' shapes with the "~" or "/" anchor replaced by
        // the scratch root: the real anchors name the user's home folder
        // and disk, and the fitting itself is the unit pins' fact. What
        // needs real restic is whether the globs match as drawn — `V*` and
        // `Envelope Index*` inside one component, spaces staying one
        // component, and `*` never crossing a separator.
        let root = fixture.sourceDirectory.path
        fixture.plan.excludePatterns = [
            root + "/Library/Mail/V*/MailData/Envelope Index*",
            root + "/Pictures/*.photoslibrary/database/search",
            root + "/Pictures/*.photoslibrary/resources/caches",
            root + "/Library/Group Containers/*/Library/Caches",
            root + "/Volumes/*/.Spotlight-V100",
            root + "/Volumes/*/.fseventsd",
        ]

        @discardableResult
        func planted(_ relative: String, _ contents: String) throws -> URL {
            let url = fixture.sourceDirectory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        try planted("Library/Mail/V10/MailData/Envelope Index", "index")
        try planted("Library/Mail/V10/MailData/Envelope Index-shm", "shm")
        try planted("Library/Mail/V10/MailData/Envelope Index-wal", "wal")
        let message = try planted("Library/Mail/V10/5C98A1B2-C3D4-4E5F-8A9B-0123456789AB/Data/Messages/172.emlx", "message")
        try planted("Pictures/My Photos.photoslibrary/database/search/leo.sqlite", "search index")
        try planted("Pictures/My Photos.photoslibrary/resources/caches/compute/thumbnails", "cache")
        let database = try planted("Pictures/My Photos.photoslibrary/database/Photos.sqlite", "library database")
        let original = try planted("Pictures/My Photos.photoslibrary/originals/2026/IMG_0001.heic", "photo")
        try planted("Library/Group Containers/group.abc123/Library/Caches/cache.bin", "cache")
        let preferences = try planted("Library/Group Containers/group.abc123/Library/Preferences/prefs.plist", "prefs")
        try planted("Volumes/T7/.fseventsd/fsevents", "events")
        try planted("Volumes/T7/.Spotlight-V100/Store-V2/index", "index")
        let document = try planted("Volumes/T7/user/doc.txt", "doc")

        let outcome = try await fixture.service.backup(fixture.context, plan: fixture.plan)
        let snapshotID = try #require(outcome.summary?.snapshotID)

        // `restic ls` of the whole snapshot is the truth the excludes are
        // checked against — every path the snapshot holds, nothing else.
        let listed = NodeCollector()
        try await fixture.service.walkSnapshot(fixture.context, snapshotID: snapshotID) { node in
            listed.append(node)
        }
        let paths = Set(listed.content.keys)

        #expect(!paths.contains { $0.hasSuffix("/Envelope Index") || $0.hasSuffix("/Envelope Index-shm") || $0.hasSuffix("/Envelope Index-wal") },
            "the Mail index trio must be skipped; snapshot held: \(paths.filter { $0.contains("MailData") })")
        #expect(paths.contains(message.path), "the message beside MailData must stay")
        #expect(!paths.contains { $0.contains("/database/search") },
            "the search index must be skipped; snapshot held: \(paths.filter { $0.contains(".photoslibrary") })")
        #expect(!paths.contains { $0.contains("/resources/caches") }, "the analysis caches must be skipped")
        #expect(paths.contains(database.path), "the library database must stay")
        #expect(paths.contains(original.path), "the originals must stay")
        #expect(!paths.contains { $0.contains("/group.abc123/Library/Caches") },
            "the app group's caches must be skipped; snapshot held: \(paths.filter { $0.contains("group.abc123") })")
        #expect(paths.contains(preferences.path), "the app group's preferences must stay")
        #expect(!paths.contains { $0.hasSuffix("/.fseventsd/fsevents") },
            "the volume's FS-events journal must be skipped; snapshot held: \(paths.filter { $0.contains("/Volumes/") })")
        #expect(!paths.contains { $0.hasSuffix("/.Spotlight-V100/Store-V2/index") }, "the volume's Spotlight index must be skipped")
        #expect(paths.contains(document.path), "the user folder on the volume must stay")
    }

    @Test("the developer rules and markers skip what the tools rebuild, over a stand-in home")
    func developerExcludesSkipRebuildables() async throws {
        var fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        // The stand-in home: a folder inside the source, so the anchored
        // rules re-root over it — the service's `home` is what the plan's
        // tilde paths and the anchored patterns expand against.
        let home = fixture.sourceDirectory.appendingPathComponent("home")
        fixture.service.home = home.path
        // Every group's rules and markers alone: no other rule may be what
        // skips a folder here.
        fixture.plan.skipsDeveloperFiles = true
        fixture.plan.skipsMachines = true

        // `inplace` is a project made a virtualenv in place
        // (`python -m venv .`): its pyvenv.cfg sits beside the user's code.
        @discardableResult
        func planted(_ relative: String, _ contents: String) throws -> URL {
            let url = fixture.sourceDirectory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let venvConfig = try planted("proj/.venv/pyvenv.cfg", "virtualenv configuration")
        let venvModule = try planted("proj/.venv/lib/x.py", "installed module")
        let namedVenvModule = try planted("tool/venv/lib/y.py", "installed module")
        try planted("inplace/pyvenv.cfg", "virtualenv configuration")
        let inPlaceCode = try planted("inplace/main.py", "the user's code beside an in-place virtualenv")
        let cargoMarker = try planted("rs/target/.rustc_info.json", "rustc info cache")
        let rustBinary = try planted("rs/target/debug/app", "built binary")
        let userTarget = try planted("notes/target/mine.txt", "a user's folder that is only named target")
        let pycache = try planted("proj/__pycache__/m.pyc", "bytecode")
        let nodeModule = try planted("web/node_modules/left-pad/index.js", "an installed package")
        let terraformState = try planted("proj/.terraform/x", "providers and modules cache")
        let terraformLock = try planted("proj/.terraform.lock.hcl", "the resolve's lock file")
        let gradleCache = try planted("home/.gradle/caches/x", "build cache")
        let gradleProperties = try planted("home/.gradle/gradle.properties", "the user's gradle properties")
        let cargoRegistry = try planted("home/.cargo/registry/x", "downloaded crate")
        let cargoBin = try planted("home/.cargo/bin/tool", "a cargo-installed executable")
        let m2Repository = try planted("home/.m2/repository/x", "downloaded artifact")
        let m2Settings = try planted("home/.m2/settings.xml", "the user's maven settings")
        let limaDisk = try planted("home/.lima/vm/diffdisk", "the machine's disk image")
        let limaConfig = try planted("home/.lima/vm/lima.yaml", "the machine's configuration")
        let avdImage = try planted("home/.android/avd/x.avd/userdata.img", "the emulator's disk image")
        let adbKey = try planted("home/.android/adbkey", "the adb identity")
        let deviceSupport = try planted("home/Library/Developer/Xcode/iOS DeviceSupport/x", "device symbols")
        let archive = try planted("home/Library/Developer/Xcode/Archives/a.xcarchive/Info.plist", "a shipped build's archive")
        let simulator = try planted("home/Library/Developer/CoreSimulator/Devices/d/data", "what was installed in a simulator")
        let deviceFile = try planted(
            "home/Library/Developer/CoreDevice/DeviceFS/device-x.localized/AppDataContainers/app/Library/a.ktx",
            "a connected iPhone's file"
        )
        let bundledGem = try planted("rb/vendor/bundle/ruby/3.3.0/gems/x/lib/x.rb", "a gem Bundler installed")
        let vendoredCode = try planted("rb/vendor/mylib/lib.rb", "the user's own vendored code")
        let installedGem = try planted("home/.gem/ruby/3.3.0/gems/y/y.rb", "a gem installed for the user")
        let gemCredentials = try planted("home/.gem/credentials", "the RubyGems API key")
        let assetsMarker = try planted("cs/obj/project.assets.json", "NuGet's restore output")
        let intermediate = try planted("cs/obj/Debug/net8.0/app.dll", "an intermediate build")
        let userObj = try planted("models/obj/mesh.obj", "a user's folder that is only named obj")
        let nugetPackage = try planted("home/.nuget/packages/z/1.0.0/z.nupkg", "a NuGet package")
        let cabalBuild = try planted("hs/dist-newstyle/build/x", "Cabal build output")
        let juliaPackage = try planted("home/.julia/packages/P/abc/src/P.jl", "a Julia package")
        let juliaDev = try planted("home/.julia/dev/Mine/src/Mine.jl", "a package under development")
        let clionBuild = try planted("cpp/cmake-build-debug/app", "CLion's build")
        let cppSource = try planted("cpp/src/main.cpp", "the user's C++ source")
        let renvLibrary = try planted("rproj/renv/library/R-4.4/x/DESCRIPTION", "an R package renv installed")
        let renvLock = try planted("rproj/renv.lock", "the R project's lockfile")
        let metals = try planted("sc/.metals/metals.mv.db", "Metals' index")
        let zigOut = try planted("zg/zig-out/bin/app", "Zig build output")
        let opamSwitch = try planted("ml/_opam/lib/x/META", "a project's opam switch")
        let uvCache = try planted("home/.cache/uv/wheels/x.whl", "uv's cache")
        let elixirLS = try planted("ex/.elixir_ls/build/x", "ElixirLS's build")

        let outcome = try await fixture.service.backup(fixture.context, plan: fixture.plan)
        let snapshotID = try #require(outcome.summary?.snapshotID)

        // `restic ls` of the whole snapshot is the truth the excludes are
        // checked against — every path the snapshot holds, nothing else.
        let listed = NodeCollector()
        try await fixture.service.walkSnapshot(fixture.context, snapshotID: snapshotID) { node in
            listed.append(node)
        }
        let paths = Set(listed.content.keys)

        for skipped in [venvConfig, venvModule, namedVenvModule, rustBinary, pycache, nodeModule, terraformState, gradleCache,
                        cargoRegistry, m2Repository, limaDisk, avdImage, deviceSupport, simulator, deviceFile,
                        bundledGem, installedGem, intermediate, nugetPackage, cabalBuild, juliaPackage, clionBuild,
                        renvLibrary, metals, zigOut, opamSwitch, uvCache, elixirLS] {
            #expect(!paths.contains(skipped.path), "the rules must skip \(skipped.path); snapshot held \(paths.count) paths")
        }
        for kept in [cargoMarker, userTarget, inPlaceCode, terraformLock, gradleProperties,
                     cargoBin, m2Settings, limaConfig, adbKey, archive,
                     vendoredCode, gemCredentials, assetsMarker, userObj, juliaDev, cppSource, renvLock] {
            #expect(paths.contains(kept.path), "the marker and the user's own files must stay: \(kept.path)")
        }
    }

    @Test("check reports a healthy repository")
    func check() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)
        _ = try await fixture.service.backup(fixture.context, plan: fixture.plan)

        let summary = try await fixture.service.check(fixture.context, readDataSubset: .percent(100))
        #expect(summary?.numErrors == 0)

        let stats = try await fixture.service.stats(fixture.context, timeout: nil)
        #expect(stats.totalSize > 0)
        #expect(stats.snapshotsCount == 1)
    }

}

@Suite("restic maintenance", .serialized)
struct ResticMaintenanceTests {
    @Test("prune reclaims space after forget, and reports in plain text")
    func prune() async throws {
        let fixture = try makeResticFixture(prefix: "Prune", password: "prune-test")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = fixture.service
        let context = fixture.context
        let plan = fixture.plan
        _ = try await service.initializeRepository(context)

        // Three snapshots of distinct data, so forgetting two leaves real garbage.
        for index in 0 ..< 3 {
            try Data((0 ..< 400_000).map { UInt8(($0 &* 7 &+ index &* 101) % 251) })
                .write(to: fixture.sourceDirectory.appendingPathComponent("blob.bin"))
            _ = try await service.backup(context, plan: plan)
        }

        let before = try await service.stats(context, timeout: nil)

        var trimmed = plan
        trimmed.retention = RetentionPolicy(
            isEnabled: true, keepLast: 1, keepHourly: 0, keepDaily: 0,
            keepWeekly: 0, keepMonthly: 0, keepYearly: 0
        )
        #expect(try await service.forget(context, plan: trimmed) == 2)

        // forget only unlinks snapshots; the packs stay until prune rewrites them.
        let output = try await service.prune(context)
        #expect(!output.isEmpty, "prune produced no output to record")
        let freed = try #require(ResticService.pruneFreedBytes(in: output), "no total prune line in: \(output)")
        #expect(freed > 0)

        let after = try await service.stats(context, timeout: nil)
        #expect(after.totalSize < before.totalSize)

        let check = try await service.check(context, readDataSubset: .percent(100))
        #expect(check?.numErrors == 0)
    }
}

/// Pins restic's end of the damage contract: a check that finds damage exits
/// 1, and its `--json` summary naming the errors still arrives; the service
/// hands it up only because restic prints it before dying. A suite of its own
/// so the damage can never touch another fixture.
@Suite("restic check damage", .serialized)
struct ResticCheckDamageTests {
    @Test("a damaged repository's check still carries its error count")
    func checkOnDamagedRepositoryReportsErrors() async throws {
        let fixture = try makeResticFixture(prefix: "CheckDamage", password: "check-damage-password") { source in
            // Random bytes, not zeros: compression would shrink them into a pack
            // too small to aim a corruption at.
            try Data(randomBytes: 200_000).write(to: source.appendingPathComponent("big.bin"))
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let context = fixture.context
        let service = fixture.service
        _ = try await service.initializeRepository(context)
        _ = try await service.backup(context, plan: fixture.plan)

        // Flip one byte in the middle of the largest data pack. restic marks
        // its packs read-only, so the mode comes back before the write — a
        // failed corrupt must never read as healthy. Structural `check`
        // verifies only headers, so the verdict is read with data: a flipped
        // blob byte is exactly what `--read-data` exists to catch.
        let dataRoot = fixture.root.appendingPathComponent("repo/data")
        let enumerator = FileManager.default.enumerator(
            at: dataRoot,
            includingPropertiesForKeys: [URLResourceKey.isRegularFileKey, .fileSizeKey]
        )
        let pack = enumerator?.allObjects
            .compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .max { (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                < (try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }
        guard let pack else {
            Issue.record("no data pack found under repo/data to corrupt")
            return
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pack.path)
        var contents = try Data(contentsOf: pack)
        #expect(contents.count > 1_000, "the largest pack is suspiciously small — corruption would miss it")
        contents[contents.count / 2] ^= 0xFF
        try contents.write(to: pack)

        let summary = try await service.check(context, readDataSubset: .percent(100))
        #expect(
            (summary?.numErrors ?? 0) > 0,
            "check exited 1 on damage but named no errors: \(String(describing: summary))"
        )

        // The structure alone passes the same damage, while a rotation of
        // slices reads the damaged pack in exactly one of them.
        #expect((try await service.check(context, readDataSubset: nil)?.numErrors ?? 0) == 0)
        var slicesFindingIt = 0
        for slice in 1 ... 2 where (try await service.check(context, readDataSubset: .slice(slice, of: 2))?.numErrors ?? 0) > 0 {
            slicesFindingIt += 1
        }
        #expect(slicesFindingIt == 1)
    }
}

private extension Data {
    init(randomBytes count: Int) {
        self = Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max) })
    }
}

@Suite("restic diff", .serialized)
struct ResticDiffTests {
    @Test("a modified, an added and a removed file each show up with the right modifier")
    func diffBetweenTwoSnapshots() async throws {
        let fixture = try makeResticFixture(prefix: "Diff", password: "diff-test") { source in
            let sub = source.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try "one".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "two".write(to: sub.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.sourceDirectory
        let sub = source.appendingPathComponent("sub")
        let service = fixture.service
        let context = fixture.context
        let plan = fixture.plan
        _ = try await service.initializeRepository(context)

        let first = try await service.backup(context, plan: plan)
        let olderID = try #require(first.summary?.snapshotID)

        try "changed".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new".write(to: source.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: sub.appendingPathComponent("b.txt"))

        let second = try await service.backup(context, plan: plan)
        let newerID = try #require(second.summary?.snapshotID)

        func walk(_ older: String, _ newer: String) async throws -> [ResticDiffChange] {
            let lock = NSLock()
            nonisolated(unsafe) var collected: [ResticDiffChange] = []
            try await service.walkDiff(context, olderID: older, newerID: newer) { change in
                lock.withLock { collected.append(change) }
            }
            return lock.withLock { collected }
        }

        let changes = try await walk(olderID, newerID)
        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
        #expect(byPath[source.appendingPathComponent("a.txt").path]?.category == .modified)
        #expect(byPath[source.appendingPathComponent("c.txt").path]?.category == .added)
        #expect(byPath[sub.appendingPathComponent("b.txt").path]?.category == .removed)
        #expect(changes.count == 3)

        // Swapping the order flips the sign: the API's `+` is "only in newer".
        let reversed = try await walk(newerID, olderID)
        #expect(reversed.first { $0.path.hasSuffix("c.txt") }?.category == .removed)

        #expect(try await walk(newerID, newerID).isEmpty)
    }
}

@Suite("restic find", .serialized)
struct ResticFindTests {
    @Test("a file deleted from the source is still findable in an older snapshot")
    func findsFileAcrossSnapshots() async throws {
        let fixture = try makeResticFixture(prefix: "Find", password: "find-test") { source in
            try "the codes".write(
                to: source.appendingPathComponent("recovery-codes.txt"),
                atomically: true,
                encoding: .utf8
            )
            try "kept".write(
                to: source.appendingPathComponent("keep.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = fixture.service
        let context = fixture.context
        let plan = fixture.plan
        let secret = fixture.sourceDirectory.appendingPathComponent("recovery-codes.txt")
        _ = try await service.initializeRepository(context)
        _ = try await service.backup(context, plan: plan)

        try FileManager.default.removeItem(at: secret)
        _ = try await service.backup(context, plan: plan)

        let latestOnly = try await service.find(context, patterns: ["recovery-codes.txt"], snapshotIDs: ["latest"])
        #expect(latestOnly.isEmpty, "the file was deleted, so the newest snapshot must not have it")

        let all = try await service.find(context, patterns: ["recovery-codes.txt"])
        #expect(all.count == 1)
        let result = try #require(all.first)
        let match = try #require(result.matches.first)
        #expect(match.name == "recovery-codes.txt")
        #expect(match.size == 9)

        #expect(try await service.find(context, patterns: ["RECOVERY-*.TXT"]).count == 1)

        // The match restores through the same path a browsed node does.
        let destination = fixture.root.appendingPathComponent("restored")
        _ = try await service.restore(
            context,
            snapshotID: result.snapshot,
            node: match.node,
            destinationDirectory: destination,
            overwrite: .replaceExisting
        )
        let restored = destination.appendingPathComponent("recovery-codes.txt")
        #expect(try String(contentsOf: restored, encoding: .utf8) == "the codes")
    }

    @Test("an escaped path finds exactly that file in every backup, with its size in each")
    func escapedPathFindsOneFile() async throws {
        let fixture = try makeResticFixture(prefix: "FindExact", password: "exact-test") { source in
            // Each target beside the name its raw glob would also match.
            for (name, body) in [("a[1].txt", "one"), ("a1.txt", "x"), ("b*c.txt", "two"), ("bXc.txt", "y")] {
                try body.write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.sourceDirectory
        let service = fixture.service
        let context = fixture.context
        let plan = fixture.plan
        _ = try await service.initializeRepository(context)
        _ = try await service.backup(context, plan: plan)
        try "one, longer".write(to: source.appendingPathComponent("a[1].txt"), atomically: true, encoding: .utf8)
        _ = try await service.backup(context, plan: plan)

        for (name, sizes) in [("a[1].txt", Set<Int64>([3, 11])), ("b*c.txt", Set<Int64>([3]))] {
            let path = source.appendingPathComponent(name).path
            let results = try await service.find(
                context, patterns: [ResticService.globEscaped(path)], ignoreCase: false
            )
            #expect(results.count == 2, "\(name): one result per backup")
            #expect(results.allSatisfy { $0.matches.map(\.path) == [path] }, "\(name): \(results.map { $0.matches.map(\.path) })")
            #expect(Set(results.compactMap { $0.matches.first?.size }) == sizes)
        }

        // Named backups narrow it — the version rows name each version's
        // newest — and a name the repository no longer holds is skipped,
        // not fatal.
        let older = try #require(try await service.snapshots(context, planID: nil, timeout: 60).last)
        let path = source.appendingPathComponent("a[1].txt").path
        let narrowed = try await service.find(
            context,
            patterns: [ResticService.globEscaped(path)],
            ignoreCase: false,
            snapshotIDs: [older.id, String(repeating: "0", count: 64)]
        )
        #expect(narrowed.map(\.snapshot) == [older.id])
        #expect(narrowed.first?.matches.first?.size == 3)
    }
}
