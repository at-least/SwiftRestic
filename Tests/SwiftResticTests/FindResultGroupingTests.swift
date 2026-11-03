import Foundation
import Testing

@Suite("Find results by path")
struct FindResultGroupingTests {
    private func result(_ snapshot: String, _ paths: [String]) throws -> FindResult {
        let matches = paths.map { #"{"path":"\#($0)","type":"file","size":3}"# }.joined(separator: ",")
        return try JSONDecoder().decode(
            FindResult.self,
            from: Data(#"{"matches":[\#(matches)],"hits":\#(paths.count),"snapshot":"\#(snapshot)"}"#.utf8)
        )
    }

    @Test("a path found in several backups is one row, at the newest, with how many hold it")
    func onePerPath() throws {
        let day = { (d: Double) in Date(timeIntervalSince1970: 1_790_000_000 + d * 86_400) }
        let times = ["s1": day(1), "s2": day(2), "s3": day(3)]
        let rows = FindResultGrouping.rows(
            [
                try result("s1", ["/d/notes.txt", "/d/old/notes.txt"]),
                try result("s3", ["/d/notes.txt"]),
                try result("s2", ["/d/notes.txt", "/d/cafe\u{301}/notes.txt"]),
            ],
            times: times,
            chain: { _ in "Documents" }
        )
        #expect(rows.map(\.match.path) == ["/d/notes.txt", "/d/cafe\u{301}/notes.txt", "/d/old/notes.txt"])
        #expect(rows.map(\.snapshotID) == ["s3", "s2", "s1"])
        #expect(rows.map(\.count) == [3, 1, 1])
        let spellings = FindResultGrouping.rows(
            [try result("s1", ["/d/caf\u{E9}", "/d/cafe\u{301}"])], times: times, chain: { _ in "Documents" }
        )
        #expect(spellings.count == 2)
        let unknown = FindResultGrouping.rows(
            [try result("gone", ["/d/x"]), try result("s1", ["/d/y"])], times: times, chain: { _ in "Documents" }
        )
        #expect(unknown.map(\.snapshotID) == ["s1", "gone"])
    }

    @Test("a row counts the backups of its newest backup's chain — what the Files tab it opens lists — not another plan's")
    func countsTheChainItOpens() throws {
        let day = { (d: Double) in Date(timeIntervalSince1970: 1_790_000_000 + d * 86_400) }
        let times = ["h1": day(1), "h2": day(2), "d1": day(3), "d2": day(4), "d3": day(5)]
        let chains = ["h1": "Home", "h2": "Home", "d1": "Documents", "d2": "Documents", "d3": "Documents"]
        let rows = FindResultGrouping.rows(
            try ["d3", "d2", "d1", "h2", "h1"].map { try result($0, ["/Users/me/Documents/notes.txt"]) },
            times: times,
            chain: { chains[$0] }
        )
        #expect(rows.map(\.snapshotID) == ["d3"])
        #expect(rows.map(\.count) == [3], "the Documents plan's three, not all five")
    }

    @Test("times all unknown, the row stays at the first holder — restic answers newest first")
    func unknownTimesKeepTheFirstHolder() throws {
        let rows = FindResultGrouping.rows(
            [try result("s9", ["/d/notes.txt"]), try result("s4", ["/d/notes.txt"])],
            times: [:],
            chain: { _ in "Documents" }
        )
        #expect(rows.map(\.snapshotID) == ["s9"])
        #expect(rows.map(\.count) == [2])
    }

    @Test("the index engine's rows are newest first by their newest version, ties keeping the search's order")
    func indexRowsOrder() {
        let old = IndexVersion(id: "old", time: Date(timeIntervalSince1970: 1_000))
        let new = IndexVersion(id: "new", time: Date(timeIntervalSince1970: 2_000))
        let hits = [SearchHit(path: "/d/a.txt", isDirectory: false), SearchHit(path: "/d/b.txt", isDirectory: false)]
        let built = FindResultGrouping.indexRows(
            hits: hits,
            summaries: [
                PathKey("/d/a.txt"): VersionSummary(count: 2, newest: old),
                PathKey("/d/b.txt"): VersionSummary(count: 5, newest: new),
            ]
        )
        #expect(built.rows.map(\.snapshotID) == ["new", "old"])
        #expect(built.dropped == 0)

        // Equal times: the search's own order stands — name, then path —
        // so equal times never shuffle between searches.
        let tied = FindResultGrouping.indexRows(
            hits: hits.reversed(),
            summaries: [
                PathKey("/d/a.txt"): VersionSummary(count: 1, newest: new),
                PathKey("/d/b.txt"): VersionSummary(count: 1, newest: new),
            ]
        )
        #expect(tied.rows.map(\.match.path) == ["/d/b.txt", "/d/a.txt"])
    }

    @Test("the index engine's rows carry the hit and the summary's facts; a hit without its summary is dropped, not a row")
    func indexRowsFacts() {
        let newest = IndexVersion(id: "s9", time: Date(timeIntervalSince1970: 3_000))
        let folder = SearchHit(path: "/d/Sub", isDirectory: true)
        let file = SearchHit(path: "/d/a.txt", isDirectory: false)
        let built = FindResultGrouping.indexRows(
            hits: [folder, file, SearchHit(path: "/d/gone.txt", isDirectory: false)],
            summaries: [
                PathKey("/d/Sub"): VersionSummary(count: 3, newest: newest),
                PathKey("/d/a.txt"): VersionSummary(count: 7, newest: newest),
            ]
        )
        #expect(built.dropped == 1, "a hit without its summary reads as a truncated list, not silence")
        #expect(built.rows.count == 2)
        let byPath = Dictionary(uniqueKeysWithValues: built.rows.map { ($0.match.path, $0) })
        #expect(byPath["/d/Sub"]?.match.type == .dir)
        #expect(byPath["/d/a.txt"]?.match.type == .file)
        #expect(byPath["/d/Sub"]?.count == 3)
        #expect(byPath["/d/a.txt"]?.count == 7)
        #expect(built.rows.allSatisfy { $0.snapshotID == "s9" && $0.snapshotTime == newest.time })
        #expect(byPath["/d/a.txt"]?.hit == file)
        #expect(byPath["/d/Sub"]?.match.size == nil && byPath["/d/Sub"]?.match.mtime == nil)
    }
}
