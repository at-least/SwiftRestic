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
