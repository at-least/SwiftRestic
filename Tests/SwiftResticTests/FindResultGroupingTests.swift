import Foundation
import Testing

/// Find Files' restic engine, read the way the index engine reads: one row
/// per path at the newest backup holding it, counting the backups that do.
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
        // Another spelling of the same name is another path.
        let spellings = FindResultGrouping.rows(
            [try result("s1", ["/d/caf\u{E9}", "/d/cafe\u{301}"])], times: times, chain: { _ in "Documents" }
        )
        #expect(spellings.count == 2)
        // A backup the listing no longer has sorts last, never first.
        let unknown = FindResultGrouping.rows(
            [try result("gone", ["/d/x"]), try result("s1", ["/d/y"])], times: times, chain: { _ in "Documents" }
        )
        #expect(unknown.map(\.snapshotID) == ["s1", "gone"])
    }

    @Test("a row counts the backups of its newest backup's chain — what the Files tab it opens lists — not another plan's")
    func countsTheChainItOpens() throws {
        let day = { (d: Double) in Date(timeIntervalSince1970: 1_790_000_000 + d * 86_400) }
        let times = ["h1": day(1), "h2": day(2), "d1": day(3), "d2": day(4), "d3": day(5)]
        // A Home plan holding ~/Documents beside a Documents plan.
        let chains = ["h1": "Home", "h2": "Home", "d1": "Documents", "d2": "Documents", "d3": "Documents"]
        let rows = FindResultGrouping.rows(
            try ["d3", "d2", "d1", "h2", "h1"].map { try result($0, ["/Users/me/Documents/notes.txt"]) },
            times: times,
            chain: { chains[$0] }
        )
        #expect(rows.map(\.snapshotID) == ["d3"])
        #expect(rows.map(\.count) == [3], "the Documents plan's three, not all five")
    }
}
