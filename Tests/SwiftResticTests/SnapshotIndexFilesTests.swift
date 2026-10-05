import Foundation
import Testing

/// The reads behind the Files view, through the public API on a file-backed
/// store: a folder's children across a chain's whole indexed history.
@Suite("snapshot index files view")
struct SnapshotIndexFilesTests {
    private let planA = IndexTestData.planA
    private let planB = IndexTestData.planB

    private func snap(_ id: String, _ seconds: Int64, plan: String? = nil) throws -> Snapshot {
        try IndexTestData.snapshot(id, micros: seconds * 1_000_000, tags: [plan ?? planA])
    }

    private func summary(_ children: [IndexChild]) -> [String] {
        children.map { "\($0.path) \($0.isDirectory ? "dir" : "file") \($0.newest.id) \($0.isInNewest ? "now" : "gone")" }
    }

    @Test("children lists everything a chain ever held under a folder, by name, marking what its newest backup no longer has")
    func childrenAcrossHistory() async throws {
        let checked = try CheckedIndex()
        let index = checked.index
        let listing = [try snap("s1", 10), try snap("s2", 20), try snap("b1", 30, plan: planB)]
        let contents: [String: IndexContent] = [
            "s1": ["/data": true, "/data/a.txt": false, "/data/sub": true, "/data/sub/x": false, "/data/k": false],
            "s2": ["/data": true, "/data/a.txt": false, "/data/b.txt": false, "/data/k": true],
            "b1": ["/data": true, "/data/c.txt": false],
        ]
        try checked.reconcile(listing)
        try checked.runToDone(contents)

        #expect(summary(try await index.children(ofPath: "/data", inChain: planA)) == [
            "/data/a.txt file s2 now",
            "/data/b.txt file s2 now",
            // A kind change: the newest snapshot holding it decides.
            "/data/k dir s2 now",
            "/data/sub dir s1 gone",
        ])
        #expect(summary(try await index.children(ofPath: "/data/sub", inChain: planA)) == ["/data/sub/x file s1 gone"])
        #expect(summary(try await index.children(ofPath: "/", inChain: planA)) == ["/data dir s2 now"])
        // Chains do not mix.
        #expect(summary(try await index.children(ofPath: "/data", inChain: planB)) == ["/data/c.txt file b1 now"])
        // Unknown folders and chains, and misspellings, hold nothing.
        #expect(try await index.children(ofPath: "/nope", inChain: planA).isEmpty)
        #expect(try await index.children(ofPath: "/data/", inChain: planA).isEmpty)
        #expect(try await index.children(ofPath: "/data", inChain: "swiftrestic-plan-unknown").isEmpty)
        // A file has no children.
        #expect(try await index.children(ofPath: "/data/a.txt", inChain: planA).isEmpty)
    }

    @Test("a forgotten backup's items leave children at once, before housekeeping, and newest falls back")
    func childrenAfterADeath() async throws {
        let checked = try CheckedIndex()
        let index = checked.index
        let contents: [String: IndexContent] = [
            "s1": ["/data": true, "/data/a.txt": false],
            "s2": ["/data": true, "/data/a.txt": false, "/data/b.txt": false],
        ]
        try checked.reconcile([try snap("s1", 10), try snap("s2", 20)])
        try checked.runToDone(contents)
        try checked.reconcile([try snap("s1", 10)])

        // Only s1 is listed: b.txt was never in it, and a.txt is in the
        // chain's newest backup again.
        #expect(summary(try await index.children(ofPath: "/data", inChain: planA)) == ["/data/a.txt file s1 now"])
        try checked.housekeeping()
        #expect(summary(try await index.children(ofPath: "/data", inChain: planA)) == ["/data/a.txt file s1 now"])
    }

    // MARK: - Search within a chain

    @Test("a chain's search keeps the chain's own paths, gone ones included, each as the tree lists it")
    func searchWithinAChain() async throws {
        let checked = try CheckedIndex()
        let index = checked.index
        let listing = [try snap("s1", 10), try snap("s2", 20), try snap("b1", 30, plan: planB)]
        let contents: [String: IndexContent] = [
            "s1": ["/data": true, "/data/report.txt": false, "/data/old-report.txt": false, "/data/reports": false],
            "s2": ["/data": true, "/data/report.txt": false, "/data/reports": true],
            "b1": ["/data": true, "/data/report-b.txt": false],
        ]
        try checked.reconcile(listing)
        try checked.runToDone(contents)

        #expect(summary(try await index.search(matching: "report", inChain: planA, limit: 10)) == [
            "/data/old-report.txt file s1 gone",
            "/data/report.txt file s2 now",
            // A kind change: the chain's newest snapshot holding it decides.
            "/data/reports dir s2 now",
        ])
        // Chains do not mix: another plan's match is no hit here.
        #expect(summary(try await index.search(matching: "report", inChain: planB, limit: 10)) == [
            "/data/report-b.txt file b1 now",
        ])
        #expect(try await index.search(matching: "report", inChain: "swiftrestic-plan-unknown", limit: 10).isEmpty)
        #expect(try await index.search(matching: "  ", inChain: planA, limit: 10).isEmpty)
    }

    @Test("a chain's search fills its limit with the chain's own hits, and equal names are cut by path")
    func searchLimitWithinAChain() async throws {
        let checked = try CheckedIndex()
        let index = checked.index
        // The other plan's names sort first and outnumber the limit: a cap
        // on the repository's hits would leave this chain none.
        let other: IndexContent = ["/data": true, "/data/note1": false, "/data/note2": false, "/data/note3": false]
        let mine: IndexContent = [
            "/data": true, "/data/x": true, "/data/y": true, "/data/x/note9": false, "/data/y/note9": false,
        ]
        try checked.reconcile([try snap("s1", 10), try snap("b1", 20, plan: planB)])
        try checked.runToDone(["s1": mine, "b1": other])

        #expect(summary(try await index.search(matching: "note", inChain: planA, limit: 1)) == ["/data/x/note9 file s1 now"])
        #expect(summary(try await index.search(matching: "note", inChain: planA, limit: 2)) == [
            "/data/x/note9 file s1 now", "/data/y/note9 file s1 now",
        ])
        #expect(summary(try await index.search(matching: "note", inChain: planB, limit: 2)) == [
            "/data/note1 file b1 now", "/data/note2 file b1 now",
        ])
    }

    @Test("a path only a forgotten backup held is no hit, before housekeeping too")
    func searchAfterADeath() async throws {
        let checked = try CheckedIndex()
        let index = checked.index
        let contents: [String: IndexContent] = [
            "s1": ["/data": true, "/data/gone.txt": false],
            "s2": ["/data": true],
        ]
        try checked.reconcile([try snap("s1", 10), try snap("s2", 20)])
        try checked.runToDone(contents)
        #expect(summary(try await index.search(matching: "gone", inChain: planA, limit: 10)) == ["/data/gone.txt file s1 gone"])

        try checked.reconcile([try snap("s2", 20)])
        #expect(try await index.search(matching: "gone", inChain: planA, limit: 10).isEmpty)
        try checked.housekeeping()
        #expect(try await index.search(matching: "gone", inChain: planA, limit: 10).isEmpty)
    }

    // MARK: - Content versions

    /// Each version as its snapshot IDs, newest first, after how it follows
    /// the next older one: "changed", "uncertain", or "first".
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

        // The whole chain goes: no mark stays.
        try checked.reconcile([])
        try checked.housekeeping()
        #expect(try count(index, "edit") == 0)
        #expect(try count(index, "blind") == 0)
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

    @Test("isInNewest follows backup time, not arrival: a back-dated backup is not the newest")
    func childrenNewestByTime() async throws {
        let checked = try CheckedIndex()
        let index = checked.index
        try checked.reconcile([try snap("s2", 20)])
        try checked.runToDone(["s2": ["/data": true, "/data/a.txt": false]])
        // An older backup arrives later: it holds a file the newest lacks.
        let contents: [String: IndexContent] = [
            "s2": ["/data": true, "/data/a.txt": false],
            "s1": ["/data": true, "/data/old.txt": false],
        ]
        try checked.reconcile([try snap("s1", 10), try snap("s2", 20)])
        try checked.runToDone(contents)

        #expect(summary(try await index.children(ofPath: "/data", inChain: planA)) == [
            "/data/a.txt file s2 now",
            "/data/old.txt file s1 gone",
        ])
    }
}
