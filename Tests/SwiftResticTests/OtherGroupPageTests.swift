import Foundation
import Testing

/// The page a group's selection shows under Other backups, either kind: one
/// derivation (`OtherGroupPageSummary`) for the explanation's sentence, fed by
/// the same labels that name the sidebar row.
@Suite("Other backups group page")
struct OtherGroupPageTests {
    private func snapshot(
        _ id: String,
        time: String,
        paths: [String] = ["/Data/Documents"],
        host: String = "mac",
        tags: [String] = []
    ) throws -> Snapshot {
        try snapshotFixture(
            id: id, time: time, paths: paths, includeShortID: true, hostname: host, tags: tags
        )
    }

    @Test("an adoptable group's page explains what the history is, without asserting which cause")
    func adoptableExplanation() throws {
        let deleted = UUID()
        let tag = ResticService.planTag(deleted)
        let g2 = try snapshot("g2", time: "2026-10-02T02:00:00Z", paths: ["/Data/Projects"], tags: [tag])
        let g1 = try snapshot("g1", time: "2026-09-28T02:00:00Z", paths: ["/Data/Old"], tags: [tag])
        let shelves = BackupShelves(listing: [g2, g1], plans: [], allPlans: [])
        let page = try #require(shelves.otherGroupPage(.plan(deleted), repositories: [], localHost: "mac"))

        #expect(page.title == "Projects")
        #expect(page.isAdoptable)
        #expect(page.explanation == "From a plan that isn’t set up here — removed, or still running on another Mac.")
    }

    @Test("a moved plan's page says it can't be continued here")
    func movedExplanation() throws {
        var offsite = Repository()
        offsite.localPath = "/Users/someone/Offsite"
        var music = BackupPlan()
        music.repositoryID = offsite.id
        music.path = "/Data/Music"
        let tag = ResticService.planTag(music.id)
        let m2 = try snapshot("m2", time: "2026-10-02T02:00:00Z", paths: ["/Data/Music"], tags: [tag])
        let m1 = try snapshot("m1", time: "2026-09-28T02:00:00Z", paths: ["/Data/Music"], tags: [tag])
        let home = BackupShelves(listing: [m2, m1], plans: [], allPlans: [music])

        let page = try #require(home.otherGroupPage(.plan(music.id), repositories: [offsite], localHost: "mac"))
        #expect(!page.isAdoptable)
        #expect(page.title == "Music")
        #expect(page.explanation == "From a plan that now backs up somewhere else, so they can’t be continued here.")
        let single = BackupShelves(listing: [m2], plans: [], allPlans: [music])
        #expect(single.otherGroupPage(.plan(music.id), repositories: [offsite], localHost: "mac")?.explanation
            == "From a plan that now backs up somewhere else, so it can’t be continued here.")
    }

    @Test("a history of several folders isn't offered as continuable, and says why")
    func severalFoldersExplanation() throws {
        let deleted = UUID()
        let tag = ResticService.planTag(deleted)
        let several = try snapshot("s1", time: "2026-10-03T02:00:00Z", paths: ["/Data/Documents", "/Data/Pictures"], tags: [tag])
        let page = try #require(BackupShelves(listing: [several], plans: [], allPlans: [])
            .otherGroupPage(.plan(deleted), repositories: [], localHost: "mac"))
        #expect(!page.isAdoptable)
        #expect(page.explanation.contains("It holds several folders"))
    }

    @Test("a repository's page offers Continue Backups for what this Mac can continue, and nothing otherwise")
    func continuePrompt() throws {
        let first = UUID()
        let second = UUID()
        let a = try snapshot("a", time: "2026-10-02T02:00:00Z", paths: ["/Data/Documents"], tags: [ResticService.planTag(first)])
        let b = try snapshot("b", time: "2026-10-01T02:00:00Z", paths: ["/Data/Music"], tags: [ResticService.planTag(second)])
        let manual = try snapshot("m", time: "2026-09-01T02:00:00Z", paths: ["/Data/Manual"])

        let one = try #require(BackupShelves(listing: [a, manual], plans: [], allPlans: [])
            .continuePrompt(repositories: [], localHost: "mac"))
        #expect(one.isOne)
        #expect(one.firstPlanID == first)
        #expect(one.text == "“Documents” has backups here. You can continue them from this Mac.")

        let two = try #require(BackupShelves(listing: [a, b], plans: [], allPlans: [])
            .continuePrompt(repositories: [], localHost: "mac"))
        #expect(!two.isOne)
        #expect(two.firstPlanID == first, "newest first, as the sidebar lists them")
        #expect(two.text == "2 plans have backups here. You can continue them from this Mac.")

        #expect(BackupShelves(listing: [manual], plans: [], allPlans: [])
            .continuePrompt(repositories: [], localHost: "mac") == nil)
    }

    @Test("the page is gone once the group is — adopted, moved to this repository, or refreshed away")
    func pageFollowsTheGroup() throws {
        let planID = UUID()
        let g1 = try snapshot("g1", time: "2026-10-01T02:00:00Z", tags: [ResticService.planTag(planID)])
        let orphaned = BackupShelves(listing: [g1], plans: [], allPlans: [])
        #expect(orphaned.orphanPlanGroup(planID)?.id == .plan(planID))

        var plan = BackupPlan()
        plan.repositoryID = UUID()
        plan.id = planID
        let shelved = BackupShelves(listing: [g1], plans: [plan], allPlans: [plan])
        #expect(shelved.orphanPlanGroup(planID) == nil)
        #expect(shelved.otherGroupPage(.plan(planID), repositories: [], localHost: "mac") == nil)
        #expect(orphaned.orphanPlanGroup(UUID()) == nil)
    }

    @Test("an untagged lineage's page says it can't be adopted")
    func lineagePage() throws {
        let l2 = try snapshot("l2", time: "2026-10-02T02:00:00Z", paths: ["/Data/Music"], host: "studio", tags: ["manual"])
        let l1 = try snapshot("l1", time: "2026-09-30T02:00:00Z", paths: ["/Data/Music"], host: "studio")
        let shelves = BackupShelves(listing: [l2, l1], plans: [], allPlans: [])
        let key = l2.lineageKey
        #expect(shelves.lineageGroup(key)?.id == .lineage(key))
        let page = try #require(shelves.otherGroupPage(.lineage(key), repositories: [], localHost: "mac"))

        #expect(page.title == "Music")
        #expect(!page.isAdoptable)
        #expect(page.explanation == "Made outside SwiftRestic, so they can’t be continued.")

        let single = BackupShelves(listing: [l1], plans: [], allPlans: [])
        #expect(single.otherGroupPage(.lineage(key), repositories: [], localHost: "mac")?.explanation
            == "Made outside SwiftRestic, so it can’t be continued.")
        let empty = BackupShelves(listing: [], plans: [], allPlans: [])
        #expect(empty.lineageGroup(key) == nil)
        #expect(empty.otherGroupPage(.lineage(key), repositories: [], localHost: "mac") == nil)
    }
}
