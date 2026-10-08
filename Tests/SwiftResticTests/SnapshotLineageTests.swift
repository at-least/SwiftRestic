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

    @Test("a folder's tally counts every change beneath it, once per folder above, so the root's equals the header's")
    func changesInsideFolders() throws {
        func change(_ path: String, _ modifier: String) -> ResticDiffChange {
            ResticDiffChange(path: path, modifier: modifier)
        }
        let changes: [String: ResticDiffChange] = [
            "/r/a/x.txt": change("/r/a/x.txt", "M"),
            "/r/a/y.txt": change("/r/a/y.txt", "-"),
            "/r/b": change("/r/b/", "+"),
            "/r/b/z.txt": change("/r/b/z.txt", "+"),
        ]
        let inside = ChangeComparison.changesInside(changes)
        #expect(inside["/r/a"] == ChangesInside(added: 0, removed: 1, modified: 1, metadata: 0))
        #expect(inside["/r/b"] == ChangesInside(added: 1, removed: 0, modified: 0, metadata: 0))
        #expect(inside["/r"]?.total == changes.count)
        #expect(inside["/r"]?.summary == "2 added, 1 removed, 1 modified")
        // A file has nothing inside; a path the diff names keeps its own
        // word in the column, so its tally is only for its folders.
        #expect(inside["/r/a/x.txt"] == nil)
        #expect(ChangeComparison.changesInside([:]).isEmpty)
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

    @Test("two plans' interleaved backups of the same folders stay two groups, never one plan's name")
    func sharedLineageTitleIsStable() throws {
        var hourly = BackupPlan()
        hourly.name = "Hourly Docs"
        var nightly = BackupPlan()
        nightly.name = "Nightly Docs"
        let hourlyTag = ResticService.planTag(hourly.id)
        let nightlyTag = ResticService.planTag(nightly.id)

        // Two plans backing up the same folders on one host, interleaved —
        // both since deleted. A group named after its plan would flip its
        // title with whichever ran last and claim the other's backups;
        // the plan tag groups them, and the folders name each. The
        // group order follows the newest member, whichever plan that is.
        let h1 = try snapshot("h1", time: "2026-09-25T01:00:00Z", paths: ["/Data/Docs"], tags: [hourlyTag])
        let n1 = try snapshot("n1", time: "2026-09-25T02:00:00Z", paths: ["/Data/Docs"], tags: [nightlyTag])
        let h2 = try snapshot("h2", time: "2026-09-25T03:00:00Z", paths: ["/Data/Docs"], tags: [hourlyTag])
        let afterHourly = BackupShelves(listing: [h1, n1, h2], plans: [], allPlans: [])
        let n2 = try snapshot("n2", time: "2026-09-25T04:00:00Z", paths: ["/Data/Docs"], tags: [nightlyTag])
        let afterNightly = BackupShelves(listing: [h1, n1, h2, n2], plans: [], allPlans: [])
        #expect(afterHourly.others.map(\.id) == [.plan(hourly.id), .plan(nightly.id)])
        #expect(afterNightly.others.map(\.id) == [.plan(nightly.id), .plan(hourly.id)])

        let labels = afterNightly.otherLabels(repositories: [], localHost: "mac")
        #expect(labels[.plan(hourly.id)]?.title == "Docs")
        #expect(labels[.plan(nightly.id)]?.title == "Docs")
        // Same title, same folders, same host: the tags' last four hex
        // digits are what tells the two histories apart.
        let hourlyHex = String(hourly.id.uuidString.lowercased().suffix(4))
        let nightlyHex = String(nightly.id.uuidString.lowercased().suffix(4))
        #expect(labels[.plan(hourly.id)]?.caption?.text == "2 backups · /Data/Docs · not set up here · \(hourlyHex)")
        #expect(labels[.plan(nightly.id)]?.caption?.text == "2 backups · /Data/Docs · not set up here · \(nightlyHex)")
    }

    @Test("the model re-sorts a repository's backups when its listing or its plans are written, not when a view asks")
    @MainActor
    func modelKeepsShelvesInStep() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticLineages-\(UUID().uuidString)")
        let model = AppModel(store: ConfigStore(directory: root), secrets: .inMemory())
        let repositoryID = UUID()
        var plan = BackupPlan()
        plan.repositoryID = repositoryID
        let docs = try snapshot("d1", time: "2026-09-26T02:00:00Z", paths: ["/Data/Docs"],
                                tags: [ResticService.planTag(plan.id)])
        let photos = try snapshot("p1", time: "2026-09-25T03:00:00Z", paths: ["/Data/Photos"])

        #expect(model.backupShelves[repositoryID] == nil)
        model.snapshots[repositoryID] = [docs, photos]
        #expect(model.shelves(for: repositoryID).others.map { $0.snapshots.map(\.id) } == [["d1"], ["p1"]])
        // The plan arrives: its backup moves under it.
        model.configuration.plans = [plan]
        #expect(model.shelves(for: repositoryID).byPlan[plan.id]?.map(\.id) == ["d1"])
        #expect(model.shelves(for: repositoryID).others.map { $0.snapshots.map(\.id) } == [["p1"]])
        // It moves to another repository: what it left here is other again.
        model.configuration.plans[0].repositoryID = UUID()
        #expect(model.shelves(for: repositoryID).byPlan.isEmpty)
        model.snapshots[repositoryID] = [photos]
        #expect(model.shelves(for: repositoryID).others.map { $0.snapshots.map(\.id) } == [["p1"]])
        model.snapshots[repositoryID] = nil
        #expect(model.backupShelves[repositoryID] == nil)
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
            caption: nil,
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

        // The model's lookup reads the same shelves and plans the sidebar
        // does. Work backs up elsewhere: here its two backups are one group
        // under Other backups, with the group's one label — the plan's name,
        // the folders of its newest member — so both records' headers agree
        // with the group row.
        let model = AppModel(
            store: ConfigStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("SwiftResticHeading-\(UUID().uuidString)")),
            secrets: .inMemory(),
            localHostname: "mac"
        )
        let repositoryID = UUID()
        model.configuration.plans = [work]
        model.snapshots[repositoryID] = [after, before]
        #expect(model.recordLabel(of: before, repositoryID: repositoryID) == SnapshotLineage.Label(
            title: "Work",
            qualifier: nil,
            caption: .init(count: "2 backups"),
            detail: "/Data/Clients, /Data/Work — from mac"
        ))
        #expect(model.recordLabel(of: after, repositoryID: repositoryID)
            == model.recordLabel(of: before, repositoryID: repositoryID))
        #expect(model.recordLabel(of: docs, repositoryID: repositoryID) == nil)
        // Work backs up here: its backups sit under it, named for it, with
        // the folders that tell its two sets apart.
        model.configuration.plans[0].repositoryID = repositoryID
        #expect(model.recordLabel(of: before, repositoryID: repositoryID) == workLabels[before.lineageKey])
    }

    @Test("a backup under its plan is named for that plan, even in a lineage another writer shares")
    @MainActor
    func restoreHeaderNamesThePlan() throws {
        let repositoryID = UUID()
        var hourly = BackupPlan()
        hourly.name = "Hourly Docs"
        hourly.repositoryID = repositoryID
        let h1 = try snapshot("h1", time: "2026-09-25T03:00:00Z", paths: ["/Data/Docs"],
                              tags: [ResticService.planTag(hourly.id)])
        // The console backed up the same folders: one lineage, which the
        // lineage rule names after its folders, "Docs".
        let console = try snapshot("c1", time: "2026-09-26T05:00:00Z", paths: ["/Data/Docs"])
        let model = AppModel(
            store: ConfigStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("SwiftResticHeading-\(UUID().uuidString)")),
            secrets: .inMemory(),
            localHostname: "mac"
        )
        model.configuration.plans = [hourly]
        model.snapshots[repositoryID] = [console, h1]

        // The sidebar shows h1 under Hourly Docs, so the header says so.
        #expect(SnapshotLineage.displayName(of: h1, label: model.recordLabel(of: h1, repositoryID: repositoryID))
            == "Hourly Docs")
        // The console's backup sits under Other backups, named for its folders.
        #expect(SnapshotLineage.displayName(of: console, label: model.recordLabel(of: console, repositoryID: repositoryID))
            == "Docs")
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

    @Test("the restore header names what the backup no longer holds — removals the tree, being this backup's, cannot show")
    func restoreHeaderRemovals() throws {
        let baseline = try snapshot("73d9b51de71d34eb", time: "2026-09-24T02:00:00Z", paths: ["/src"])
        let record = try snapshot("abf72899aaaaaaaa", time: "2026-09-26T02:00:00Z", paths: ["/src"])
        let since = Format.timestamp(baseline.time)
        func changeMap(_ lines: [(String, String)]) -> [String: ResticDiffChange] {
            Dictionary(uniqueKeysWithValues: lines.map { (ResticPath.normalized($0.0), ResticDiffChange(path: $0.0, modifier: $0.1)) })
        }
        func heading(_ changes: [String: ResticDiffChange]) -> RestoreRecordHeading {
            RestoreRecordHeading(record: record, label: nil, comparison: .compared(
                baseline: baseline, changeCount: changes.count, removed: ChangeComparison.removals(in: changes)
            ))
        }

        // restic 0.19.1's diff after a file and a folder were deleted: the
        // folder, then everything it held, each its own "-" line.
        let changes = changeMap([
            ("/src/keep/k.txt", "M"), ("/src/old.txt", "-"), ("/src/sub/", "-"),
            ("/src/sub/a.txt", "-"), ("/src/sub/deep/", "-"), ("/src/sub/deep/b.txt", "-"),
        ])
        #expect(ChangeComparison.removals(in: changes).map(\.path) == ["/src/old.txt", "/src/sub/"])
        let removedTwo = heading(changes)
        // The count line is unchanged; the removals get their own.
        #expect(removedTwo.caption == "abf72899 · 6 changes since \(since)")
        #expect(removedTwo.removed?.line == "Removed: old.txt, sub")
        #expect(removedTwo.removed?.detail == "Removed since \(since):\n/src/old.txt\n/src/sub and everything in it")
        // Each name is a route to the copy the backup before holds.
        #expect(removedTwo.removed?.names.items == [
            RemovedItem(path: "/src/old.txt", isDirectory: false), RemovedItem(path: "/src/sub", isDirectory: true),
        ])
        #expect(removedTwo.removed?.names.items.map(\.name) == ["old.txt", "sub"])
        #expect(removedTwo.removed?.baseline == baseline)

        // Past three names, a count; the tooltip lists them all.
        let five = heading(changeMap(["e", "a", "d", "b", "c"].map { ("/src/\($0).txt", "-") }))
        #expect(five.removed?.line == "Removed: a.txt, b.txt, c.txt, and 2 more")
        #expect(five.removed?.names.items.map(\.name) == ["a.txt", "b.txt", "c.txt"])
        #expect(five.removed?.names.more == 2)
        #expect(five.removed?.detail.split(separator: "\n").count == 6)

        // Twenty paths at most in the tooltip.
        let many = heading(changeMap((10 ..< 33).map { ("/src/f\($0).txt", "-") }))
        #expect(many.removed?.detail.split(separator: "\n").last == "and 3 more")
        #expect(many.removed?.detail.split(separator: "\n").count == 22)

        // "/src/data2" is not inside the removed "/src/data": a byte-exact
        // ancestor, as the index compares paths.
        let siblings = changeMap([("/src/data/", "-"), ("/src/data/x", "-"), ("/src/data2", "-")])
        #expect(ChangeComparison.removals(in: siblings).map(\.path) == ["/src/data/", "/src/data2"])

        // Nothing removed, or no finished comparison: no line.
        #expect(heading(changeMap([("/src/keep/k.txt", "M"), ("/src/new.txt", "+")])).removed == nil)
        let unfinished: [ChangeComparison?] = [nil, .firstBackup, .comparing(baseline: baseline),
                                               .failed(baseline: baseline, reason: "Fatal: injected")]
        #expect(unfinished.allSatisfy {
            let heading = RestoreRecordHeading(record: record, label: nil, comparison: $0)
            return heading.removed == nil
        })
    }
}
