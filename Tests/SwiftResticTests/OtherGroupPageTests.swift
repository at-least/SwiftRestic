import Foundation
import Testing

/// The page a group's selection shows under Other backups, either kind: one
/// derivation (`OtherGroupPageSummary`) for the explanation's sentence and
/// the Backups card's rows, fed by the same labels that name the sidebar row.
@Suite("Other backups group page")
struct OtherGroupPageTests {
    private func snapshot(
        _ id: String,
        time: String,
        paths: [String] = ["/Data/Documents"],
        host: String = "mac",
        tags: [String] = [],
        excludes: [String]? = nil
    ) throws -> Snapshot {
        // Arrays through JSONEncoder: interpolating a Swift array writes its
        // debug description, whose escaped quotes end up inside the strings.
        let array = { (strings: [String]) in String(decoding: try JSONEncoder().encode(strings), as: UTF8.self) }
        let excludesJSON = try excludes.map { ",\"excludes\":\(try array($0))" } ?? ""
        let json = """
        {"id":"\(id)","short_id":"\(id.prefix(8))","time":"\(time)","paths":\(try array(paths)),\
        "hostname":"\(host)","tags":\(try array(tags))\(excludesJSON)}
        """
        return try ResticMessageDecoder.jsonDecoder.decode(Snapshot.self, from: Data(json.utf8))
    }

    @Test("an adoptable group's page explains what the history is, without asserting which cause")
    func adoptableExplanation() throws {
        let deleted = UUID()
        let tag = ResticService.planTag(deleted)
        // The plan's folders changed mid-history, and its exclude list with
        // them — the union is the page's row, newest patterns first.
        let g2 = try snapshot(
            "g2", time: "2026-10-02T02:00:00Z", paths: ["/Data/Projects"],
            tags: [tag, "travel"], excludes: ["node_modules", ".env"]
        )
        let g1 = try snapshot(
            "g1", time: "2026-09-28T02:00:00Z", paths: ["/Data/Old"],
            tags: [tag, "travel"], excludes: ["node_modules", ".DS_Store"]
        )
        let shelves = BackupShelves(listing: [g2, g1], plans: [], allPlans: [])
        let page = try #require(shelves.otherGroupPage(.plan(deleted), repositories: [], localHost: "mac"))

        #expect(page.title == "Projects")
        #expect(page.explanation == "These 2 backups carry the ID of a plan that isn't set up in SwiftRestic"
            + " — it was deleted here, or it's still running on another Mac.")
        #expect(page.formerPlan == nil)
        #expect(page.newestSnapshotID == "g2")
        #expect(page.newestAt == g2.time)
        #expect(page.oldestAt == g1.time)
        #expect(page.madeFrom == "mac")
        // One line per folder set, the newest set first.
        #expect(page.folders == ["/Data/Projects", "/Data/Old"])
        #expect(page.excludes == ["node_modules", ".env", ".DS_Store"])
        // Plan tags are the group's plumbing, not a user tag.
        #expect(page.userTags == ["travel"])
        #expect(page.planTag == tag)
    }

    @Test("one adoptable backup reads in the singular")
    func adoptableSingular() throws {
        let deleted = UUID()
        let only = try snapshot("g1", time: "2026-10-01T02:00:00Z", tags: [ResticService.planTag(deleted)])
        let shelves = BackupShelves(listing: [only], plans: [], allPlans: [])
        #expect(shelves.otherGroupPage(.plan(deleted), repositories: [], localHost: "mac")?.explanation
            == "This backup carries the ID of a plan that isn't set up in SwiftRestic"
                + " — it was deleted here, or it's still running on another Mac.")
    }

    @Test("a moved plan's page names the plan and where it went, and carries the plan to open")
    func movedExplanation() throws {
        var offsite = Repository()
        offsite.name = "Offsite"
        var music = BackupPlan()
        music.name = "Music"
        music.repositoryID = offsite.id
        let tag = ResticService.planTag(music.id)
        let m2 = try snapshot("m2", time: "2026-10-02T02:00:00Z", paths: ["/Data/Music"], tags: [tag])
        let m1 = try snapshot("m1", time: "2026-09-28T02:00:00Z", paths: ["/Data/Music"], tags: [tag])
        let home = BackupShelves(listing: [m2, m1], plans: [], allPlans: [music])

        let page = try #require(home.otherGroupPage(.plan(music.id), repositories: [offsite], localHost: "mac"))
        #expect(page.explanation == "These are the 2 backups “Music” made here before it moved to “Offsite”.")
        #expect(page.formerPlan == music)
        #expect(page.title == "Music")

        // One backup, and a plan whose repository is gone from the list: the
        // sentence says it left, never where — the sidebar's caption stays
        // silent the same way rather than naming a wrong destination.
        let single = BackupShelves(listing: [m2], plans: [], allPlans: [music])
        #expect(single.otherGroupPage(.plan(music.id), repositories: [offsite], localHost: "mac")?.explanation
            == "This is the backup “Music” made here before it moved to “Offsite”.")
        #expect(single.otherGroupPage(.plan(music.id), repositories: [], localHost: "mac")?.explanation
            == "This is the backup “Music” made here before it moved away.")
    }

    @Test("a history several Macs made counts them, then names them")
    func madeFromSeveralMacs() throws {
        let deleted = UUID()
        let tag = ResticService.planTag(deleted)
        let g3 = try snapshot("g3", time: "2026-10-02T02:00:00Z", paths: ["/Data/Docs"], tags: [tag])
        let g2 = try snapshot("g2", time: "2026-10-01T02:00:00Z", paths: ["/Data/Old"], host: "laptop", tags: [tag])
        let g1 = try snapshot("g1", time: "2026-09-30T02:00:00Z", paths: ["/Data/Docs"], tags: [tag])
        let shelves = BackupShelves(listing: [g3, g2, g1], plans: [], allPlans: [])
        let page = try #require(shelves.otherGroupPage(.plan(deleted), repositories: [], localHost: "mac"))
        // The count leads, so a long hostname cannot push it out; the list
        // follows in first-seen order, the newest backup's Mac first.
        #expect(page.madeFrom == "2 Macs — mac, laptop")
    }

    @Test("two Macs that backed up the same folders spell one Folders line")
    func foldersAcrossMacs() throws {
        let deleted = UUID()
        let tag = ResticService.planTag(deleted)
        // The same plan definition on a second Mac with the same folders:
        // two lineages (restic groups them apart) whose one line the page
        // must not repeat — the rows key on the string, and "Made from"
        // already names them both.
        let g2 = try snapshot("g2", time: "2026-10-02T02:00:00Z", paths: ["/Data/Documents"], host: "laptop", tags: [tag])
        let g1 = try snapshot("g1", time: "2026-10-01T02:00:00Z", paths: ["/Data/Documents"], host: "mac", tags: [tag])
        let shelves = BackupShelves(listing: [g2, g1], plans: [], allPlans: [])
        let page = try #require(shelves.otherGroupPage(.plan(deleted), repositories: [], localHost: "mac"))
        #expect(page.madeFrom == "2 Macs — laptop, mac")
        #expect(page.folders == ["/Data/Documents"])
    }

    @Test("the page is gone once the group is — adopted, moved to this repository, or refreshed away")
    func pageFollowsTheGroup() throws {
        let planID = UUID()
        let g1 = try snapshot("g1", time: "2026-10-01T02:00:00Z", tags: [ResticService.planTag(planID)])
        let orphaned = BackupShelves(listing: [g1], plans: [], allPlans: [])
        #expect(orphaned.orphanPlanGroup(planID)?.id == .plan(planID))

        // The plan is configured for this repository: the backup shelves
        // under it, the group is gone, and so is the page.
        var plan = BackupPlan()
        plan.repositoryID = UUID()
        plan.id = planID
        let shelved = BackupShelves(listing: [g1], plans: [plan], allPlans: [plan])
        #expect(shelved.orphanPlanGroup(planID) == nil)
        #expect(shelved.otherGroupPage(.plan(planID), repositories: [], localHost: "mac") == nil)
        // An unknown UUID was never a group here.
        #expect(orphaned.orphanPlanGroup(UUID()) == nil)
    }

    @Test("an untagged lineage's page says it can't be adopted, has no plan tag, and reads its files from its own chain")
    func lineagePage() throws {
        let l2 = try snapshot("l2", time: "2026-10-02T02:00:00Z", paths: ["/Data/Music"], host: "studio", tags: ["manual"])
        let l1 = try snapshot("l1", time: "2026-09-30T02:00:00Z", paths: ["/Data/Music"], host: "studio")
        let shelves = BackupShelves(listing: [l2, l1], plans: [], allPlans: [])
        let key = l2.lineageKey
        #expect(shelves.lineageGroup(key)?.id == .lineage(key))
        let page = try #require(shelves.otherGroupPage(.lineage(key), repositories: [], localHost: "mac"))

        #expect(page.title == "Music")
        #expect(page.explanation == "These 2 backups carry no plan ID — they were made outside SwiftRestic — so they can't be adopted as a plan.")
        #expect(page.formerPlan == nil)
        #expect(page.planTag == nil)
        #expect(page.chainKey == SnapshotIndex.chainKey(for: l2))
        #expect(page.chainKey == SnapshotIndex.chainKey(for: l1))
        #expect(page.newestSnapshotID == "l2")
        #expect(page.madeFrom == "studio")
        #expect(page.folders == ["/Data/Music"])
        #expect(page.userTags == ["manual"])

        let single = BackupShelves(listing: [l1], plans: [], allPlans: [])
        #expect(single.otherGroupPage(.lineage(key), repositories: [], localHost: "mac")?.explanation
            == "This backup carries no plan ID — it was made outside SwiftRestic — so it can't be adopted as a plan.")
        // Gone once no backup of it is left.
        let empty = BackupShelves(listing: [], plans: [], allPlans: [])
        #expect(empty.lineageGroup(key) == nil)
        #expect(empty.otherGroupPage(.lineage(key), repositories: [], localHost: "mac") == nil)
    }

    @Test("a plan-UUID group's page reads its files from the plan tag's chain")
    func planGroupChain() throws {
        let deleted = UUID()
        let tag = ResticService.planTag(deleted)
        let g1 = try snapshot("g1", time: "2026-10-01T02:00:00Z", tags: [tag])
        let shelves = BackupShelves(listing: [g1], plans: [], allPlans: [])
        let page = try #require(shelves.otherGroupPage(.plan(deleted), repositories: [], localHost: "mac"))
        #expect(page.chainKey == tag)
        #expect(page.planTag == tag)
    }
}
