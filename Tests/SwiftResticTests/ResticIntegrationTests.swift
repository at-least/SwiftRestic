import Foundation
import Testing

/// Drives the real restic binary against a throwaway local repository.
///
/// These are the tests that would catch a change in restic's actual behaviour
/// rather than only in the JSON we recorded. They are skipped when restic is not
/// installed so the suite still runs on a bare machine.
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
        #expect(try await fixture.service.repositoryExists(fixture.context) == false)

        let repositoryID = try await fixture.service.initializeRepository(fixture.context)
        #expect(repositoryID != nil)
        #expect(try await fixture.service.repositoryExists(fixture.context))

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
        // localizedStandardCompare actually produces, captured here so a
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
            destinationDirectory: fileDestination
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
            destinationDirectory: dirDestination
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
            destinationDirectory: wholeDestination
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
        } catch let ResticError.commandFailed(code, message, _) {
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
        } catch let ResticError.commandFailed(code, _, _) {
            #expect(code == 10)
        }
    }

    @Test("a hostile RESTIC_PASSWORD in the environment cannot override the stored one")
    func hostileEnvironmentPassword() async throws {
        // backrest issue #1139: a RESTIC_PASSWORD inherited from the environment
        // must never beat the password the app stores for the repository, or a
        // stale shell variable quietly breaks every backup. The runner does
        // inherit the parent environment, so the context's own value is the only
        // thing standing between restic and whatever is in it.
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

        let latestOnly = try await service.find(context, pattern: "recovery-codes.txt", snapshotID: "latest")
        #expect(latestOnly.isEmpty, "the file was deleted, so the newest snapshot must not have it")

        let all = try await service.find(context, pattern: "recovery-codes.txt")
        #expect(all.count == 1)
        let result = try #require(all.first)
        let match = try #require(result.matches.first)
        #expect(match.name == "recovery-codes.txt")
        #expect(match.size == 9)

        // Case-insensitive by default, and globs work.
        #expect(try await service.find(context, pattern: "RECOVERY-*.TXT").count == 1)

        // The match restores through the same path a browsed node does.
        let destination = root.appendingPathComponent("restored")
        _ = try await service.restore(
            context,
            snapshotID: result.snapshot,
            node: match.node,
            destinationDirectory: destination
        )
        let restored = destination.appendingPathComponent("recovery-codes.txt")
        #expect(try String(contentsOf: restored, encoding: .utf8) == "the codes")
    }
}
