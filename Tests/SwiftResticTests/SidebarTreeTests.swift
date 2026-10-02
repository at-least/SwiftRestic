import Foundation
import Testing

/// The sidebar's shape, as the pure rules the view lays out: repositories at
/// the top, each with its plans — which fold open to their own backups — the
/// way to its first plan while it has none, and Other backups for whatever
/// no plan of the repository made.
@Suite("Sidebar tree")
struct SidebarTreeTests {
    private func plan(_ name: String, in repository: UUID?) -> BackupPlan {
        var plan = BackupPlan()
        plan.name = name
        plan.repositoryID = repository
        return plan
    }

    private func repository(_ name: String) -> Repository {
        var repository = Repository()
        repository.name = name
        return repository
    }

    private func snapshot(
        _ id: String,
        time: String,
        paths: [String] = ["/Data/Documents"],
        host: String = "mac",
        tags: [String] = []
    ) throws -> Snapshot {
        let array = { (strings: [String]) in String(decoding: try JSONEncoder().encode(strings), as: UTF8.self) }
        let json = """
        {"id":"\(id)","short_id":"\(id.prefix(8))","time":"\(time)","paths":\(try array(paths)),\
        "hostname":"\(host)","tags":\(try array(tags))}
        """
        return try ResticMessageDecoder.jsonDecoder.decode(Snapshot.self, from: Data(json.utf8))
    }

    @Test("a repository lists its own plans in configuration order, then Other backups only while it holds any")
    func plansThenOtherBackups() {
        let nas = UUID()
        let documents = plan("Documents", in: nas)
        let elsewhere = plan("Elsewhere", in: UUID())
        let photos = plan("Photos", in: nas)
        let plans = [documents, elsewhere, photos]
        #expect(SidebarTree.children(of: nas, in: plans, hasOtherBackups: false)
            == [.plan(documents.id), .plan(photos.id)])
        #expect(SidebarTree.children(of: nas, in: plans, hasOtherBackups: true)
            == [.plan(documents.id), .plan(photos.id), .otherBackups(repositoryID: nas)])
    }

    @Test("no two repositories' children share an identity")
    func childrenAreUniqueAcrossRepositories() {
        // The List gives every repository's children one identity space: a
        // shared Other backups row showed up, empty, under repositories
        // that hold none.
        let nas = UUID()
        let fresh = UUID()
        let all = SidebarTree.children(of: nas, in: [], hasOtherBackups: true)
            + SidebarTree.children(of: fresh, in: [], hasOtherBackups: true)
        #expect(Set(all).count == all.count)
    }

    @Test("a repository with no plan offers its first one where its plans would be")
    func noPlanOffersOne() {
        // The dead end the user reported: a new repository and nowhere to
        // add a plan to it.
        let test = UUID()
        #expect(SidebarTree.children(of: test, in: [plan("Elsewhere", in: UUID())], hasOtherBackups: false)
            == [.addPlan(repositoryID: test)])
        // A repository that already held backups when it was added.
        #expect(SidebarTree.children(of: test, in: [], hasOtherBackups: true)
            == [.addPlan(repositoryID: test), .otherBackups(repositoryID: test)])
    }

    @Test("Other backups is just Backups while the repository has no plan to be other than")
    func otherBackupsTitle() {
        #expect(SidebarTree.otherBackupsTitle(repositoryHasPlans: true) == "Other backups")
        #expect(SidebarTree.otherBackupsTitle(repositoryHasPlans: false) == "Backups")
    }

    @Test("the landing pane is the first repository's page, or the welcome when there is none")
    func landing() {
        let nas = repository("NAS")
        let b2 = repository("B2")
        #expect(SidebarTree.landingSelection(repositories: [nas, b2]) == .repository(nas.id))
        #expect(SidebarTree.landingSelection(repositories: []) == nil)
    }

    @Test("a backup sits under the plan of the repository that made it, the rest under Other backups by lineage")
    func shelves() throws {
        let nas = UUID()
        let documents = plan("Documents", in: nas)
        let photos = plan("Photos", in: nas)
        let movedAway = plan("Music", in: UUID())
        let docsTag = ResticService.planTag(documents.id)
        let photosTag = ResticService.planTag(photos.id)

        // Newest first, as ResticService.snapshots sorts the listing.
        let d2 = try snapshot("d2", time: "2026-09-30T02:00:00Z", tags: [docsTag])
        let p1 = try snapshot("p1", time: "2026-09-29T03:00:00Z", paths: ["/Data/Photos"], tags: [photosTag])
        // A plan whose folders changed keeps every backup under it, one flat
        // list: the Change column finds its baseline by lineage, not by row.
        let d1 = try snapshot("d1", time: "2026-09-29T02:00:00Z", paths: ["/Data/Old"], tags: [docsTag])
        // A plan that now backs up elsewhere left these behind.
        let m1 = try snapshot("m1", time: "2026-09-28T02:00:00Z", paths: ["/Data/Music"],
                              tags: [ResticService.planTag(movedAway.id)])
        // Another Mac or the console: no plan tag at all.
        let x1 = try snapshot("x1", time: "2026-09-27T02:00:00Z", paths: ["/Data/Music"], host: "old-mac")
        // A deleted plan's tag.
        let g1 = try snapshot("g1", time: "2026-09-26T02:00:00Z", paths: ["/Data/Gone"],
                              tags: [ResticService.planTag(UUID())])

        let shelves = BackupShelves(listing: [d2, p1, d1, m1, x1, g1], plans: [documents, photos])
        #expect(shelves.byPlan[documents.id]?.map(\.id) == ["d2", "d1"])
        #expect(shelves.byPlan[photos.id]?.map(\.id) == ["p1"])
        #expect(shelves.others.map { $0.snapshots.map(\.id) } == [["m1"], ["x1"], ["g1"]])
        #expect(shelves.hasOtherBackups)

        // Every backup a plan of the repository made: no Other backups.
        let tidy = BackupShelves(listing: [d2, p1, d1], plans: [documents, photos])
        #expect(!tidy.hasOtherBackups)
        // A repository without plans: all of it is other.
        #expect(BackupShelves(listing: [d2], plans: []).others.map(\.key) == [d2.lineageKey])
    }

    @Test("a backup two plans' tags claim sits under the first of them, once")
    func dualTaggedBackupHasOneHome() throws {
        // Only `restic tag` from outside can do this; the app never does. Every
        // backup still renders exactly once, so its selection stays unique.
        let nas = UUID()
        let documents = plan("Documents", in: nas)
        let photos = plan("Photos", in: nas)
        let both = try snapshot("b1", time: "2026-09-30T02:00:00Z",
                                tags: [ResticService.planTag(photos.id), ResticService.planTag(documents.id)])
        let shelves = BackupShelves(listing: [both], plans: [documents, photos])
        #expect(shelves.byPlan[documents.id]?.map(\.id) == ["b1"])
        #expect(shelves.byPlan[photos.id] == nil)
        #expect(BackupShelves.owner(of: both, among: [documents, photos]) == documents.id)
        #expect(BackupShelves.owner(of: both, among: [photos, documents]) == photos.id)
    }

    @Test("picking a backup from anywhere opens the fold it sits in")
    func revealOpensTheOwner() throws {
        let nas = UUID()
        let documents = plan("Documents", in: nas)
        let mine = try snapshot("d1", time: "2026-09-30T02:00:00Z", tags: [ResticService.planTag(documents.id)])
        let foreign = try snapshot("x1", time: "2026-09-29T02:00:00Z", host: "old-mac")

        var folds = SidebarFolds()
        folds.reveal(mine, in: nas, plans: [documents])
        #expect(folds == SidebarFolds(plans: [documents.id], otherBackups: []))
        folds.reveal(foreign, in: nas, plans: [documents])
        #expect(folds == SidebarFolds(plans: [documents.id], otherBackups: [nas]))
    }

    @Test("a backup is named for where it sits: its plan, or its group among the Other backups")
    func labelsFollowTheShelf() throws {
        let nas = UUID()
        let hourly = plan("Hourly Docs", in: nas)
        let nightly = plan("Nightly Docs", in: nas)
        let music = plan("Music", in: UUID())
        let allPlans = [hourly, nightly, music]

        // Two plans backing up the same folders: one lineage, which the
        // lineage rule names after its folders. In the sidebar each backup
        // sits under its own plan, so it is named for that plan.
        let h1 = try snapshot("h1", time: "2026-09-30T03:00:00Z", paths: ["/Data/Docs"],
                              tags: [ResticService.planTag(hourly.id)])
        let n1 = try snapshot("n1", time: "2026-09-30T02:00:00Z", paths: ["/Data/Docs"],
                              tags: [ResticService.planTag(nightly.id)])
        // The hourly plan once backed up another folder too.
        let h0 = try snapshot("h0", time: "2026-09-29T03:00:00Z", paths: ["/Data/Docs", "/Data/Notes"],
                              tags: [ResticService.planTag(hourly.id)])
        let m1 = try snapshot("m1", time: "2026-09-28T02:00:00Z", paths: ["/Data/Music"],
                              tags: [ResticService.planTag(music.id)])
        let x1 = try snapshot("x1", time: "2026-09-27T02:00:00Z", paths: ["/Data/Music"], host: "old-mac")
        let shelves = BackupShelves(listing: [h1, n1, h0, m1, x1], plans: [hourly, nightly])

        #expect(shelves.label(of: n1, allPlans: allPlans) == SnapshotLineage.Label(
            title: "Nightly Docs",
            qualifier: nil,
            detail: "/Data/Docs — from mac"
        ))
        // A plan whose backups span two sets of folders: the folders say
        // which one an open backup holds.
        #expect(shelves.label(of: h1, allPlans: allPlans)?.title == "Hourly Docs")
        #expect(shelves.label(of: h1, allPlans: allPlans)?.qualifier == "/Data/Docs")
        #expect(shelves.label(of: h0, allPlans: allPlans)?.qualifier == "/Data/Docs, /Data/Notes")

        // Under Other backups, among the groups shown there together: two
        // hosts, so each says which; the moved plan's group keeps its name.
        let others = shelves.otherLabels(allPlans: allPlans)
        #expect(others[m1.lineageKey]?.title == "Music")
        #expect(others[m1.lineageKey]?.qualifier == "mac · /Data/Music")
        #expect(others[x1.lineageKey]?.qualifier == "old-mac · /Data/Music")
        #expect(shelves.label(of: x1, allPlans: allPlans) == others[x1.lineageKey])
    }

    @Test("a group under Other backups that one plan wrote names the plan, which now backs up elsewhere")
    func formerPlan() throws {
        // Documents moved to B2; the repository on screen keeps what it
        // backed up before, and has no plan of its own.
        let documents = plan("Documents", in: UUID())
        let m1 = try snapshot("m1", time: "2026-09-28T02:00:00Z", tags: [ResticService.planTag(documents.id)])
        let x1 = try snapshot("x1", time: "2026-09-27T02:00:00Z", paths: ["/Data/Music"], host: "old-mac")
        let shelves = BackupShelves(listing: [m1, x1], plans: [])
        #expect(shelves.others.map { shelves.formerPlan(of: $0, allPlans: [documents])?.id }
            == [documents.id, nil])
        // A console backup of the same folders: no single plan wrote the group.
        let console = try snapshot("c1", time: "2026-09-26T02:00:00Z")
        let shared = BackupShelves(listing: [m1, console], plans: [])
        #expect(shared.others.map { shared.formerPlan(of: $0, allPlans: [documents])?.id } == [nil])
    }

    @Test("a repository needs attention for an unreadable listing or a known-unprotected plan, never for pending or running ones")
    func attention() {
        let repository = UUID()
        func row(_ name: String, isKnown: Bool, isProtected: Bool, didFail: Bool = false, isRunning: Bool = false) -> ProtectionRow {
            ProtectionRow(
                plan: plan(name, in: repository),
                stateText: name,
                isKnown: isKnown,
                isProtected: isProtected,
                didFail: didFail,
                isRunning: isRunning
            )
        }
        let unreadable = row("Unreadable", isKnown: false, isProtected: false, didFail: true)
        let exposed = row("Exposed", isKnown: true, isProtected: false)
        let pending = row("Pending", isKnown: false, isProtected: false)
        let running = row("Running", isKnown: true, isProtected: false, isRunning: true)
        let protected = row("Protected", isKnown: true, isProtected: true)

        #expect(OverviewMetrics.needingAttention([protected, unreadable, pending, exposed, running]).map(\.planName)
            == ["Unreadable", "Exposed"])
        #expect(OverviewMetrics.needingAttention([protected, pending, running]).isEmpty)
    }
}
