import Foundation
import Testing

@Suite("Backups tab load")
@MainActor
struct RestorePaneLoadTests {
    private enum Event: Equatable {
        case shown(RestorePaneLoad.Marks)
        case treeListed
    }

    /// Records what the load did, in order.
    @MainActor
    private final class Recorder {
        var events: [Event] = []
        var compareCalls = 0
    }

    private func snapshot(_ id: String, time: String) throws -> Snapshot {
        try snapshotFixture(id: id, time: time, paths: ["/src"], includeShortID: true, hostname: "mac", tags: [])
    }

    /// A comparison the test finishes when it chooses: what a slow
    /// `restic diff` is to the load.
    private func heldCompare(
        _ recorder: Recorder
    ) -> (compare: @MainActor (Snapshot) async -> ChangeMarks, finish: (ChangeMarks) -> Void) {
        let (stream, continuation) = AsyncStream<ChangeMarks>.makeStream()
        let compare: @MainActor (Snapshot) async -> ChangeMarks = { _ in
            recorder.compareCalls += 1
            for await marks in stream { return marks }
            return ChangeMarks(changes: [:], failure: "cancelled")
        }
        return (compare, { continuation.yield($0); continuation.finish() })
    }

    private func start(
        baseline: Snapshot?,
        compare: @escaping @MainActor (Snapshot) async -> ChangeMarks,
        recorder: Recorder
    ) -> Task<Void, Never> {
        Task { @MainActor in
            await RestorePaneLoad.run(
                baseline: baseline,
                compare: compare,
                listTree: { recorder.events.append(.treeListed) },
                show: { recorder.events.append(.shown($0)) }
            )
        }
    }

    /// Lets the load run until the tree is listed, or gives up: a load that
    /// waits for the comparison first never gets there while it is held.
    private func untilTreeListed(_ recorder: Recorder) async {
        for _ in 0..<1000 where !recorder.events.contains(.treeListed) {
            await Task.yield()
        }
    }

    private func change(_ path: String, _ modifier: String) -> ResticDiffChange {
        ResticDiffChange(path: path, modifier: modifier)
    }

    private func marks(_ lines: [(String, String)], failure: String? = nil) -> ChangeMarks {
        ChangeMarks(
            changes: Dictionary(uniqueKeysWithValues: lines.map { (ResticPath.normalized($0.0), change($0.0, $0.1)) }),
            failure: failure
        )
    }

    @Test("the tree is listed while the comparison is still running, the column blank and comparing")
    func treeBeforeComparison() async throws {
        let baseline = try snapshot("73d9b51de71d34eb", time: "2026-09-24T02:00:00Z")
        let recorder = Recorder()
        let held = heldCompare(recorder)
        let load = start(baseline: baseline, compare: held.compare, recorder: recorder)
        await untilTreeListed(recorder)

        #expect(recorder.events == [
            .shown(RestorePaneLoad.Marks(changes: [:], changesInside: [:], comparison: .comparing(baseline: baseline))),
            .treeListed,
        ])
        held.finish(marks([]))
        await load.value
    }

    @Test("the comparison's marks are shown whole once it ends, removals left out")
    func marksAfterComparison() async throws {
        let baseline = try snapshot("73d9b51de71d34eb", time: "2026-09-24T02:00:00Z")
        let recorder = Recorder()
        let held = heldCompare(recorder)
        let load = start(baseline: baseline, compare: held.compare, recorder: recorder)
        await untilTreeListed(recorder)
        held.finish(marks([("/src/a/k.txt", "M"), ("/src/new.txt", "+"), ("/src/old.txt", "-")]))
        await load.value

        let last = try #require(recorder.events.last)
        guard case let .shown(shown) = last else {
            Issue.record("the load ended on \(last), not on the comparison's marks")
            return
        }
        #expect(Set(shown.changes.keys) == ["/src/a/k.txt", "/src/new.txt"])
        #expect(shown.changesInside["/src"]?.total == 2)
        #expect(shown.changesInside["/src/a"]?.total == 1)
        #expect(shown.comparison == .compared(baseline: baseline, changeCount: 2))
        #expect(recorder.events.count == 3)
    }

    @Test("a load cancelled by a record switch shows none of its comparison")
    func cancelledLoadShowsNoMarks() async throws {
        let baseline = try snapshot("73d9b51de71d34eb", time: "2026-09-24T02:00:00Z")
        let recorder = Recorder()
        let held = heldCompare(recorder)
        let load = start(baseline: baseline, compare: held.compare, recorder: recorder)
        await untilTreeListed(recorder)
        load.cancel()
        held.finish(marks([("/src/a/k.txt", "M")]))
        await load.value

        #expect(recorder.events == [
            .shown(RestorePaneLoad.Marks(changes: [:], changesInside: [:], comparison: .comparing(baseline: baseline))),
            .treeListed,
        ])
    }

    @Test("a comparison that fails keeps the tree and says it could not compare, keeping what streamed")
    func failedComparison() async throws {
        let baseline = try snapshot("73d9b51de71d34eb", time: "2026-09-24T02:00:00Z")
        let recorder = Recorder()
        let held = heldCompare(recorder)
        let load = start(baseline: baseline, compare: held.compare, recorder: recorder)
        await untilTreeListed(recorder)
        held.finish(marks([("/src/a/k.txt", "M")], failure: "unable to open repository"))
        await load.value

        #expect(recorder.events.contains(.treeListed))
        let last = try #require(recorder.events.last)
        guard case let .shown(shown) = last else {
            Issue.record("the load ended on \(last), not on the failed comparison")
            return
        }
        #expect(shown.comparison == .failed(baseline: baseline, reason: "unable to open repository"))
        #expect(Set(shown.changes.keys) == ["/src/a/k.txt"])
    }

    @Test("the roots beside the walk open after it, a root on the walk left to the walk, spellings told apart by bytes")
    func rootsBesideWalk() {
        #expect(RestorePaneLoad.rootsBesideWalk(roots: ["/src"], walk: []) == ["/src"])
        #expect(RestorePaneLoad.rootsBesideWalk(roots: ["/a", "/b"], walk: []) == ["/a", "/b"])
        #expect(RestorePaneLoad.rootsBesideWalk(roots: ["/a", "/b"], walk: ["/a", "/a/x"]) == ["/b"])
        #expect(RestorePaneLoad.rootsBesideWalk(roots: ["/a", "/b"], walk: ["/b"]) == ["/a"])
        // NFC and NFD: one String to Swift's ==, two roots to restic. Failed
        // with String comparison (the NFD root was dropped).
        #expect(RestorePaneLoad.rootsBesideWalk(roots: ["/Caf\u{E9}", "/Cafe\u{301}"], walk: ["/Caf\u{E9}"])
            .map { PathKey($0) } == [PathKey("/Cafe\u{301}")])
    }

    @Test("a first backup lists its tree and runs no comparison")
    func firstBackup() async {
        let recorder = Recorder()
        let held = heldCompare(recorder)
        await RestorePaneLoad.run(
            baseline: nil,
            compare: held.compare,
            listTree: { recorder.events.append(.treeListed) },
            show: { recorder.events.append(.shown($0)) }
        )
        #expect(recorder.events == [
            .shown(RestorePaneLoad.Marks(changes: [:], changesInside: [:], comparison: .firstBackup)),
            .treeListed,
        ])
        #expect(recorder.compareCalls == 0)
    }
}
