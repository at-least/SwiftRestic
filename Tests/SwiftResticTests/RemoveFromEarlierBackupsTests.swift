import Foundation
import Testing

@Suite("Remove from earlier backups")
struct RemoveFromEarlierBackupsTests {
    @Test("a pattern reads back as its one path only when nothing in it is a wildcard")
    func globUnescaped() {
        for path in ["/data/a[1].txt", "/data/what?", "/data/*star", "/data/back\\slash", "/data/plain"] {
            #expect(ResticService.globUnescaped(ResticService.globEscaped(path)) == path)
        }
        for pattern in ["/data/*.log", "**/build", "/data/a?", "/data/[ab]", "/data/trailing\\"] {
            #expect(ResticService.globUnescaped(pattern) == nil, "\(pattern)")
        }
    }

    @Test("a plan's excluded paths are its patterns naming one absolute path inside it, tilde expanded, each once")
    func excludedPaths() {
        var plan = BackupPlan()
        plan.path = "~/Projects"
        plan.excludePatterns = [
            "~/Projects/app/build",
            ResticService.globEscaped("/Users/someone/Projects/x[1]/vendor"),
            "/Users/someone/Projects/app/build",
            "/Users/someone/Projects/app/build/",
            "*.log",
            "node_modules",
            "/Users/someone/Projects/**/dist",
            // Names the plan's folder itself: a backup does not pass it.
            "~/Projects",
        ]
        let found = ResticService.excludedPaths(of: plan, home: "/Users/someone")
        #expect(found == [
            ExcludedPath(pattern: "/Users/someone/Projects/app/build", path: "/Users/someone/Projects/app/build"),
            ExcludedPath(pattern: "/Users/someone/Projects/x\\[1]/vendor", path: "/Users/someone/Projects/x[1]/vendor"),
        ])
    }

    @Test("rewrite's closing line gives the count; any other line is unreadable, never zero")
    func countRewritten() throws {
        let output = """
            create exclusive lock for repository

            snapshot 35de2419 of [/data] at 2026-10-30 05:01:02.172696 +0800 CST by someone@mac
            saved new snapshot c345df07
            removed old snapshot 35de2419

            modified 1 snapshots

            """
        #expect(try ResticService.countRewritten(rewriteOutput: output) == 1)
        #expect(try ResticService.countRewritten(rewriteOutput: "snapshot 1 of [/data]\n\nno snapshots were modified\n") == 0)
        #expect(throws: ResticError.self) { try ResticService.countRewritten(rewriteOutput: "would modify 2 snapshots") }
        #expect(throws: ResticError.self) { try ResticService.countRewritten(rewriteOutput: "") }
    }

    @Test("the run's summary counts items and backups")
    func summary() {
        #expect(RunRecord.rewriteSummary(items: 2, backups: 38) == "Removed 2 items from 38 backups. The space is freed at the next cleanup.")
        #expect(RunRecord.rewriteSummary(items: 1, backups: 0) == "No backup held it.")
    }

    @Test("a rewritten backup still resolves to the run that wrote it, through a chain of rewrites, and survives the file")
    func rewrittenBackupKeepsItsRun() throws {
        var run = RunRecord(kind: .backup, planID: UUID(), planName: "Projects", startedAt: Date(timeIntervalSince1970: 1_790_000_000))
        run.outcome = .completedWithErrors
        run.exitCode = ResticError.backupPartialSuccessCode
        run.snapshotID = "a0"
        func snapshot(_ id: String, original: String?) throws -> Snapshot {
            var document: [String: Any] = ["id": id, "time": "2026-10-30T10:00:00+08:00", "paths": ["/p"]]
            if let original { document["original"] = original }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: document))
        }

        // The first rewrite: restic names the backup's own snapshot.
        let first = try #require(RunRecord.adoptingRewrites([run], listing: [try snapshot("a1", original: "a0")]))
        #expect(RunRecord.backupRunsBySnapshot(first)["a1"]?.snapshotCompleteness == .incomplete)
        // The second names the first's ID, which is gone from the listing.
        let second = try #require(RunRecord.adoptingRewrites(first, listing: [try snapshot("a2", original: "a1")]))
        #expect(RunRecord.backupRunsBySnapshot(second)["a2"]?.id == run.id)
        #expect(second[0].rewrittenSnapshotIDs == ["a1", "a2"])
        #expect(RunRecord.adoptingRewrites(second, listing: [try snapshot("a2", original: "a1")]) == nil)
        #expect(RunRecord.adoptingRewrites(second, listing: [try snapshot("zz", original: "unknown")]) == nil)
        // Two links in one listing, the newer first.
        let both = try #require(RunRecord.adoptingRewrites([run], listing: [try snapshot("b2", original: "b1"), try snapshot("b1", original: "a0")]))
        #expect(RunRecord.backupRunsBySnapshot(both)["b2"]?.id == run.id)

        let decoded = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(second[0]))
        #expect(decoded.rewrittenSnapshotIDs == ["a1", "a2"])
    }
}
