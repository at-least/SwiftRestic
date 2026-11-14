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

@Suite("Month headings")
struct MonthHeadingsTests {
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
        let buckets = MonthHeadings.months(in: [feb2, feb1, jan], time: \.time, calendar: calendar)

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
        let months = MonthHeadings.months(in: versions, time: \.time, calendar: calendar)
        #expect(months.map { $0.items.map(\.id) } == [["m2", "m1"], ["f9"]])
        #expect(months.map(\.label) == ["March 2026", "February 2026"])
        // One month needs no landmark.
        #expect(MonthHeadings.landmarks(in: Array(versions.prefix(2)), time: \.time, calendar: calendar) == nil)
        #expect(MonthHeadings.landmarks(in: versions, time: \.time, calendar: calendar)?.count == 2)
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
        let months = try #require(MonthHeadings.landmarks(in: versions, time: \.snapshots.last!.time, calendar: calendar))
        #expect(months.map(\.label) == ["March 2026", "January 2026"])
        #expect(months.map { $0.items.map(\.id) } == [["c", "b2"], ["a3"]])
        #expect(MonthHeadings.landmarks(in: Array(versions.prefix(2)), time: \.snapshots.last!.time, calendar: calendar) == nil)
    }

    @Test("empty input groups to nothing")
    func emptyInput() throws {
        #expect(MonthHeadings.months(in: [Snapshot](), time: \.time).isEmpty)
    }
}
