import Foundation
import Testing

/// The backfill buffer's failure discipline, driven through an injected
/// flush: a chunk that cannot be recorded must leave the snapshot pending —
/// never flagged as fully read — and stop every flush after it, and a
/// cancelled buffer must flush nothing.
struct IndexBackfillBufferTests {
    /// Lock-guarded flush spy: records every call, optionally failing them.
    /// `recorded` holds the calls that landed; `attempted` holds every call,
    /// failed ones included — the only way to see a flush the buffer should
    /// never have made once a failure is injected.
    private final class FlushRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(count: Int, final: Bool)] = []
        private var attempts: [(count: Int, final: Bool)] = []
        private var failing = false

        func failFromNowOn() {
            lock.lock()
            failing = true
            lock.unlock()
        }

        func record(_ entries: [IndexedEntry], _ final: Bool) throws {
            lock.lock()
            defer { lock.unlock() }
            attempts.append((entries.count, final))
            if failing { throw IndexError.unknownSnapshot("injected") }
            calls.append((entries.count, final))
        }

        var recorded: [(count: Int, final: Bool)] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        var attempted: [(count: Int, final: Bool)] {
            lock.lock()
            defer { lock.unlock() }
            return attempts
        }
    }

    @Test("a failing mid-stream chunk stops the flushing, and finish throws without marking coverage")
    func failingChunkKeepsSnapshotPending() throws {
        let recorder = FlushRecorder()
        let buffer = BackfillBuffer { paths, final in
            try recorder.record(paths, final)
        }

        // The buffer's chunk size is 4000, and a full chunk flushes inside
        // `append`. The first chunk lands; the second fails mid-stream —
        // not at finish — and a third full chunk plus a short remainder
        // follow it, so both later flush paths get their chance to run.
        for index in 0..<4000 { buffer.append(IndexedEntry(path: "/data/f\(index)", isDirectory: false)) }
        recorder.failFromNowOn()
        for index in 4000..<12_010 { buffer.append(IndexedEntry(path: "/data/f\(index)", isDirectory: false)) }

        #expect(throws: (any Error).self) { try buffer.finish() }
        // Exactly two flushes were ever tried: the chunk that landed and the
        // one that failed. No later chunk, no remainder, no final marker.
        #expect(recorder.attempted.map(\.count) == [4000, 4000])
        #expect(recorder.attempted.allSatisfy { !$0.final })
        #expect(recorder.recorded.map(\.count) == [4000])
    }

    @Test("a clean finish flushes the remainder once and marks coverage exactly once")
    func cleanFinishMarksOnce() {
        let recorder = FlushRecorder()
        let buffer = BackfillBuffer { paths, final in
            try recorder.record(paths, final)
        }
        for index in 0..<10 { buffer.append(IndexedEntry(path: "/data/f\(index)", isDirectory: false)) }
        try? buffer.finish()
        #expect(recorder.recorded.count == 2)
        #expect(recorder.recorded.first?.final == false)
        #expect(recorder.recorded.last?.final == true)
    }

    @Test("a stream that delivered nothing is refused without the final: applied, it would read as an empty snapshot")
    func emptyStreamNeverFinalises() {
        let recorder = FlushRecorder()
        let buffer = BackfillBuffer { paths, final in
            try recorder.record(paths, final)
        }
        #expect(throws: IncompleteStream.emptyListing) { try buffer.finish() }
        #expect(recorder.attempted.isEmpty)
    }

    @Test("a cancelled buffer flushes nothing more")
    func cancelledFlushesNothing() {
        let recorder = FlushRecorder()
        let buffer = BackfillBuffer { paths, final in
            try recorder.record(paths, final)
        }
        buffer.append(IndexedEntry(path: "/data/a", isDirectory: false))
        buffer.cancel()
        buffer.append(IndexedEntry(path: "/data/b", isDirectory: false))
        try? buffer.finish()
        #expect(recorder.recorded.isEmpty)
    }
}

/// The delta route's reading of a `restic diff`: existence changes only, and
/// any `T` line or undecodable line means the diff cannot build the target.
struct DeltaCollectorTests {
    @Test("added and removed are kept in restic's spelling; content and metadata changes are not existence")
    func keepsExistenceChanges() throws {
        let collector = DeltaCollector()
        for (path, modifier) in [("/d/new.txt", "+"), ("/d/sub/", "+"), ("/d/gone.txt", "-"), ("/d/edit.txt", "M"), ("/d/meta", "U"), ("/d/both", "MU")] {
            collector.consume(ResticDiffChange(path: path, modifier: modifier))
        }
        let delta = try collector.delta(malformedLines: 0)
        #expect(delta.added == ["/d/new.txt", "/d/sub/"])
        #expect(delta.removed == ["/d/gone.txt"])
    }

    @Test("a T line ends the delta whatever follows it: restic omits both subtrees of a kind change")
    func typeChangeAborts() {
        let collector = DeltaCollector()
        collector.consume(ResticDiffChange(path: "/d/a", modifier: "+"))
        collector.consume(ResticDiffChange(path: "/d/x/", modifier: "T"))
        collector.consume(ResticDiffChange(path: "/d/b", modifier: "-"))
        #expect(throws: IncompleteStream.typeChange(path: "/d/x/")) { try collector.delta(malformedLines: 0) }
    }

    @Test("a line that did not decode ends the delta: the change it carried would be silently missing")
    func malformedAborts() {
        let collector = DeltaCollector()
        collector.consume(ResticDiffChange(path: "/d/a", modifier: "+"))
        #expect(throws: IncompleteStream.malformedLines(2)) { try collector.delta(malformedLines: 2) }
    }
}
