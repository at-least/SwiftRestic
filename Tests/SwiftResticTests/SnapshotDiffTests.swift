import Foundation
import Testing

@Suite("Snapshot comparison")
struct SnapshotDiffTests {
    private func snapshot(_ id: String, time: String, paths: [String], host: String = "mac") throws -> Snapshot {
        let json = """
        {"id":"\(id)","short_id":"\(id.prefix(8))","time":"\(time)","paths":\(paths.map { "\"\($0)\"" }),"hostname":"\(host)","tags":[]}
        """
        return try ResticMessageDecoder.jsonDecoder.decode(Snapshot.self, from: Data(json.utf8))
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

    @Test("counts by category and remembers the order the IDs were passed in")
    func diffCounts() throws {
        var diff = SnapshotDiff(olderID: "old", newerID: "new")
        for line in [
            #"{"message_type":"change","path":"/a","modifier":"+"}"#,
            #"{"message_type":"change","path":"/b","modifier":"+"}"#,
            #"{"message_type":"change","path":"/c","modifier":"-"}"#,
            #"{"message_type":"change","path":"/d","modifier":"MU"}"#,
        ] {
            if case let .change(change)? = ResticMessageDecoder.decode(line: line) {
                diff.changes.append(change)
            }
        }
        #expect(diff.count(of: .added) == 2)
        #expect(diff.count(of: .removed) == 1)
        #expect(diff.count(of: .modified) == 1)
        #expect(diff.count(of: .metadataOnly) == 0)
        #expect(diff.olderID == "old" && diff.newerID == "new")
    }

    @Test("path search matches case-insensitively on prepared lowercase forms")
    func diffChangeSearch() {
        let changes = [
            ResticDiffChange(path: "/Users/me/Reports/Q3.PDF", modifier: "+"),
            ResticDiffChange(path: "/Users/me/old.txt", modifier: "-"),
            ResticDiffChange(path: "/Users/me/notes.md", modifier: "M"),
        ]
        let search = DiffChangeSearch(changes: changes)

        // A mixed-case needle finds a mixed-case path.
        #expect(search.matches(category: nil, needle: "q3.pdf").map(\.path)
            == ["/Users/me/Reports/Q3.PDF"])
        // The category gate composes with the needle.
        #expect(search.matches(category: .removed, needle: "USERS").map(\.path)
            == ["/Users/me/old.txt"])
        #expect(search.matches(category: .removed, needle: "q3.pdf").isEmpty)
        // An empty or whitespace-only needle admits everything the category allows.
        #expect(search.matches(category: nil, needle: "   ").count == 3)
        #expect(search.matches(category: nil, needle: "").count == 3)
        // A miss is empty, never a crash.
        #expect(search.matches(category: nil, needle: "zzz").isEmpty)
        // The needle is matched as a substring anywhere in the path.
        #expect(search.matches(category: nil, needle: "reports/q3").count == 1)
    }
}

@Suite("Diff candidate grouping")
struct DiffCandidateGroupingTests {
    private func snapshot(_ id: String, time: String) throws -> Snapshot {
        let json = #"{"id":"\#(id)","time":"\#(time)","paths":["/x"],"tags":[]}"#
        return try ResticMessageDecoder.jsonDecoder.decode(Snapshot.self, from: Data(json.utf8))
    }

    @Test("months bucket newest first, one label per month, order preserved")
    func monthBucketing() throws {
        let jan = try snapshot("j1", time: "2026-01-28T02:00:00Z")
        let feb1 = try snapshot("f1", time: "2026-02-01T02:00:00Z")
        let feb2 = try snapshot("f2", time: "2026-02-03T02:00:00Z")

        let buckets = DiffCandidateGrouping.months(in: [feb2, feb1, jan])

        #expect(buckets.count == 2)
        // Input is newest first, so first sight of a month names the group.
        #expect(buckets[0].items.map(\.id) == ["f2", "f1"])
        #expect(buckets[1].items.map(\.id) == ["j1"])
        // Distinct months carry distinct, non-empty labels.
        #expect(!buckets[0].label.isEmpty && !buckets[1].label.isEmpty)
        #expect(buckets[0].label != buckets[1].label)
    }

    @Test("a folder's backups group by month too, as the Files pane's picker and the sidebar's fold read them")
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
        #expect(DiffCandidateGrouping.sharedDisplayedMinutes(in: []).isEmpty)
    }

    @Test("the shared-minute set names exactly the minutes two candidates display alike")
    func sharedMinutes() throws {
        let a = try snapshot("a", time: "2026-02-03T10:00:30Z")
        let b = try snapshot("b", time: "2026-02-03T10:00:55Z")
        let c = try snapshot("c", time: "2026-02-03T11:00:00Z")

        let shared = DiffCandidateGrouping.sharedDisplayedMinutes(in: [a, b, c])
        #expect(shared == [DiffCandidateGrouping.displayedMinute(a.time)])
        // A lone candidate shares nothing; neither does a blank list.
        #expect(DiffCandidateGrouping.sharedDisplayedMinutes(in: [a]).isEmpty)
    }
}
