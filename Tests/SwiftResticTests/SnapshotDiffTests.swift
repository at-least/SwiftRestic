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
        #expect(buckets[0].snapshots.map(\.id) == ["f2", "f1"])
        #expect(buckets[1].snapshots.map(\.id) == ["j1"])
        // Distinct months carry distinct, non-empty labels.
        #expect(!buckets[0].label.isEmpty && !buckets[1].label.isEmpty)
        #expect(buckets[0].label != buckets[1].label)
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
