import Foundation
import Testing

@Suite("Snapshot comparison")
struct SnapshotDiffTests {
    private func snapshot(_ id: String, time: String, paths: [String], host: String = "mac") throws -> Snapshot {
        try snapshotFixture(id: id, time: time, paths: paths, includeShortID: true, hostname: host, tags: [])
    }

    @Test("the default comparison is the previous snapshot of the same folders from the same host")
    func previousComparable() throws {
        let docsOld = try snapshot("a1", time: "2026-09-01T02:00:00Z", paths: ["/Users/me/Documents"])
        let photos = try snapshot("b1", time: "2026-09-02T02:00:00Z", paths: ["/Users/me/Pictures"])
        let docsOtherMac = try snapshot("c1", time: "2026-09-03T02:00:00Z", paths: ["/Users/me/Documents"], host: "laptop")
        let docsMid = try snapshot("a2", time: "2026-09-04T02:00:00Z", paths: ["/Users/me/Documents"])
        let docsNew = try snapshot("a3", time: "2026-09-05T02:00:00Z", paths: ["/Users/me/Documents"])
        let all = [docsNew, docsMid, docsOtherMac, photos, docsOld]

        // Not the row above (another Mac's Documents), not another plan's tree:
        // the most recent earlier snapshot of exactly these folders on this host.
        #expect(docsNew.previousComparable(in: all)?.id == "a2")
        #expect(docsMid.previousComparable(in: all)?.id == "a1")
        // The oldest of its kind has nothing to compare against, even though
        // older snapshots of other things exist.
        #expect(docsOld.previousComparable(in: all) == nil)
        #expect(docsOtherMac.previousComparable(in: all) == nil)
        #expect(photos.previousComparable(in: all) == nil)
    }

    @Test("a change row's copy is in the newer backup, a removed one's in the older")
    func changeHolder() throws {
        let older = try snapshot("a1", time: "2026-09-01T02:00:00Z", paths: ["/src"])
        let newer = try snapshot("a2", time: "2026-09-02T02:00:00Z", paths: ["/src"])
        for modifier in ["+", "M", "T", "U", "MU", "?"] {
            #expect(ResticDiffChange(path: "/src/a.txt", modifier: modifier).holder(newer: newer, older: older) == newer)
        }
        #expect(ResticDiffChange(path: "/src/gone/", modifier: "-").holder(newer: newer, older: older) == older)
    }

    @Test("a change row's glyph: the category's sign, a modified one's strongest fact")
    func changeGlyph() {
        // U+2212 minus for a removal, not a hyphen.
        let expectations: [(modifier: String, glyph: String)] = [
            ("+", "+"), ("-", "\u{2212}"), ("M", "M"), ("T", "T"), ("?", "?"),
            ("MU", "M"), ("TU", "T"), ("U", "U"),
        ]
        for (modifier, glyph) in expectations {
            #expect(ResticDiffChange(path: "/a", modifier: modifier).glyph == glyph, "modifier \(modifier)")
        }
    }
}

@Suite("Diff candidate grouping")
struct DiffCandidateGroupingTests {
    private func snapshot(_ id: String, time: String) throws -> Snapshot {
        try snapshotFixture(id: id, time: time, paths: ["/x"], includeShortID: false, hostname: nil, tags: [])
    }

    @Test("months bucket newest first, one label per month, order preserved")
    func monthBucketing() throws {
        let jan = try snapshot("j1", time: "2026-01-28T02:00:00Z")
        let feb1 = try snapshot("f1", time: "2026-02-01T02:00:00Z")
        let feb2 = try snapshot("f2", time: "2026-02-03T02:00:00Z")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let buckets = DiffCandidateGrouping.months(in: [feb2, feb1, jan], calendar: calendar)

        #expect(buckets.count == 2)
        // Input is newest first, so first sight of a month names the group.
        #expect(buckets[0].items.map(\.id) == ["f2", "f1"])
        #expect(buckets[1].items.map(\.id) == ["j1"])
        #expect(!buckets[0].label.isEmpty && !buckets[1].label.isEmpty)
        #expect(buckets[0].label != buckets[1].label)
    }

    @Test("a folder's backups group by month too, as the Files pane's picker and the Backups tab read them")
    func versionMonths() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let day = { (iso: String) in ISO8601DateFormatter().date(from: iso)! }
        let versions = [
            IndexVersion(id: "m2", time: day("2026-03-02T09:00:00Z")),
            IndexVersion(id: "m1", time: day("2026-03-01T00:30:00Z")),
            IndexVersion(id: "f9", time: day("2026-02-28T23:30:00Z")),
        ]
        let months = DiffCandidateGrouping.months(in: versions, time: \.time, calendar: calendar)
        #expect(months.map { $0.items.map(\.id) } == [["m2", "m1"], ["f9"]])
        #expect(months.map(\.label) == ["March 2026", "February 2026"])
        // One month needs no landmark: the list reads as it always has.
        #expect(DiffCandidateGrouping.landmarks(in: Array(versions.prefix(2)), time: \.time, calendar: calendar) == nil)
        #expect(DiffCandidateGrouping.landmarks(in: versions, time: \.time, calendar: calendar)?.count == 2)
    }

    @Test("a file's versions group by the month of the first backup that held each, as the file pane's list reads them")
    func contentVersionMonths() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let day = { (iso: String) in ISO8601DateFormatter().date(from: iso)! }
        // Newest first, each version's backups newest first: the oldest
        // version, left alone, was still held in March.
        let versions = [
            ContentVersion(snapshots: [IndexVersion(id: "c", time: day("2026-03-20T09:00:00Z"))], since: .changed),
            ContentVersion(snapshots: [
                IndexVersion(id: "b2", time: day("2026-03-10T09:00:00Z")),
                IndexVersion(id: "b1", time: day("2026-03-02T09:00:00Z")),
            ], since: .changed),
            ContentVersion(snapshots: [
                IndexVersion(id: "a3", time: day("2026-03-01T09:00:00Z")),
                IndexVersion(id: "a1", time: day("2026-01-15T09:00:00Z")),
            ], since: nil),
        ]
        let months = try #require(DiffCandidateGrouping.landmarks(in: versions, time: \.snapshots.last!.time, calendar: calendar))
        #expect(months.map(\.label) == ["March 2026", "January 2026"])
        #expect(months.map { $0.items.map(\.id) } == [["c", "b2"], ["a3"]])
        // A file whose versions all began in one month reads as before.
        #expect(DiffCandidateGrouping.landmarks(in: Array(versions.prefix(2)), time: \.snapshots.last!.time, calendar: calendar) == nil)
    }

    @Test("empty input groups to nothing")
    func emptyInput() throws {
        #expect(DiffCandidateGrouping.months(in: []).isEmpty)
    }
}

@Suite("Show Changes Only")
struct BackupChangesTests {
    private func changes(_ entries: [(String, String)]) -> [PathKey: ResticDiffChange] {
        Dictionary(uniqueKeysWithValues: entries.map {
            (PathKey(ResticPath.normalized($0.0)), ResticDiffChange(path: $0.0, modifier: $0.1))
        })
    }

    @Test("lists every change by path, deletions and folders too, each with its normalized path")
    func rows() {
        let list = BackupChanges(changes: changes([
            ("/d/z.txt", "+"), ("/d/a.txt", "-"), ("/d/sub/", "+"), ("/d/m.txt", "M"),
        ]))
        #expect(list.rows.map(\.path) == ["/d/a.txt", "/d/m.txt", "/d/sub", "/d/z.txt"])
        #expect(list.rows.first?.change.category == .removed)
        #expect(list.rows[2].change.isDirectory)
        #expect(list.total == 4)
        #expect(list.summary(dataAdded: nil) == "2 added, 1 deleted, 1 modified")
    }

    @Test("says the data the backup added, and nothing for a run that stored none")
    func summaryWithData() {
        let list = BackupChanges(changes: changes([("/a", "+")]))
        #expect(list.summary(dataAdded: 2_000_000) == "1 added · \(Format.bytes(2_000_000)) of new data")
        #expect(list.summary(dataAdded: 0) == "1 added")
        #expect(BackupChanges(changes: [:]).summary(dataAdded: nil) == "No changes")
    }

    @Test("two names differing only in Unicode normalization are two rows")
    func spellings() {
        let list = BackupChanges(changes: changes([("/d/caf\u{e9}", "+"), ("/d/cafe\u{301}", "+")]))
        #expect(Set(list.rows.map(\.id)).count == 2)
    }

    /// Built off the main actor when the diff lands (`RestorePaneLoad.run`); its
    /// cost is what "why did this backup grow" waits on past the walk itself.
    @Test("a diff past the limit keeps the counts whole, says it stopped, and builds in seconds")
    func large() {
        let count = 200_000
        var entries: [PathKey: ResticDiffChange] = [:]
        entries.reserveCapacity(count)
        for index in 0 ..< count {
            let path = "/data/folder\(index % 500)/file\(index)"
            entries[PathKey(path)] = ResticDiffChange(path: path, modifier: index % 2 == 0 ? "+" : "M")
        }
        let started = ContinuousClock.now
        let list = BackupChanges(changes: entries)
        let elapsed = ContinuousClock.now - started
        print("SHOW-CHANGES build: \(count) changes in \(elapsed)")
        #expect(list.total == count)
        #expect(list.rows.count == BackupChanges.rowLimit)
        #expect(list.summary(dataAdded: nil).hasSuffix("Showing the first \(Format.count(BackupChanges.rowLimit))"))
        #expect(elapsed < .seconds(10))
    }
}
