import Foundation
import Testing

/// Drives the real restic binary against a throwaway local repository.
///
/// These are the tests that would catch a change in restic's actual behaviour
/// rather than only in the JSON lines the unit suites quote. They are skipped
/// when restic is not installed so the suite still runs on a bare machine.
enum ResticAvailability {
    static let isInstalled = (try? ResticBinary.locate(userOverride: nil)) != nil
}

@Suite("restic integration", .serialized, .enabled(if: ResticAvailability.isInstalled))
struct ResticIntegrationTests {
    private static let password = "integration-test-password"

    /// A repository, a source tree and the context needed to reach them.
    private struct Fixture {
        var root: URL
        var sourceDirectory: URL
        var context: RepositoryContext
        var service: ResticService
        var plan: BackupPlan
    }

    private func makeFixture() throws -> Fixture {
        let binary = try ResticBinary.locate(userOverride: nil)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // /var/folders is a symlink to /private/var/folders; restic records the
        // resolved path, so resolve here or every path comparison is off by one.
        let root = base.resolvingSymlinksInPath()

        let repositoryDirectory = root.appendingPathComponent("repo")
        let sourceDirectory = root.appendingPathComponent("source")
        let subDirectory = sourceDirectory.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDirectory, withIntermediateDirectories: true)
        try "hello world".write(
            to: sourceDirectory.appendingPathComponent("a.txt"),
            atomically: true,
            encoding: .utf8
        )
        try Data(repeating: 7, count: 200_000).write(
            to: sourceDirectory.appendingPathComponent("big.bin")
        )
        try "nested".write(
            to: subDirectory.appendingPathComponent("b.txt"),
            atomically: true,
            encoding: .utf8
        )
        // A name whose first character is a combining mark: the separator
        // before it merges into one grapheme, so any Character-level path
        // arithmetic silently drops the file from a directory listing. A
        // regression here would lose exactly this file at browse time.
        try "combining".write(
            to: sourceDirectory.appendingPathComponent("\u{0301}leading.txt"),
            atomically: true,
            encoding: .utf8
        )

        var repository = Repository()
        repository.name = "Integration"
        repository.kind = .local
        repository.localPath = repositoryDirectory.path

        var plan = BackupPlan()
        plan.name = "Integration plan"
        plan.repositoryID = repository.id
        plan.sources = [sourceDirectory.path]
        plan.excludePatterns = []

        return Fixture(
            root: root,
            sourceDirectory: sourceDirectory,
            context: RepositoryContext(repository: repository, password: Self.password),
            service: ResticService(runner: ResticRunner(), binary: binary.url),
            plan: plan
        )
    }

    @Test("init, backup, list, browse and restore against a real repository")
    func endToEnd() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // A repository that does not exist yet must report so rather than throw.
        #expect(try await fixture.service.repositoryExists(fixture.context, timeout: nil) == false)

        let repositoryID = try await fixture.service.initializeRepository(fixture.context)
        #expect(repositoryID != nil)
        #expect(try await fixture.service.repositoryExists(fixture.context, timeout: nil))

        // Backup
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

        // Restoring a directory does the same for a subtree.
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

    @Test("retention deletes only the plan's own extra snapshots")
    func retention() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        // Three snapshots from this plan…
        for index in 0 ..< 3 {
            try "change \(index)".write(
                to: fixture.sourceDirectory.appendingPathComponent("a.txt"),
                atomically: true,
                encoding: .utf8
            )
            _ = try await fixture.service.backup(fixture.context, plan: fixture.plan)
        }
        // …and one from a different plan, which retention must not touch.
        var otherPlan = fixture.plan
        otherPlan.id = UUID()
        otherPlan.name = "Other"
        _ = try await fixture.service.backup(fixture.context, plan: otherPlan)

        var plan = fixture.plan
        plan.retention = RetentionPolicy(
            isEnabled: true,
            keepLast: 1,
            keepHourly: 0,
            keepDaily: 0,
            keepWeekly: 0,
            keepMonthly: 0,
            keepYearly: 0,
            runPrune: false
        )
        let removed = try await fixture.service.forget(fixture.context, plan: plan)
        #expect(removed == 2)

        #expect(try await fixture.service.snapshots(fixture.context, planID: plan.id).count == 1)
        #expect(try await fixture.service.snapshots(fixture.context, planID: otherPlan.id).count == 1)
        #expect(try await fixture.service.snapshots(fixture.context).count == 2)
    }

    @Test("keep-last 1 per plan keeps exactly each plan's newest snapshot ID")
    func retentionKeepsExactIDs() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        // restic stamps snapshots with second granularity, so backups taken in
        // the same second can tie and keep-last's notion of "newest" becomes
        // unstable. Spacing the runs out makes the expected survivor exact.
        func runPlan(_ plan: BackupPlan) async throws -> String {
            try "change \(UUID().uuidString)".write(
                to: fixture.sourceDirectory.appendingPathComponent("a.txt"),
                atomically: true,
                encoding: .utf8
            )
            let outcome = try await fixture.service.backup(fixture.context, plan: plan)
            try await Task.sleep(for: .milliseconds(1100))
            return try #require(outcome.summary?.snapshotID)
        }

        var planB = fixture.plan
        planB.id = UUID()
        planB.name = "Other"
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

        // Spaced a second apart: restic stamps whole seconds, and keep-last's
        // "newest" must be exact for the IDs below to be.
        var planIDs: [String] = []
        for index in 0 ..< 3 {
            try "change \(index)".write(
                to: fixture.sourceDirectory.appendingPathComponent("a.txt"),
                atomically: true,
                encoding: .utf8
            )
            let outcome = try await fixture.service.backup(fixture.context, plan: fixture.plan)
            planIDs.append(try #require(outcome.summary?.snapshotID))
            try await Task.sleep(for: .milliseconds(1100))
        }
        var otherPlan = fixture.plan
        otherPlan.id = UUID()
        otherPlan.name = "Other"
        let otherOutcome = try await fixture.service.backup(fixture.context, plan: otherPlan)
        let other = try #require(otherOutcome.summary?.snapshotID)

        var plan = fixture.plan
        plan.retention = RetentionPolicy(
            isEnabled: true, keepLast: 1, keepHourly: 0, keepDaily: 0,
            keepWeekly: 0, keepMonthly: 0, keepYearly: 0,
            runPrune: true
        )

        // A backup of its own holds a lock while the preview runs — the
        // situation a user opening the sheet mid-backup is in. Its stdin
        // command waits for a file this test writes, so the lock is held
        // for as long as the preview and the control below take, however
        // slowly restic runs: a 30 s sleep in its place let the lock go
        // before the control forget on a loaded Mac (2026-10-09, the test
        // at 228 s against its usual 12), and the forget pruned two
        // snapshots.
        let binary = try ResticBinary.locate(userOverride: nil)
        let release = fixture.root.appendingPathComponent("release-hold")
        let holder = Process()
        holder.executableURL = binary.url
        holder.arguments = [
            "backup", "--stdin-from-command", "--stdin-filename", "hold", "--",
            "/bin/sh", "-c", "while [ ! -e \"$1\" ]; do sleep 0.2; done", "hold", release.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["RESTIC_REPOSITORY"] = fixture.root.appendingPathComponent("repo").path
        environment["RESTIC_PASSWORD"] = Self.password
        holder.environment = environment
        holder.standardOutput = FileHandle.nullDevice
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        // A failed expectation must not leave restic holding the lock, nor
        // the shell waiting for a release that never comes.
        defer {
            try? Data().write(to: release)
            holder.terminate()
        }
        let locks = fixture.root.appendingPathComponent("repo/locks")
        // Waits on restic's own start — key derivation and the repository
        // open — which load stretches; 20 s was a bet on it.
        let lockDeadline = Date.now.addingTimeInterval(120)
        while ((try? FileManager.default.contentsOfDirectory(atPath: locks.path)) ?? []).isEmpty, Date.now < lockDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!((try? FileManager.default.contentsOfDirectory(atPath: locks.path)) ?? []).isEmpty,
                "the holder never took its lock")

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

        // Let the holder finish: the shell exits, restic writes its untagged
        // snapshot and releases the lock on its own.
        try Data().write(to: release)
        await Self.waitForExit(holder, within: 120)
        #expect(!holder.isRunning, "the holder did not finish after its release")
        // Nothing was removed — neither by the dry run nor by the refused forget.
        #expect(try await fixture.service.snapshots(fixture.context, planID: plan.id).count == 3)
    }

    /// The model over the fixture repository, with the history read in: what
    /// the app runs when a repository page shows a group under Other backups.
    @MainActor
    private func adoptableModel(fixture: Fixture, repository: Repository) async throws -> AppModel {
        let model = AppModel(
            store: ConfigStore(directory: fixture.root.appendingPathComponent("config")),
            secrets: .inMemory([repository.id: (password: Self.password, providerSecret: nil)])
        )
        model.binary = try ResticBinary.locate(userOverride: nil)
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
        var plan = fixture.plan
        plan.name = "Projects"
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
        repository.name = "Integration"
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
        let draft = try #require(model.adoptDraft(repositoryID: repository.id, planID: plan.id))
        // No configuration holds the UUID, so the group's own label names it:
        // the newest backup's folder, not the plan name the repository never
        // knew.
        #expect(draft.name == "source")
        #expect(draft.sources == [fixture.sourceDirectory.path])
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
    @Test("the adopt sheet's dry run answers with the draft's own rules, over the unsaved plan")
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
        repository.name = "Integration"
        repository.kind = .local
        repository.localPath = fixture.root.appendingPathComponent("repo").path
        let model = try await adoptableModel(fixture: fixture, repository: repository)

        var draft = try #require(model.adoptDraft(repositoryID: repository.id, planID: plan.id))
        // Retention starts off; the sheet's preview turns a policy on in the
        // draft alone — the plan is not saved, so the draft itself travels to
        // restic.
        #expect(!draft.retention.isEnabled)
        draft.retention = RetentionPolicy(
            isEnabled: true, keepLast: 1, keepHourly: 0, keepDaily: 0,
            keepWeekly: 0, keepMonthly: 0, keepYearly: 0, runPrune: false
        )
        let preview = try await model.previewRetention(plan: draft)
        #expect(preview.kept.count == 1)
        #expect(preview.removed.count == 1)
        #expect(preview.adoptionLine == "With this policy, 2 backups would become 1.")
        // A dry run over an unsaved plan removed nothing.
        #expect(try await fixture.service.snapshots(fixture.context, planID: plan.id).count == 2)
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
        let binary = try ResticBinary.locate(userOverride: nil)
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
            await Self.waitForExit(process)
            return process.terminationStatus
        }

        var repository = Repository()
        repository.kind = .sftp
        repository.sftpUser = "backup"
        repository.sftpHost = "nas.example"
        repository.sftpPort = "2222"
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
        let binary = try ResticBinary.locate(userOverride: nil)
        let service = ResticService(runner: ResticRunner(), binary: binary.url)
        var repository = Repository()
        repository.kind = .rest
        // Port 1 refuses: restic 0.19.1 retried this for over ten minutes
        // (probed) before the timeout bounded it.
        repository.restURL = "http://127.0.0.1:1/"
        let started = Date.now
        do {
            _ = try await service.repositoryExists(RepositoryContext(repository: repository, password: Self.password), timeout: 3)
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
        // A RESTIC_PASSWORD inherited from the environment must never beat
        // the password the app stores for the repository, or a stale shell
        // variable quietly breaks every backup. The runner does inherit the
        // parent environment, so the context's own value is the only thing
        // standing between restic and whatever is in it.
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

    @Test("an unreadable file yields exit 3 with the file named, and the snapshot still lands")
    func partialBackup() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        // A file restic cannot read. 0000 keeps the owner out too, which is the
        // shape a corrupted download or a botched rsync actually leaves behind.
        let unreadable = fixture.sourceDirectory.appendingPathComponent("locked.dat")
        try "secret".write(to: unreadable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }

        let outcome = try await fixture.service.backup(fixture.context, plan: fixture.plan)

        #expect(outcome.exitCode == ResticError.backupPartialSuccessCode)
        #expect(outcome.completedWithErrors)
        // restic skipped the file but still wrote everything else, so the run
        // must be recorded as a snapshot-with-warnings, never as no snapshot.
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

    @Test("a missing source folder is named, though restic sends no error event for it")
    func missingSourceIsNamed() async throws {
        var fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        // An unmounted volume or a renamed folder: restic skips the source
        // with a plain-text warning, still writes a snapshot of the rest, and
        // exits 3 — the case that drops a whole top-level folder.
        let missing = fixture.root.appendingPathComponent("does-not-exist").path
        fixture.plan.sources = [fixture.sourceDirectory.path, missing]

        let outcome = try await fixture.service.backup(fixture.context, plan: fixture.plan)

        #expect(outcome.exitCode == ResticError.backupPartialSuccessCode)
        #expect(outcome.summary?.snapshotID != nil, "a skipped source must still leave a snapshot of the rest")
        #expect(outcome.itemErrors == ["\(missing) does not exist, skipping"])
    }

    @Test("a missing source folder exits 3 with no error event, and only the transcript keeps restic's words")
    func missingSourceIsTranscribed() async throws {
        var fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)

        let missing = fixture.root.appendingPathComponent("gone").path
        fixture.plan.sources = [fixture.sourceDirectory.path, missing]
        let transcript = RunTranscript()
        let service = fixture.service
        let context = fixture.context
        let plan = fixture.plan
        let outcome = try await RunTranscript.$current.withValue(transcript) {
            try await service.backup(context, plan: plan)
        }

        #expect(outcome.exitCode == 3)
        let entries = transcript.contents.entries
        #expect(entries.first?.kind == .command)
        #expect(entries.first?.text.hasPrefix("restic backup --json") == true, "first entry was \(entries.first?.text ?? "none")")
        #expect(entries.contains { entry in
            if case .output = entry.kind { entry.text.contains("gone does not exist, skipping") } else { false }
        }, "entries were \(entries.map(\.text))")
        #expect(entries.contains { $0.kind == .exit(3) })
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

    /// The fixture backed up, and its root folder's listing.
    private func backedUpChildren(_ fixture: Fixture) async throws -> (snapshotID: String, children: [SnapshotNode]) {
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

    @Test("keep-existing single-file restore keeps an existing file and reports it skipped")
    func keepExistingFileRestore() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (snapshotID, children) = try await backedUpChildren(fixture)
        let file = try #require(children.first { $0.name == "a.txt" })
        let destination = fixture.root.appendingPathComponent("restore-keep-file")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = destination.appendingPathComponent("a.txt")
        try "mine".write(to: existing, atomically: false, encoding: .utf8)

        let summary = try await fixture.service.restore(
            fixture.context, snapshotID: snapshotID, node: file,
            destinationDirectory: destination, overwrite: .keepExisting
        )

        #expect(try String(contentsOf: existing, encoding: .utf8) == "mine", "Keep replaced the user's file")
        #expect(summary?.filesSkipped == 1)
        #expect(summary?.filesRestored == 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(!names.contains { $0.hasSuffix(".partial") }, "left behind: \(names)")
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
        await #expect(throws: (any Error).self) { try await restore([sub, file], fileThere, .keepExisting) }
        #expect(try String(contentsOf: fileThere.appendingPathComponent("sub"), encoding: .utf8) == "mine")

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
        let modules = fixture.sourceDirectory.appendingPathComponent("project/node_modules/left-pad")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try "module".write(to: modules.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        fixture.plan.excludePatterns = BackupPlan.defaultExcludes

        let outcome = try await fixture.service.backup(fixture.context, plan: fixture.plan)
        let snapshotID = try #require(outcome.summary?.snapshotID)

        let destination = fixture.root.appendingPathComponent("restore-all")
        _ = try await fixture.service.restoreWholeSnapshot(
            fixture.context,
            snapshotID: snapshotID,
            destinationDirectory: destination,
            overwrite: .replaceExisting
        )
        let restored = { (url: URL) in destination.appendingPathComponent(url.path) }
        #expect(FileManager.default.fileExists(atPath: restored(object).path))
        #expect(FileManager.default.fileExists(atPath: restored(git.appendingPathComponent("HEAD")).path))
        #expect(!FileManager.default.fileExists(atPath: restored(modules).path))
    }

    @Test("check reports a healthy repository")
    func check() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.service.initializeRepository(fixture.context)
        _ = try await fixture.service.backup(fixture.context, plan: fixture.plan)

        let summary = try await fixture.service.check(fixture.context, readDataSubsetPercent: 100)
        #expect(summary?.numErrors == 0)

        let stats = try await fixture.service.stats(fixture.context)
        #expect(stats.totalSize > 0)
        #expect(stats.snapshotsCount == 1)
    }

}

@Suite("restic maintenance", .serialized, .enabled(if: ResticAvailability.isInstalled))
struct ResticMaintenanceTests {
    @Test("prune reclaims space after forget, and reports in plain text")
    func prune() async throws {
        let binary = try ResticBinary.locate(userOverride: nil)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticPrune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        var repository = Repository()
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path

        var plan = BackupPlan()
        plan.name = "Prune plan"
        plan.repositoryID = repository.id
        plan.sources = [source.path]
        plan.excludePatterns = []

        let service = ResticService(runner: ResticRunner(), binary: binary.url)
        let context = RepositoryContext(repository: repository, password: "prune-test")
        _ = try await service.initializeRepository(context)

        // Three snapshots of distinct data, so forgetting two leaves real garbage.
        for index in 0 ..< 3 {
            try Data((0 ..< 400_000).map { UInt8(($0 &* 7 &+ index &* 101) % 251) })
                .write(to: source.appendingPathComponent("blob.bin"))
            _ = try await service.backup(context, plan: plan)
        }

        let before = try await service.stats(context)

        var trimmed = plan
        trimmed.retention = RetentionPolicy(
            isEnabled: true, keepLast: 1, keepHourly: 0, keepDaily: 0,
            keepWeekly: 0, keepMonthly: 0, keepYearly: 0
        )
        #expect(try await service.forget(context, plan: trimmed) == 2)

        // forget only unlinks snapshots; the packs stay until prune rewrites them.
        let output = try await service.prune(context)
        #expect(!output.isEmpty, "prune produced no output to record")

        let after = try await service.stats(context)
        #expect(after.totalSize < before.totalSize)

        // The repository must still be sound afterwards.
        let check = try await service.check(context, readDataSubsetPercent: 100)
        #expect(check?.numErrors == 0)
    }
}

/// Pins restic's end of the damage contract: a check that finds damage exits
/// 1, and its `--json` summary naming the errors still arrives — the service
/// is allowed to hand it up only because restic actually prints it before
/// dying. Runs against a real repository, like the integration suite; kept
/// apart only so the damage it inflicts can never touch another fixture.
@Suite("restic check damage", .serialized, .enabled(if: ResticAvailability.isInstalled))
struct ResticCheckDamageTests {
    @Test("a damaged repository's check still carries its error count")
    func checkOnDamagedRepositoryReportsErrors() async throws {
        let binary = try ResticBinary.locate(userOverride: nil)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticCheckDamage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceDirectory = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        // Random bytes, not zeros: compression would shrink them into a pack
        // too small to aim a corruption at.
        try Data(randomBytes: 200_000).write(to: sourceDirectory.appendingPathComponent("big.bin"))

        var repository = Repository()
        repository.name = "Check damage"
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path

        var plan = BackupPlan()
        plan.name = "Check damage plan"
        plan.repositoryID = repository.id
        plan.sources = [sourceDirectory.path]
        plan.excludePatterns = []

        let context = RepositoryContext(repository: repository, password: "check-damage-password")
        let service = ResticService(runner: ResticRunner(), binary: binary.url)
        _ = try await service.initializeRepository(context)
        _ = try await service.backup(context, plan: plan)

        // Flip one byte in the middle of the largest data pack. restic marks
        // its packs read-only, so the mode comes back before the write — a
        // failed corrupt must never read as healthy. Structural `check`
        // verifies only headers, so the verdict is read with data: a flipped
        // blob byte is exactly what `--read-data` exists to catch.
        let dataRoot = root.appendingPathComponent("repo/data")
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

        let summary = try await service.check(context, readDataSubsetPercent: 100)
        #expect(
            (summary?.numErrors ?? 0) > 0,
            "check exited 1 on damage but named no errors: \(String(describing: summary))"
        )
    }
}

private extension Data {
    /// `UInt8.random` in a loop — fine at fixture sizes, and dependency-free.
    init(randomBytes count: Int) {
        self = Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max) })
    }
}

@Suite("restic diff", .serialized, .enabled(if: ResticAvailability.isInstalled))
struct ResticDiffTests {
    @Test("a modified, an added and a removed file each show up with the right modifier")
    func diffBetweenTwoSnapshots() async throws {
        let binary = try ResticBinary.locate(userOverride: nil)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticDiff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source")
        let sub = source.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "one".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two".write(to: sub.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        var repository = Repository()
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        var plan = BackupPlan()
        plan.name = "Diff plan"
        plan.repositoryID = repository.id
        plan.sources = [source.path]
        plan.excludePatterns = []

        let service = ResticService(runner: ResticRunner(), binary: binary.url)
        let context = RepositoryContext(repository: repository, password: "diff-test")
        _ = try await service.initializeRepository(context)

        let first = try await service.backup(context, plan: plan)
        let olderID = try #require(first.summary?.snapshotID)

        try "changed".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new".write(to: source.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: sub.appendingPathComponent("b.txt"))

        let second = try await service.backup(context, plan: plan)
        let newerID = try #require(second.summary?.snapshotID)

        let diff = try await service.diff(context, olderID: olderID, newerID: newerID)
        #expect(diff.olderID == olderID)
        #expect(diff.newerID == newerID)
        #expect(!diff.isTruncated)

        let byPath = Dictionary(uniqueKeysWithValues: diff.changes.map { ($0.path, $0) })
        #expect(byPath[source.appendingPathComponent("a.txt").path]?.category == .modified)
        #expect(byPath[source.appendingPathComponent("c.txt").path]?.category == .added)
        #expect(byPath[sub.appendingPathComponent("b.txt").path]?.category == .removed)
        #expect(diff.changes.count == 3)

        let stats = try #require(diff.statistics)
        #expect(stats.changedFiles == 1)
        #expect(stats.added.files == 1)
        #expect(stats.removed.files == 1)

        // Swapping the order flips the sign: the API's `+` is "only in newer".
        let reversed = try await service.diff(context, olderID: newerID, newerID: olderID)
        #expect(reversed.changes.first { $0.path.hasSuffix("c.txt") }?.category == .removed)

        // Comparing a snapshot with itself is a valid, empty result.
        let same = try await service.diff(context, olderID: newerID, newerID: newerID)
        #expect(same.changes.isEmpty)
        #expect(same.statistics?.changedFiles == 0)
    }
}

@Suite("restic find", .serialized, .enabled(if: ResticAvailability.isInstalled))
struct ResticFindTests {
    @Test("a file deleted from the source is still findable in an older snapshot")
    func findsFileAcrossSnapshots() async throws {
        let binary = try ResticBinary.locate(userOverride: nil)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticFind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let secret = source.appendingPathComponent("recovery-codes.txt")
        try "the codes".write(to: secret, atomically: true, encoding: .utf8)
        try "kept".write(
            to: source.appendingPathComponent("keep.txt"),
            atomically: true,
            encoding: .utf8
        )

        var repository = Repository()
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path

        var plan = BackupPlan()
        plan.name = "Find plan"
        plan.repositoryID = repository.id
        plan.sources = [source.path]
        plan.excludePatterns = []

        let service = ResticService(runner: ResticRunner(), binary: binary.url)
        let context = RepositoryContext(repository: repository, password: "find-test")
        _ = try await service.initializeRepository(context)
        _ = try await service.backup(context, plan: plan)

        // Delete it and take another snapshot: the newest backup no longer has it.
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

        // Case-insensitive by default, and globs work.
        #expect(try await service.find(context, patterns: ["RECOVERY-*.TXT"]).count == 1)

        // The match restores through the same path a browsed node does.
        let destination = root.appendingPathComponent("restored")
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

    /// The Files view's version rows read one file's node in every backup
    /// through its escaped path: exactly that file, whatever glob
    /// characters its name holds, with its size in each backup.
    @Test("an escaped path finds exactly that file in every backup, with its size in each")
    func escapedPathFindsOneFile() async throws {
        let binary = try ResticBinary.locate(userOverride: nil)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticFindExact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        // Each target beside the name its raw glob would also match.
        for (name, body) in [("a[1].txt", "one"), ("a1.txt", "x"), ("b*c.txt", "two"), ("bXc.txt", "y")] {
            try body.write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        var repository = Repository()
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        var plan = BackupPlan()
        plan.name = "Exact"
        plan.repositoryID = repository.id
        plan.sources = [source.path]
        plan.excludePatterns = []

        let service = ResticService(runner: ResticRunner(), binary: binary.url)
        let context = RepositoryContext(repository: repository, password: "exact-test")
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

/// Backups made outside the app with relative paths, as the console makes
/// them from inside a folder: restic names the absolute path in the snapshot
/// and keeps only the relative one in its tree.
@Suite("restic relative paths", .serialized, .enabled(if: ResticAvailability.isInstalled))
struct ResticRelativePathTests {
    @MainActor
    @Test("a backup made with a relative path lists its folder in Files where restic put it in the tree, not at the absolute path the snapshot names")
    func relativeBackupRoots() async throws {
        let binary = try ResticBinary.locate(userOverride: nil)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticRelative-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }

        let work = root.appendingPathComponent("work")
        let album = work.appendingPathComponent("src/Music/Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try "la".write(to: album.appendingPathComponent("song.txt"), atomically: true, encoding: .utf8)

        var repository = Repository()
        repository.name = "Relative"
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        let password = "relative-test"
        let service = ResticService(runner: ResticRunner(), binary: binary.url)
        _ = try await service.initializeRepository(RepositoryContext(repository: repository, password: password))

        // The console's way, from inside the folder: restic names the
        // absolute path in the snapshot but stores /src/Music in its tree.
        let console = Process()
        console.executableURL = binary.url
        console.arguments = ["backup", "src/Music", "--quiet"]
        console.currentDirectoryURL = work
        console.environment = ProcessInfo.processInfo.environment.merging(
            ["RESTIC_REPOSITORY": repository.localPath, "RESTIC_PASSWORD": password]
        ) { $1 }
        try console.run()
        console.waitUntilExit()
        #expect(console.terminationStatus == 0)

        var configuration = AppConfiguration()
        configuration.repositories = [repository]
        configuration.settings.resticPathOverride = binary.url.path
        let store = ConfigStore(directory: root.appendingPathComponent("config"))
        try await store.save(configuration)
        let model = AppModel(store: store, secrets: .inMemory([repository.id: (password: password, providerSecret: nil)]))
        await model.bootstrap()
        await model.refreshSnapshots(repositoryID: repository.id)
        let deadline = Date.now.addingTimeInterval(60)
        while !(await model.indexIsComplete(repositoryID: repository.id)), Date.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await model.indexIsComplete(repositoryID: repository.id), "the index never read the backup")

        let snapshot = try #require(model.snapshots(for: repository.id).first)
        // Absolute, from the working folder restic resolved (/private/var…).
        #expect(snapshot.paths.count == 1 && snapshot.paths[0].hasSuffix("/work/src/Music"), "\(snapshot.paths)")
        let roots = FileNode.roots(repositoryID: repository.id, chainKey: SnapshotIndex.chainKey(for: snapshot))
        let top = try await FilesTree.level(of: roots, model: model)
        #expect(top.entries.map(\.node.path) == ["/src/Music"])
        #expect(top.entries.first?.node.isDirectory == true)
        #expect(top.entries.first?.isInNewest == true)
        let music = try #require(top.entries.first?.node)
        let inside = try await FilesTree.level(of: music, model: model)
        #expect(inside.entries.map(\.node.name) == ["Album"])

        await model.shutdown()
    }
}
