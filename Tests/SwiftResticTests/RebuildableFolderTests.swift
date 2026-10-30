import Foundation
import Testing

/// The folders the plan page offers to skip after a backup: the rule table,
/// what a plan is offered of the index's finds, and the user's Keep.
@Suite("Rebuildable folders")
struct RebuildableFolderTests {
    @Test("no rule names a folder a developer group already skips by name, and no rule is listed twice")
    func rulesStayOutOfTheSwitches() {
        let named = Set(ExcludeRule.developer.map(\.pattern).filter { $0.hasPrefix("**/") }.map { String($0.dropFirst(3)) })
        let overlapping = RebuildableFolderRule.all.filter { named.contains($0.folder) }
        #expect(overlapping.isEmpty, "covered by a developer group: \(overlapping.map(\.folder))")
        #expect(Set(RebuildableFolderRule.all).count == RebuildableFolderRule.all.count)
    }

    @Test("a plan is offered each find with its rule, less what it skips by path and what the user kept")
    func offered() {
        var plan = BackupPlan()
        plan.path = "/data"
        plan.excludePatterns = [ResticService.globEscaped("/data/skipped[1]/build")]
        plan.keptRebuildableFolders = ["/data/kept/vendor"]
        let found = [
            FolderBesideManifest(path: "/data/app/build", manifest: "build.gradle"),
            FolderBesideManifest(path: "/data/skipped[1]/build", manifest: "build.gradle"),
            FolderBesideManifest(path: "/data/kept/vendor", manifest: "go.mod"),
            FolderBesideManifest(path: "/data/go/vendor", manifest: "go.mod"),
        ]
        let offered = RebuildableFolder.offered(found, to: plan)
        #expect(offered.map(\.path) == ["/data/app/build", "/data/go/vendor"])
        #expect(offered.map(\.rule.why) == ["Gradle builds it again", "go mod vendor makes it again"])
    }

    @Test("a folder the plan skips is known however its pattern was typed: a tilde, a trailing slash")
    func skippedAsTyped() {
        let home = NSHomeDirectory()
        var plan = BackupPlan()
        plan.path = "~/proj"
        plan.excludePatterns = ["~/proj/app/build", "\(home)/proj/go/vendor/"]
        let found = [
            FolderBesideManifest(path: "\(home)/proj/app/build", manifest: "build.gradle"),
            FolderBesideManifest(path: "\(home)/proj/go/vendor", manifest: "go.mod"),
        ]
        #expect(RebuildableFolder.offered(found, to: plan).isEmpty)
    }

    @Test("a folder inside an offered one is left to it, but offered once the outer one is kept")
    func nestedFolders() {
        var plan = BackupPlan()
        plan.path = "/p"
        let found = [
            FolderBesideManifest(path: "/p/vendor", manifest: "go.mod"),
            FolderBesideManifest(path: "/p/vendor/x/build", manifest: "build.gradle"),
        ]
        #expect(RebuildableFolder.offered(found, to: plan).map(\.path) == ["/p/vendor"])
        plan.keptRebuildableFolders = ["/p/vendor"]
        #expect(RebuildableFolder.offered(found, to: plan).map(\.path) == ["/p/vendor/x/build"])
        // A skipped one answers for it as an offered one does.
        plan.keptRebuildableFolders = []
        plan.excludePatterns = ["/p/vendor"]
        #expect(RebuildableFolder.offered(found, to: plan).isEmpty)
    }

    @Test("the folders the user kept survive an editor save and the configuration file")
    func keptSurvives() throws {
        var stored = BackupPlan()
        stored.keptRebuildableFolders = ["/data/kept/vendor"]
        var draft = stored
        draft.keptRebuildableFolders = []
        #expect(stored.merging(draft: draft).keptRebuildableFolders == ["/data/kept/vendor"])
        let decoded = try JSONDecoder().decode(BackupPlan.self, from: JSONEncoder().encode(stored))
        #expect(decoded.keptRebuildableFolders == ["/data/kept/vendor"])
        // A plan saved before the key has kept nothing.
        let older = try JSONDecoder().decode(BackupPlan.self, from: Data(#"{"path": "/data"}"#.utf8))
        #expect(older.keptRebuildableFolders.isEmpty)
    }
}
