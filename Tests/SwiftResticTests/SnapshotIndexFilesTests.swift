import Foundation
import Testing

@Suite("snapshot index files view")
struct SnapshotIndexFilesTests {
    private let planA = IndexTestData.planA
    private let planB = IndexTestData.planB

    private func snap(_ id: String, _ seconds: Int64, plan: String? = nil) throws -> Snapshot {
        try IndexTestData.snapshot(id, micros: seconds * 1_000_000, tags: [plan ?? planA])
    }

    private func versions(_ index: SnapshotIndex, _ path: String = "/data/f", chain: String? = nil) async throws -> [String] {
        try await index.contentVersions(ofPath: path, inChain: chain ?? planA).map { version in
            let since = switch version.since {
            case .changed: "changed"
            case .uncertain: "uncertain"
            case nil: "first"
            }
            return since + ":" + version.snapshots.map(\.id).joined(separator: ",")
        }
    }

    private func count(_ index: SnapshotIndex, _ table: String) throws -> Int {
        try index.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    private let file: IndexContent = ["/data": true, "/data/f": false]

    @Test("a history read newest first: backups with the same content are one version, an M splits them")
    func versionsFromReverseDeltas() async throws {
        let checked = try CheckedIndex()
        try checked.reconcile([try snap("s1", 10), try snap("s2", 20), try snap("s3", 30), try snap("s4", 40)])
        let trace = try checked.runToDone(
            ["s1": file, "s2": file, "s3": file, "s4": file],
            revisions: ["s1": ["/data/f": 1], "s2": ["/data/f": 1], "s3": ["/data/f": 2], "s4": ["/data/f": 2]]
        )
        #expect(trace == ["full(s4)", "delta(s3<-s4)", "delta(s2<-s3)", "delta(s1<-s2)"])
        #expect(try await versions(checked.index) == ["changed:s4,s3", "first:s2,s1"])
        // The folder holding it is never modified, so it is one version.
        #expect(try await versions(checked.index, "/data") == ["first:s4,s3,s2,s1"])
    }

    @Test("new backups read forward split the same way, and a changed-back file is still a new version")
    func versionsFromForwardDeltas() async throws {
        let checked = try CheckedIndex()
        let revisions: [String: [String: Int]] = [
            "s1": ["/data/f": 1], "s2": ["/data/f": 2], "s3": ["/data/f": 2], "s4": ["/data/f": 1],
        ]
        var listing: [Snapshot] = []
        for (n, id) in ["s1", "s2", "s3", "s4"].enumerated() {
            listing.append(try snap(id, Int64(n + 1) * 10))
            try checked.reconcile(listing)
            try checked.runToDone(["s1": file, "s2": file, "s3": file, "s4": file], revisions: revisions)
        }
        #expect(try await versions(checked.index) == ["changed:s4", "changed:s3,s2", "first:s1"])
    }

    @Test("a step a full read took is a cut marked uncertain, even when the content did not change")
    func fullReadIsUncertain() async throws {
        let checked = try CheckedIndex()
        let index = checked.index
        try checked.reconcile([try snap("s1", 10), try snap("s2", 20), try snap("s3", 30)])
        try checked.full("s3", IndexTestData.ls(file))
        // The planner offers a delta from s3; a failed diff reads s2 in full.
        #expect(try index.nextStep() == .delta(snapshotID: "s2", from: "s3"))
        try checked.full("s2", IndexTestData.ls(file))
        try checked.runToDone(["s1": file, "s2": file, "s3": file])
        #expect(try await versions(index) == ["uncertain:s3", "first:s2,s1"])
        #expect(try count(index, "blind") == 1)
    }

    @Test("a forgotten backup between two edits keeps the cut, and housekeeping drops the marks a dead bottom strands")
    func deathsAndMarks() async throws {
        let checked = try CheckedIndex()
        let index = checked.index
        let all = [try snap("s1", 10), try snap("s2", 20), try snap("s3", 30), try snap("s4", 40)]
        try checked.reconcile(all)
        try checked.runToDone(
            ["s1": file, "s2": file, "s3": file, "s4": file],
            revisions: ["s1": ["/data/f": 1], "s2": ["/data/f": 2], "s3": ["/data/f": 2], "s4": ["/data/f": 3]]
        )
        #expect(try await versions(index) == ["changed:s4", "changed:s3,s2", "first:s1"])

        // s2 goes: s1 and s3 now sit side by side, and the edit between s1
        // and s2 still says their content differs.
        try checked.reconcile([all[0], all[2], all[3]])
        try checked.housekeeping()
        #expect(try await versions(index) == ["changed:s4", "changed:s3", "first:s1"])
        #expect(try count(index, "edit") == 2)

        // s1 goes too: the mark at its pair with s3 has nothing below it.
        try checked.reconcile([all[2], all[3]])
        try checked.housekeeping()
        #expect(try await versions(index) == ["changed:s4", "first:s3"])
        #expect(try count(index, "edit") == 1)

        try checked.reconcile([])
        try checked.housekeeping()
        #expect(try count(index, "edit") == 0)
        #expect(try count(index, "blind") == 0)
    }

    @Test("two edits across a forgotten backup may be a change undone: the cut is uncertain, as the folder's change list says")
    func twoEditsAcrossADeathAreUncertain() async throws {
        let checked = try CheckedIndex()
        let index = checked.index
        let all = [try snap("s1", 10), try snap("s2", 20), try snap("s3", 30)]
        try checked.reconcile(all)
        try checked.runToDone(
            ["s1": file, "s2": file, "s3": file],
            revisions: ["s1": ["/data/f": 1], "s2": ["/data/f": 2], "s3": ["/data/f": 1]]
        )
        #expect(try await versions(index) == ["changed:s3", "changed:s2", "first:s1"])

        try checked.reconcile([all[0], all[2]])
        try checked.housekeeping()
        #expect(try count(index, "edit") == 2)
        #expect(try await versions(index) == ["uncertain:s3", "first:s1"])
    }

    @Test("a file absent in between is a new version, whatever it held when it came back")
    func absenceIsUncertain() async throws {
        let checked = try CheckedIndex()
        try checked.reconcile([try snap("s1", 10), try snap("s2", 20), try snap("s3", 30)])
        try checked.runToDone(["s1": file, "s2": ["/data": true], "s3": file])
        #expect(try await versions(checked.index) == ["uncertain:s3", "first:s1"])
    }

    @Test("a file<->symlink T spelled as an add keeps the run and records a content change")
    func symlinkTypeChangeIsAnEdit() async throws {
        let checked = try CheckedIndex()
        try checked.reconcile([try snap("s1", 10), try snap("s2", 20)])
        try checked.full("s2", IndexTestData.ls(file))
        try checked.delta("s1", from: "s2", added: ["/data/f"], removed: [])
        #expect(try await versions(checked.index) == ["changed:s2", "first:s1"])
    }

    @Test("a back-dated backup arriving last is cut by its own diff, in time order")
    func backDatedVersions() async throws {
        let checked = try CheckedIndex()
        try checked.reconcile([try snap("s2", 20)])
        try checked.runToDone(["s2": file])
        try checked.reconcile([try snap("s1", 10), try snap("s2", 20)])
        let trace = try checked.runToDone(
            ["s1": file, "s2": file], revisions: ["s1": ["/data/f": 1], "s2": ["/data/f": 2]]
        )
        // Read forward, above s2's seq, though it is older.
        #expect(trace == ["delta(s1<-s2)"])
        #expect(try await versions(checked.index) == ["changed:s2", "first:s1"])
    }

    @Test("unknown paths and chains have no versions; chains do not mix")
    func versionsUnknownAndChains() async throws {
        let checked = try CheckedIndex()
        try checked.reconcile([try snap("s1", 10), try snap("b1", 20, plan: planB)])
        try checked.runToDone(["s1": file, "b1": file])
        #expect(try await versions(checked.index, "/data/nope").isEmpty)
        #expect(try await versions(checked.index, chain: "swiftrestic-plan-unknown").isEmpty)
        #expect(try await versions(checked.index) == ["first:s1"])
        #expect(try await versions(checked.index, chain: planB) == ["first:b1"])
    }
}
