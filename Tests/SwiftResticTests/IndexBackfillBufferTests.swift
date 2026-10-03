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

    @Test("a clean finish sends the remainder as the final chunk: one transaction, coverage marked once")
    func cleanFinishMarksOnce() throws {
        let recorder = FlushRecorder()
        let buffer = BackfillBuffer { paths, final in
            try recorder.record(paths, final)
        }
        for index in 0..<10 { buffer.append(IndexedEntry(path: "/data/f\(index)", isDirectory: false)) }
        try buffer.finish()
        #expect(recorder.recorded.map(\.count) == [10])
        #expect(recorder.recorded.map(\.final) == [true])
    }

    @Test("a stream that ends on a chunk boundary still finalises, with an empty final")
    func boundaryFinishSendsEmptyFinal() throws {
        let recorder = FlushRecorder()
        let buffer = BackfillBuffer { paths, final in
            try recorder.record(paths, final)
        }
        for index in 0..<SnapshotIndex.chunkSize {
            buffer.append(IndexedEntry(path: "/data/f\(index)", isDirectory: false))
        }
        try buffer.finish()
        #expect(recorder.recorded.map(\.count) == [SnapshotIndex.chunkSize, 0])
        #expect(recorder.recorded.map(\.final) == [false, true])
    }

    @Test("a final that fails surfaces its own error, once, and leaves nothing recorded")
    func failingFinalThrows() {
        let recorder = FlushRecorder()
        let buffer = BackfillBuffer { paths, final in
            try recorder.record(paths, final)
        }
        for index in 0..<10 { buffer.append(IndexedEntry(path: "/data/f\(index)", isDirectory: false)) }
        recorder.failFromNowOn()
        #expect(throws: IndexError.unknownSnapshot("injected")) { try buffer.finish() }
        #expect(recorder.attempted.map(\.count) == [10])
        #expect(recorder.attempted.map(\.final) == [true])
        #expect(recorder.recorded.isEmpty)
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

/// The delta route's reading of a `restic diff`: existence and content
/// changes, as the entries the store takes (the path without restic's
/// trailing `/`, the kind that `/` marks), and any `T` line means the diff
/// cannot build the target.
struct DeltaCollectorTests {
    @Test("added, removed and modified arrive as entries, the kind read off restic's trailing slash; a metadata-only change is none of them")
    func keepsExistenceAndContentChanges() throws {
        let collector = DeltaCollector()
        for (path, modifier) in [
            ("/d/new.txt", "+"), ("/d/sub/", "+"), ("/d/new\u{0600}/", "+"),
            ("/d/gone.txt", "-"), ("/d/old/", "-"),
            ("/d/edit.txt", "M"), ("/d/meta", "U"), ("/d/both", "MU"),
        ] {
            collector.consume(ResticDiffChange(path: path, modifier: modifier))
        }
        let delta = try collector.delta()
        #expect(delta.added == [
            IndexedEntry(path: "/d/new.txt", isDirectory: false),
            IndexedEntry(path: "/d/sub", isDirectory: true),
            IndexedEntry(path: "/d/new\u{0600}", isDirectory: true),
        ])
        #expect(delta.removed == [
            IndexedEntry(path: "/d/gone.txt", isDirectory: false),
            IndexedEntry(path: "/d/old", isDirectory: true),
        ])
        // A content change with or without a metadata one; `U` alone keeps
        // the content.
        #expect(delta.modified == [
            IndexedEntry(path: "/d/edit.txt", isDirectory: false),
            IndexedEntry(path: "/d/both", isDirectory: false),
        ])
        // Byte-exact: the Prepend directory's slash is gone, not kept inside
        // its last Character (`IndexedEntry`'s `==` is String's, which is
        // canonical equivalence).
        #expect(delta.added.map { Array($0.path.utf8) }.last == Array("/d/new\u{0600}".utf8))
    }

    @Test("a T line ends the delta whatever follows it: restic omits both subtrees of a kind change")
    func typeChangeAborts() {
        let collector = DeltaCollector()
        collector.consume(ResticDiffChange(path: "/d/a", modifier: "+"))
        collector.consume(ResticDiffChange(path: "/d/x/", modifier: "T"))
        collector.consume(ResticDiffChange(path: "/d/b", modifier: "-"))
        #expect(throws: IncompleteStream.typeChange(path: "/d/x/")) { try collector.delta() }
    }

    @Test("the tests' diff spelling is the one restic writes and the index reads back")
    func diffSpellingRoundTrips() {
        for (path, isDirectory) in [("/d/sub", true), ("/d/file.txt", false), ("/d/cafe\u{0301}", true)] {
            let spelled = IndexTestData.diffSpelling(path, isDirectory: isDirectory)
            #expect(ResticDiffChange(path: spelled, modifier: "+").isDirectory == isDirectory, "\(spelled)")
            // What `DeltaCollector` hands the store for that line: the kind
            // back, and the path byte-exact — the NFD name as its own bytes,
            // not only as a canonically equal String (`IndexedEntry`'s `==`
            // is String's).
            let entry = IndexedEntry(diffSpelling: spelled)
            #expect(entry.isDirectory == isDirectory, "\(spelled)")
            #expect(Array(entry.path.utf8) == Array(path.utf8), "\(spelled)")
        }
    }
}
