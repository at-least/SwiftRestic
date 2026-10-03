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
