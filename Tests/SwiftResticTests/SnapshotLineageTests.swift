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

    @Test("the restore header names the open backup the way the sidebar names its group")
    @MainActor
    func restoreHeaderName() throws {
        // Named apart from its folder, so the plan's name — what the sidebar
        // shows — is told apart from the folder the backup holds.
        var documentsPlan = BackupPlan()
        documentsPlan.name = "Paperwork"
        let docs = try snapshot("d1", time: "2026-09-26T02:00:00Z", paths: ["/Data/Documents"],
                                tags: [ResticService.planTag(documentsPlan.id)])
        let docsLabels = SnapshotLineage.labels(for: SnapshotLineage.grouping([docs]), plans: [documentsPlan])
        let heading = RestoreRecordHeading(record: docs, label: docsLabels[docs.lineageKey], comparison: nil)
        #expect(heading.name == "Paperwork")
        #expect(SnapshotLineage.displayName(of: docs, label: docsLabels[docs.lineageKey]) == "Paperwork")
        // Computed, not a literal: the day reads the same in any locale or zone.
        #expect(heading.time == Format.timestamp(docs.time))

        // The `qualifiers` fixture: a plan whose folders changed. The older
        // lineage wears the qualifier the sidebar gives its group.
        var work = BackupPlan()
        work.name = "Work"
        let tag = ResticService.planTag(work.id)
        let before = try snapshot("w1", time: "2026-09-20T02:00:00Z", paths: ["/Data/Work"], tags: [tag])
        let after = try snapshot("w2", time: "2026-09-26T02:00:00Z", paths: ["/Data/Clients", "/Data/Work"], tags: [tag])
        let workLabels = SnapshotLineage.labels(for: SnapshotLineage.grouping([before, after]), plans: [work])
        #expect(RestoreRecordHeading(record: before, label: workLabels[before.lineageKey], comparison: .firstBackup).name
            == "Work · /Data/Work")
        // The one rule later restore surfaces reuse, not a second lookup.
        #expect(SnapshotLineage.displayName(of: before, label: workLabels[before.lineageKey]) == "Work · /Data/Work")

        // No label: the folders still say which backup.
        #expect(RestoreRecordHeading(record: after, label: nil, comparison: nil).name == "Clients, Work")
        #expect(SnapshotLineage.displayName(of: after, label: nil) == "Clients, Work")

        // The model's lookup reads the same lineages and plans the sidebar does.
        let model = AppModel(
            store: ConfigStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("SwiftResticHeading-\(UUID().uuidString)")),
            secrets: .inMemory()
        )
        let repositoryID = UUID()
        model.configuration.plans = [work]
        model.snapshots[repositoryID] = [after, before]
        #expect(model.lineageLabel(of: before, repositoryID: repositoryID) == workLabels[before.lineageKey])
        #expect(model.lineageLabel(of: docs, repositoryID: repositoryID) == nil)
    }

    @Test("the restore header says what the Change column compares against, and why it is blank")
    func restoreHeaderCaption() throws {
        let baseline = try snapshot("73d9b51de71d34eb", time: "2026-09-24T02:00:00Z", paths: ["/Data/Documents"])
        let record = try snapshot("abf72899aaaaaaaa", time: "2026-09-26T02:00:00Z", paths: ["/Data/Documents"])
        let since = Format.timestamp(baseline.time)
        func heading(_ comparison: ChangeComparison?) -> RestoreRecordHeading {
            RestoreRecordHeading(record: record, label: nil, comparison: comparison)
        }

        #expect(heading(nil).caption == "abf72899")
        #expect(heading(.firstBackup).caption == "abf72899 · No earlier backup of these folders, so no changes are marked")
        #expect(heading(.comparing(baseline: baseline)).caption == "abf72899 · Comparing with \(since)…")
        #expect(heading(.compared(baseline: baseline, changeCount: 1)).caption == "abf72899 · 1 change since \(since)")
        #expect(heading(.compared(baseline: baseline, changeCount: 3)).caption == "abf72899 · 3 changes since \(since)")
        // restic diff lists nothing when nothing changed: an honest zero.
        #expect(heading(.compared(baseline: baseline, changeCount: 0)).caption == "abf72899 · No changes since \(since)")
        // restic's first sentence in the caption; the whole reason in the tooltip.
        let failed = heading(.failed(baseline: baseline, reason: "restic reported a fatal error — Fatal: injected. More."))
        #expect(failed.caption == "abf72899 · Could not compare with \(since): restic reported a fatal error — Fatal: injected")
        #expect(failed.detail.hasSuffix(" restic diff failed: restic reported a fatal error — Fatal: injected. More."))

        // Only a failed comparison wears the warning glyph.
        #expect(failed.isProblem)
        let calm: [ChangeComparison?] = [nil, .firstBackup, .comparing(baseline: baseline),
                                         .compared(baseline: baseline, changeCount: 2)]
        #expect(calm.allSatisfy { !heading($0).isProblem })

        // The tooltip names both full IDs, or says why there is no baseline —
        // in the restore surfaces' word: the open record is a backup.
        #expect(heading(nil).detail == "Backup abf72899aaaaaaaa.")
        #expect(heading(.compared(baseline: baseline, changeCount: 1)).detail
            == "Backup abf72899aaaaaaaa, compared with 73d9b51de71d34eb — the previous backup of these folders "
            + "from the same Mac. Changes to permissions or timestamps alone are not marked.")
        #expect(heading(.firstBackup).detail
            == "Backup abf72899aaaaaaaa. The Change column compares a backup with the previous one of the same "
            + "folders from the same Mac, and this is the first.")
    }
}
