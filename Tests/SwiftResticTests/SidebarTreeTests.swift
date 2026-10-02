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

    @Test("a backup sits under the plan of the repository that made it, the rest under Other backups by plan or lineage")
    func shelves() throws {
        let nas = UUID()
        let documents = plan("Documents", in: nas)
        let photos = plan("Photos", in: nas)
        let movedAway = plan("Music", in: UUID())
        let deleted = UUID()
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
                              tags: [ResticService.planTag(deleted)])

        let shelves = BackupShelves(listing: [d2, p1, d1, m1, x1, g1], plans: [documents, photos],
                                    allPlans: [documents, photos, movedAway])
        #expect(shelves.byPlan[documents.id]?.map(\.id) == ["d2", "d1"])
        #expect(shelves.byPlan[photos.id]?.map(\.id) == ["p1"])
        // The groups interleave newest-first, whatever kind they are.
        #expect(shelves.others.map(\.id) == [.plan(movedAway.id), .lineage(x1.lineageKey), .plan(deleted)])
        #expect(shelves.others.map { $0.snapshots.map(\.id) } == [["m1"], ["x1"], ["g1"]])
        #expect(shelves.hasOtherBackups)

        // Every backup a plan of the repository made: no Other backups.
        let tidy = BackupShelves(listing: [d2, p1, d1], plans: [documents, photos], allPlans: [documents, photos])
        #expect(!tidy.hasOtherBackups)
        // A repository without plans: all of it is other, still by plan.
        #expect(BackupShelves(listing: [d2], plans: [], allPlans: []).others.map(\.id) == [.plan(documents.id)])
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
        let shelves = BackupShelves(listing: [both], plans: [documents, photos], allPlans: [documents, photos])
        #expect(shelves.byPlan[documents.id]?.map(\.id) == ["b1"])
        #expect(shelves.byPlan[photos.id] == nil)
        #expect(BackupShelves.owner(of: both, among: [documents, photos]) == documents.id)
        #expect(BackupShelves.owner(of: both, among: [photos, documents]) == photos.id)
    }

    @Test("an orphan two deleted plans' tags claim sits with the lexicographically first")
    func dualTaggedOrphanHasOneHome() throws {
        // The snapshot index's own rule for the same outside-`restic tag`
        // situation, whatever order the tags arrive in.
        let first = UUID(uuidString: "0a000000-0000-4000-8000-00000000000a")!
        let second = UUID(uuidString: "0b000000-0000-4000-8000-00000000000b")!
        let both = try snapshot("o1", time: "2026-09-30T02:00:00Z",
                                tags: [ResticService.planTag(second), ResticService.planTag(first)])
        let shelves = BackupShelves(listing: [both], plans: [], allPlans: [])
        #expect(shelves.others.map(\.id) == [.plan(first)])
        #expect(shelves.others.map { $0.snapshots.map(\.id) } == [["o1"]])
    }

    @Test("a plan tag's UUID parses back to the plan, and nothing else does")
    func planUUIDRoundTrip() {
        let planID = UUID()
        #expect(ResticService.planUUID(fromTag: ResticService.planTag(planID)) == planID)
        // Anything else names no plan: another client's tag, a plain word,
        // a mangled tail, or the UUID in upper case.
        #expect(ResticService.planUUID(fromTag: "swiftrestic-plan-") == nil)
        #expect(ResticService.planUUID(fromTag: "swiftrestic-plan-not-a-uuid") == nil)
        #expect(ResticService.planUUID(fromTag: "vacation") == nil)
        #expect(ResticService.planUUID(fromTag: "") == nil)
        // The prefix stays, the UUID's tail goes upper case: the tail still
        // parses, so it is the round trip — the tag the app writes is lower
        // case — that rejects it.
        let upper = ResticService.planTagPrefix + planID.uuidString.uppercased()
        #expect(ResticService.planUUID(fromTag: upper) == nil)
    }

    @Test("one plan's history stays one group across hosts and folder sets, newest member first")
    func spanningGroupStaysOne() throws {
        let deleted = UUID()
        let tag = ResticService.planTag(deleted)
        let newest = try snapshot("g3", time: "2026-09-30T02:00:00Z", paths: ["/Data/Docs"], tags: [tag])
        // The plan ran from a laptop for a while, then dropped a folder.
        let laptop = try snapshot("g2", time: "2026-09-29T02:00:00Z", paths: ["/Data/Old"],
                                  host: "laptop", tags: [tag])
        let oldest = try snapshot("g1", time: "2026-09-28T02:00:00Z", paths: ["/Data/Docs"], tags: [tag])
        let shelves = BackupShelves(listing: [oldest, laptop, newest], plans: [], allPlans: [])
        #expect(shelves.others.map(\.id) == [.plan(deleted)])
        #expect(shelves.others[0].snapshots.map(\.id) == ["g3", "g2", "g1"])
        // The newest member names the group. It came from this Mac, so the
        // caption names no Mac at all — the laptop's backups do not change
        // that.
        let label = shelves.otherLabels(repositories: [], localHost: "mac")[shelves.others[0].id]
        #expect(label?.title == "Docs")
        #expect(label?.caption?.text == "3 backups · not set up here")
        #expect(label?.qualifier == nil)
        // Read on the laptop, the newest backup is another Mac's, and the
        // caption says whose: the host is a piece that gives way, the kind
        // one that stays whole.
        let onLaptop = shelves.otherLabels(repositories: [], localHost: "laptop")[shelves.others[0].id]
        #expect(onLaptop?.caption == .init(count: "3 backups", qualifiers: ["mac"], kind: ["not set up here"]))
        #expect(onLaptop?.qualifier == "mac")
    }

    @Test("a group's caption says which of the three kinds it is")
    func captionKinds() throws {
        let offsite = repository("Offsite")
        let music = plan("Music", in: offsite.id)
        // A plan that now backs up elsewhere; a console backup; a deleted
        // plan's history. All from this Mac, so no caption names a host.
        let m1 = try snapshot("m1", time: "2026-09-30T02:00:00Z", paths: ["/Data/Music"],
                              tags: [ResticService.planTag(music.id)])
        let x1 = try snapshot("x1", time: "2026-09-29T02:00:00Z", paths: ["/Data/Sites"])
        let deleted = UUID()
        let g1 = try snapshot("g1", time: "2026-09-28T02:00:00Z", paths: ["/Data/Gone"],
                              tags: [ResticService.planTag(deleted)])
        let shelves = BackupShelves(listing: [m1, x1, g1], plans: [], allPlans: [music])
        let labels = shelves.otherLabels(repositories: [offsite], localHost: "mac")
        #expect(labels[.plan(music.id)]?.caption?.text == "1 backup · now backs up to “Offsite”")
        #expect(labels[.lineage(x1.lineageKey)]?.caption?.text == "1 backup · outside SwiftRestic")
        #expect(labels[.plan(deleted)]?.caption?.text == "1 backup · not set up here")
        #expect(labels[.plan(music.id)]?.detail
            == "/Data/Music — from mac\nThe “Music” plan backs up to “Offsite” now; these are its earlier backups.")
        #expect(labels[.plan(deleted)]?.detail == "/Data/Gone — from mac\nBacked up by a plan not set up here")
        #expect(labels[.lineage(x1.lineageKey)]?.detail == "/Data/Sites — from mac\n"
            + "These backups carry no plan ID, so they can't be adopted. "
            + "restic's `tag` command (Repository ▸ restic Console…) can give them one, "
            + "but it rewrites every snapshot's ID.")
        // The restore header names the orphan record by its group, as the
        // sidebar row does.
        #expect(RestoreRecordHeading(record: g1, label: labels[.plan(deleted)], comparison: nil).name
            == "Gone")
    }

    @Test("the newest member's folders read sorted, whatever order its snapshot lists them in")
    func unsortedPathsReadSorted() throws {
        // Only restic's own listing is sorted; another writer's snapshot can
        // list its paths any way. The lineage key's sorted rule is the one
        // every folder list reads — and here it also qualifies the two
        // groups' shared title.
        let deleted = UUID()
        let g1 = try snapshot("g1", time: "2026-09-30T02:00:00Z", paths: ["/Data/Zeta", "/Data/Alpha"],
                              tags: [ResticService.planTag(deleted)])
        let x1 = try snapshot("x1", time: "2026-09-29T02:00:00Z", paths: ["/Data/Zeta", "/Data/Alpha"])
        let shelves = BackupShelves(listing: [g1, x1], plans: [], allPlans: [])
        let labels = shelves.otherLabels(repositories: [], localHost: "mac")
        #expect(labels[.plan(deleted)]?.title == "Alpha, Zeta")
        #expect(labels[.lineage(x1.lineageKey)]?.title == "Alpha, Zeta")
        #expect(labels[.plan(deleted)]?.qualifier == "/Data/Alpha, /Data/Zeta")
        #expect(labels[.lineage(x1.lineageKey)]?.caption?.text == "1 backup · /Data/Alpha, /Data/Zeta · outside SwiftRestic")
        #expect(labels[.lineage(x1.lineageKey)]?.detail == "/Data/Alpha, /Data/Zeta — from mac\n"
            + "These backups carry no plan ID, so they can't be adopted. "
            + "restic's `tag` command (Repository ▸ restic Console…) can give them one, "
            + "but it rewrites every snapshot's ID.")
    }

    @Test("backups no plan tag marks keep grouping by folders and Mac")
    func untaggedPassThrough() throws {
        let newest = try snapshot("x2", time: "2026-09-30T02:00:00Z", paths: ["/Data/Music"], host: "old-mac")
        let older = try snapshot("x1", time: "2026-09-29T02:00:00Z", paths: ["/Data/Music"], host: "old-mac")
        let other = try snapshot("y1", time: "2026-09-28T02:00:00Z", paths: ["/Data/Sites"], host: "old-mac")
        let shelves = BackupShelves(listing: [older, other, newest], plans: [], allPlans: [])
        #expect(shelves.others.map(\.id) == [.lineage(newest.lineageKey), .lineage(other.lineageKey)])
        #expect(shelves.others.map { $0.snapshots.map(\.id) } == [["x2", "x1"], ["y1"]])
    }

    @Test("picking a backup from anywhere opens the fold it sits in")
    func revealOpensTheOwner() throws {
        let nas = UUID()
        let documents = plan("Documents", in: nas)
        let mine = try snapshot("d1", time: "2026-09-30T02:00:00Z", tags: [ResticService.planTag(documents.id)])
        let foreign = try snapshot("x1", time: "2026-09-29T02:00:00Z", host: "old-mac")
        let deleted = UUID()
        let tagged = try snapshot("g1", time: "2026-09-28T02:00:00Z", tags: [ResticService.planTag(deleted)])

        var folds = SidebarFolds()
        folds.reveal(mine, in: nas, plans: [documents])
        #expect(folds == SidebarFolds(plans: [documents.id], otherBackups: [], otherGroups: []))
        folds.reveal(foreign, in: nas, plans: [documents])
        #expect(folds == SidebarFolds(plans: [documents.id], otherBackups: [nas], otherGroups: []))
        // A tagged orphan's group is a fold of its own, closed at launch —
        // selecting one of its records must open it, or the record lands in
        // a group the sidebar never shows.
        folds.reveal(tagged, in: nas, plans: [documents])
        #expect(folds == SidebarFolds(
            plans: [documents.id],
            otherBackups: [nas],
            otherGroups: [OtherGroupFoldID(repositoryID: nas, planID: deleted)]
        ))
    }

    @Test("a backup is named for where it sits: its plan, or its group among the Other backups")
    func labelsFollowTheShelf() throws {
        let nas = UUID()
        let hourly = plan("Hourly Docs", in: nas)
        let nightly = plan("Nightly Docs", in: nas)
        let offsite = repository("Offsite")
        let music = plan("Music", in: offsite.id)
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
        let shelves = BackupShelves(listing: [h1, n1, h0, m1, x1], plans: [hourly, nightly], allPlans: allPlans)

        #expect(shelves.label(of: n1, repositories: [offsite], localHost: "mac") == SnapshotLineage.Label(
            title: "Nightly Docs",
            qualifier: nil,
            caption: nil,
            detail: "/Data/Docs — from mac"
        ))
        // A plan whose backups span two sets of folders: the folders say
        // which one an open backup holds.
        #expect(shelves.label(of: h1, repositories: [offsite], localHost: "mac")?.title == "Hourly Docs")
        #expect(shelves.label(of: h1, repositories: [offsite], localHost: "mac")?.qualifier == "/Data/Docs")
        #expect(shelves.label(of: h0, repositories: [offsite], localHost: "mac")?.qualifier == "/Data/Docs, /Data/Notes")

        // Under Other backups, among the groups shown there together: the
        // console's lineage came from another Mac, so it says which, while
        // this Mac's goes unnamed; the moved plan's group and the console's
        // lineage share the title "Music", so the folders qualify both. The
        // caption's kind word is what tells them apart.
        let others = shelves.otherLabels(repositories: [offsite], localHost: "mac")
        #expect(others[.plan(music.id)] == SnapshotLineage.Label(
            title: "Music",
            qualifier: "/Data/Music",
            caption: .init(count: "1 backup", qualifiers: ["/Data/Music"], kind: ["now backs up to “Offsite”"]),
            detail: "/Data/Music — from mac\nThe “Music” plan backs up to “Offsite” now; these are its earlier backups."
        ))
        #expect(others[.lineage(x1.lineageKey)] == SnapshotLineage.Label(
            title: "Music",
            qualifier: "old-mac · /Data/Music",
            caption: .init(count: "1 backup", qualifiers: ["old-mac", "/Data/Music"], kind: ["outside SwiftRestic"]),
            detail: "/Data/Music — from old-mac\nThese backups carry no plan ID, so they can't be adopted. "
                + "restic's `tag` command (Repository ▸ restic Console…) can give them one, "
                + "but it rewrites every snapshot's ID."
        ))
        #expect(shelves.label(of: x1, repositories: [offsite], localHost: "mac") == others[.lineage(x1.lineageKey)])
        // The restore header names an orphan record the way the sidebar names
        // its group, not by the record's own folders alone.
        #expect(SnapshotLineage.displayName(of: m1, label: shelves.label(of: m1, repositories: [offsite], localHost: "mac"))
            == "Music · /Data/Music")
    }

    @Test("a group under Other backups that one plan wrote names the plan, which now backs up elsewhere")
    func formerPlan() throws {
        // Documents moved to B2; the repository on screen keeps what it
        // backed up before, and has no plan of its own.
        let documents = plan("Documents", in: UUID())
        let m1 = try snapshot("m1", time: "2026-09-28T02:00:00Z", tags: [ResticService.planTag(documents.id)])
        let x1 = try snapshot("x1", time: "2026-09-27T02:00:00Z", paths: ["/Data/Music"], host: "old-mac")
        let shelves = BackupShelves(listing: [m1, x1], plans: [], allPlans: [documents])
        // The classification is configuration-wide: the plan belongs to
        // another repository, so the group is its former one — never one to
        // adopt. A deleted plan's and a console backup's groups are not.
        #expect(shelves.others.map { shelves.formerPlan(of: $0)?.id } == [documents.id, nil])
        let gone = BackupShelves(listing: [m1], plans: [], allPlans: [])
        #expect(gone.others.map { gone.formerPlan(of: $0)?.id } == [nil])
    }

    @Test("a shared title brings the folders in, and a caption that still matches brings the tag's last four hex digits")
    func collisionFallbackChain() throws {
        // Two untagged groups whose folders share a last component: the
        // folders say which is which.
        let music = try snapshot("x1", time: "2026-09-30T02:00:00Z", paths: ["/Data/Music"])
        let volume = try snapshot("x2", time: "2026-09-29T02:00:00Z", paths: ["/Volumes/Music"])
        let untagged = BackupShelves(listing: [music, volume], plans: [], allPlans: [])
        let untaggedLabels = untagged.otherLabels(repositories: [], localHost: "mac")
        #expect(untaggedLabels[.lineage(music.lineageKey)]?.title == "Music")
        #expect(untaggedLabels[.lineage(music.lineageKey)]?.caption?.text == "1 backup · /Data/Music · outside SwiftRestic")
        #expect(untaggedLabels[.lineage(volume.lineageKey)]?.caption?.text == "1 backup · /Volumes/Music · outside SwiftRestic")

        // Two deleted plans that backed up the same folders from the same
        // host: title, folders and caption all match, so the tag's last four
        // hex digits — the one identifier left — tell them apart, in the
        // header's name as well as the row's caption.
        let first = UUID(uuidString: "00000000-0000-4000-8000-000000000021")!
        let second = UUID(uuidString: "00000000-0000-4000-8000-0000000000ab")!
        let a1 = try snapshot("a1", time: "2026-09-30T02:00:00Z", paths: ["/Data/Music"],
                              tags: [ResticService.planTag(first)])
        let b1 = try snapshot("b1", time: "2026-09-29T02:00:00Z", paths: ["/Data/Music"],
                              tags: [ResticService.planTag(second)])
        let shelves = BackupShelves(listing: [a1, b1], plans: [], allPlans: [])
        let labels = shelves.otherLabels(repositories: [], localHost: "mac")
        #expect(labels[.plan(first)]?.caption?.text == "1 backup · /Data/Music · not set up here · 0021")
        // The hex joins the kind, which the row keeps whole; the folders are
        // what give way.
        #expect(labels[.plan(first)]?.caption == .init(
            count: "1 backup", qualifiers: ["/Data/Music"], kind: ["not set up here", "0021"]
        ))
        #expect(labels[.plan(second)]?.caption?.text == "1 backup · /Data/Music · not set up here · 00ab")
        #expect(labels[.plan(first)]?.qualifier == "/Data/Music · 0021")
        #expect(labels[.plan(second)]?.qualifier == "/Data/Music · 00ab")
        #expect(SnapshotLineage.displayName(of: a1, label: labels[.plan(first)]) == "Music · /Data/Music · 0021")
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
