import Foundation
import Testing

/// Remove from Earlier Backups' pure parts: which of a plan's patterns name
/// one path, and what restic's rewrite said.
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
}
