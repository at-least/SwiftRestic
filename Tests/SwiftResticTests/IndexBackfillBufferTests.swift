import Foundation
import Testing

/// The backfill buffer's failure discipline, driven through an injected
/// flush: a chunk that cannot be recorded must leave the snapshot pending —
/// never flagged as fully read — and a cancelled buffer must flush nothing.
struct IndexBackfillBufferTests {
    /// Lock-guarded flush spy: records every call, optionally failing them.
    private final class FlushRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(count: Int, final: Bool)] = []
        private var failing = false

        func failFromNowOn() {
            lock.lock()
            failing = true
            lock.unlock()
        }

        func record(_ paths: [String], _ final: Bool) throws {
            lock.lock()
            defer { lock.unlock() }
            if failing { throw IndexError.unknownSnapshot("injected") }
            calls.append((paths.count, final))
        }

        var recorded: [(count: Int, final: Bool)] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    @Test("a failing chunk makes finish throw before coverage is ever marked")
    func failingChunkKeepsSnapshotPending() throws {
        let recorder = FlushRecorder()
        let buffer = BackfillBuffer { paths, final in
            try recorder.record(paths, final)
        }

        // Fill one chunk (the buffer's chunk size is 4000), then let the
        // writes start failing BEFORE the remainder is flushed at finish.
        for index in 0..<4000 { buffer.append("/data/f\(index)") }
        recorder.failFromNowOn()

        #expect(throws: (any Error).self) { try buffer.finish() }
        // The final marker must never have gone through.
        #expect(recorder.recorded.allSatisfy { !$0.final })
    }

    @Test("a clean finish flushes the remainder once and marks coverage exactly once")
    func cleanFinishMarksOnce() {
        let recorder = FlushRecorder()
        let buffer = BackfillBuffer { paths, final in
            try recorder.record(paths, final)
        }
        for index in 0..<10 { buffer.append("/data/f\(index)") }
        try? buffer.finish()
        #expect(recorder.recorded.count == 2)
        #expect(recorder.recorded.first?.final == false)
        #expect(recorder.recorded.last?.final == true)
    }

    @Test("a cancelled buffer flushes nothing more")
    func cancelledFlushesNothing() {
        let recorder = FlushRecorder()
        let buffer = BackfillBuffer { paths, final in
            try recorder.record(paths, final)
        }
        buffer.append("/data/a")
        buffer.cancel()
        buffer.append("/data/b")
        try? buffer.finish()
        #expect(recorder.recorded.isEmpty)
    }
}
