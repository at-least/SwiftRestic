import Foundation
import Testing

@Suite("Snapshot lineages")
struct SnapshotLineageTests {
    private func snapshot(
        _ id: String,
        time: String,
        paths: [String],
        host: String = "mac",
        tags: [String] = []
    ) throws -> Snapshot {
        // Arrays through JSONEncoder: interpolating a Swift array writes its
        // debug description, whose escaped quotes end up inside the strings.
        let array = { (strings: [String]) in String(decoding: try JSONEncoder().encode(strings), as: UTF8.self) }
        let json = """
        {"id":"\(id)","short_id":"\(id.prefix(8))","time":"\(time)","paths":\(try array(paths)),\
        "hostname":"\(host)","tags":\(try array(tags))}
        """
        return try ResticMessageDecoder.jsonDecoder.decode(Snapshot.self, from: Data(json.utf8))
    }

    @Test("the Change column compares against the previous backup of the same folders, not the row above")
    func changeBaselineSkipsOtherPlans() throws {
        // Two plans sharing one repository, interleaved in time — the listing
        // the restore pane reads, newest first.
        let docsNew = try snapshot("d3", time: "2026-09-26T02:00:00Z", paths: ["/Users/me/Documents"])
        let photosNew = try snapshot("p2", time: "2026-09-25T03:00:00Z", paths: ["/Users/me/Pictures"])
        let docsMid = try snapshot("d2", time: "2026-09-24T02:00:00Z", paths: ["/Users/me/Documents"])
        let photosOld = try snapshot("p1", time: "2026-09-20T03:00:00Z", paths: ["/Users/me/Pictures"])
        let docsOld = try snapshot("d1", time: "2026-09-20T02:00:00Z", paths: ["/Users/me/Documents"])
        let listing = [docsNew, photosNew, docsMid, photosOld, docsOld]

        #expect(SnapshotLineage.changeBaseline(for: "d3", in: listing)?.id == "d2")
        #expect(SnapshotLineage.changeBaseline(for: "p2", in: listing)?.id == "p1")
        // The first backup of its folders has nothing to compare against,
        // even though an older backup of another plan sits right below it.
        #expect(SnapshotLineage.changeBaseline(for: "p1", in: listing) == nil)
        #expect(SnapshotLineage.changeBaseline(for: "d1", in: listing) == nil)
        #expect(SnapshotLineage.changeBaseline(for: "gone", in: listing) == nil)
    }

    @Test("groups by host and paths, whatever order the paths or the listing arrive in")
    func grouping() throws {
        let docsNew = try snapshot("d2", time: "2026-09-26T02:00:00Z", paths: ["/Users/me/Documents", "/Users/me/Projects"])
        let photos = try snapshot("p1", time: "2026-09-25T03:00:00Z", paths: ["/Users/me/Pictures"])
        // The same two folders listed the other way round are the same lineage.
        let docsOld = try snapshot("d1", time: "2026-09-20T02:00:00Z", paths: ["/Users/me/Projects", "/Users/me/Documents"])
        let laptopDocs = try snapshot("l1", time: "2026-09-24T02:00:00Z", paths: ["/Users/me/Documents", "/Users/me/Projects"], host: "laptop")

        let lineages = SnapshotLineage.grouping([docsOld, laptopDocs, photos, docsNew])

        // The lineage holding the newest backup first; each one's own
        // snapshots newest first.
        #expect(lineages.map { $0.snapshots.map(\.id) } == [["d2", "d1"], ["p1"], ["l1"]])
        #expect(lineages[0].key == SnapshotLineage.Key(hostname: "mac", paths: ["/Users/me/Documents", "/Users/me/Projects"]))
        #expect(lineages[2].key.hostname == "laptop")
        #expect(SnapshotLineage.grouping([]).isEmpty)
    }

    @Test("names a lineage after its plan, or its folders when no plan claims it")
    func labels() throws {
        var documentsPlan = BackupPlan()
        documentsPlan.name = "Documents"
        let tag = ResticService.planTag(documentsPlan.id)
        let deletedPlanTag = ResticService.planTag(UUID())

        let docs = try snapshot("d1", time: "2026-09-26T02:00:00Z", paths: ["/Data/Documents"], tags: [tag])
        let photos = try snapshot("p1", time: "2026-09-25T03:00:00Z", paths: ["/Data/Pictures", "/Volumes/Card/DCIM"])
        let orphan = try snapshot("o1", time: "2026-09-24T03:00:00Z", paths: ["/Data/Music"], tags: [deletedPlanTag])
        let lineages = SnapshotLineage.grouping([docs, photos, orphan])

        let labels = SnapshotLineage.labels(for: lineages, plans: [documentsPlan])

        #expect(labels[docs.lineageKey]?.title == "Documents")
        #expect(labels[photos.lineageKey]?.title == "Pictures, DCIM")
        // A plan that no longer exists names nothing: the folders do.
        #expect(labels[orphan.lineageKey]?.title == "Music")
        // One host and distinct titles: nothing needs qualifying.
        #expect(labels.values.allSatisfy { $0.qualifier == nil })
        #expect(labels[photos.lineageKey]?.detail == "/Data/Pictures, /Volumes/Card/DCIM — from mac")
    }

    @Test("a lineage more than one writer shares is named after its folders, whichever ran last")
    func sharedLineageTitleIsStable() throws {
        var hourly = BackupPlan()
        hourly.name = "Hourly Docs"
        var nightly = BackupPlan()
        nightly.name = "Nightly Docs"
        let hourlyTag = ResticService.planTag(hourly.id)
        let nightlyTag = ResticService.planTag(nightly.id)
        let plans = [hourly, nightly]

        // Two plans backing up the same folders on one host: one lineage.
        let h1 = try snapshot("h1", time: "2026-09-25T01:00:00Z", paths: ["/Data/Docs"], tags: [hourlyTag])
        let n1 = try snapshot("n1", time: "2026-09-25T02:00:00Z", paths: ["/Data/Docs"], tags: [nightlyTag])
        let h2 = try snapshot("h2", time: "2026-09-25T03:00:00Z", paths: ["/Data/Docs"], tags: [hourlyTag])
        let afterHourly = SnapshotLineage.labels(for: SnapshotLineage.grouping([h1, n1, h2]), plans: plans)
        let n2 = try snapshot("n2", time: "2026-09-25T04:00:00Z", paths: ["/Data/Docs"], tags: [nightlyTag])
        let afterNightly = SnapshotLineage.labels(for: SnapshotLineage.grouping([h1, n1, h2, n2]), plans: plans)

        // Naming the group after the newest snapshot's plan flipped the title
        // with every run and claimed the other plan's backups for it.
        #expect(afterHourly[h1.lineageKey]?.title == "Docs")
        #expect(afterNightly[h1.lineageKey]?.title == "Docs")
        #expect(afterNightly[h1.lineageKey]?.detail == "/Data/Docs — from mac\nBacked up by Hourly Docs and Nightly Docs")

        // One plan plus a snapshot taken outside it (the Console, another
        // client): the plan did not write the whole group either.
        let console = try snapshot("c1", time: "2026-09-26T05:00:00Z", paths: ["/Data/Docs"])
        let mixed = SnapshotLineage.labels(for: SnapshotLineage.grouping([h1, h2, console]), plans: plans)
        #expect(mixed[h1.lineageKey]?.title == "Docs")
        #expect(mixed[h1.lineageKey]?.detail == "/Data/Docs — from mac\nBacked up by Hourly Docs and outside SwiftRestic")
    }

    @Test("the model regroups a repository's listing when it is written, not when a view asks")
    @MainActor
    func modelKeepsLineagesInStep() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticLineages-\(UUID().uuidString)")
        let model = AppModel(store: ConfigStore(directory: root), secrets: .inMemory())
        let repositoryID = UUID()
        let docs = try snapshot("d1", time: "2026-09-26T02:00:00Z", paths: ["/Data/Docs"])
        let photos = try snapshot("p1", time: "2026-09-25T03:00:00Z", paths: ["/Data/Photos"])

        #expect(model.lineages(for: repositoryID).isEmpty)
        model.snapshots[repositoryID] = [docs, photos]
        #expect(model.lineages(for: repositoryID).map { $0.snapshots.map(\.id) } == [["d1"], ["p1"]])
        model.snapshots[repositoryID] = [photos]
        #expect(model.lineages(for: repositoryID).map { $0.snapshots.map(\.id) } == [["p1"]])
        model.snapshots[repositoryID] = nil
        #expect(model.lineages(for: repositoryID).isEmpty)
    }

    @Test("a plan whose folders changed, or a second host, is told apart in the qualifier")
    func qualifiers() throws {
        var plan = BackupPlan()
        plan.name = "Work"
        let tag = ResticService.planTag(plan.id)
        // The plan backed up one folder, then two: two lineages, one plan name.
        let before = try snapshot("w1", time: "2026-09-20T02:00:00Z", paths: ["/Data/Work"], tags: [tag])
        let after = try snapshot("w2", time: "2026-09-26T02:00:00Z", paths: ["/Data/Clients", "/Data/Work"], tags: [tag])

        let changed = SnapshotLineage.labels(for: SnapshotLineage.grouping([before, after]), plans: [plan])
        #expect(changed[before.lineageKey] == SnapshotLineage.Label(
            title: "Work",
            qualifier: "/Data/Work",
            detail: "/Data/Work — from mac"
        ))
        #expect(changed[after.lineageKey]?.qualifier == "/Data/Clients, /Data/Work")

        // Same folders from two Macs: the host is what differs, and the
        // shared title brings the folders along too.
        let home = try snapshot("h1", time: "2026-09-26T02:00:00Z", paths: ["/Data/Work"], tags: [tag])
        let laptop = try snapshot("h2", time: "2026-09-25T02:00:00Z", paths: ["/Data/Work"], host: "laptop", tags: [tag])
        let hosts = SnapshotLineage.labels(for: SnapshotLineage.grouping([home, laptop]), plans: [plan])
        #expect(hosts[laptop.lineageKey]?.qualifier == "laptop · /Data/Work")
        #expect(hosts[home.lineageKey]?.qualifier == "mac · /Data/Work")
    }
}
