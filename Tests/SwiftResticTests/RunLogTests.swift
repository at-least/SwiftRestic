import Foundation
import Testing

/// The plain-text log a run leaves beside `config.json`, and the store that
/// keeps those files in step with the run history.
@Suite("run log")
struct RunLogTests {
    private let versions = RunLogVersions(
        app: "SwiftRestic 0.1.0 (1)",
        macOS: "macOS 26.6.2 (Build 25G83)",
        restic: "restic 0.19.1 compiled with go1.26.5 on darwin/arm64"
    )

    /// 2026-09-26 07:58:17 UTC, plus seconds.
    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_790_409_497 + seconds)
    }

    @Test("a rendered log leads with versions and the run, lists entries by time, and ends with the verdict")
    func renderedLog() {
        var repository = Repository()
        repository.name = "Home NAS"
        repository.kind = .local
        repository.localPath = "/Volumes/Secret/repo"

        var record = RunRecord(kind: .backup, planName: "Documents", repositoryID: repository.id, startedAt: at(0))
        record.finishedAt = at(2)
        record.outcome = .completedWithErrors
        record.snapshotID = "61b0f11423fd96e36f2fb2ddefdb4d41a4331adf2041828fcef2f679eaf97bfe"
        record.filesNew = 1
        record.filesUnmodified = 2
        record.bytesProcessed = 5000
        record.dataAdded = 5300

        let contents = RunTranscript.Contents(
            entries: [
                .init(time: at(0), kind: .command, text: "restic backup --json /src /src/gone"),
                .init(time: at(1), kind: .output(.stderr), text: "/src/gone does not exist, skipping"),
                .init(time: at(1), kind: .output(.stdout), text: #"{"message_type":"summary","files_new":1}"#),
                .init(time: at(1), kind: .exit(3), text: "3"),
                .init(time: at(2), kind: .note, text: "Retention removed 0 snapshots"),
            ],
            headCount: 5,
            omittedLineCount: 0,
            firstExitCode: 3
        )

        let text = RunLog.render(
            record: record,
            repositoryName: repository.name,
            repositoryKind: repository.kind.displayName,
            versions: versions,
            transcript: contents,
            timeZone: TimeZone(identifier: "UTC")!
        )
        let lines = text.components(separatedBy: "\n")
        #expect(Array(lines.prefix(5)) == [
            "SwiftRestic 0.1.0 (1) · macOS 26.6.2 (Build 25G83)",
            "restic 0.19.1 compiled with go1.26.5 on darwin/arm64",
            "Backup of “Documents” — repository “Home NAS” (Local folder or disk)",
            "Started 2026-09-26 07:58:17 +0000",
            "",
        ], "log began \(lines.prefix(5))")
        #expect(lines.contains("07:58:17 $    restic backup --json /src /src/gone"))
        #expect(lines.contains("07:58:18 err  /src/gone does not exist, skipping"))
        #expect(lines.contains(#"07:58:18 out  {"message_type":"summary","files_new":1}"#))
        #expect(lines.contains("07:58:18 exit 3"))
        #expect(lines.contains("07:58:19 note Retention removed 0 snapshots"))
        #expect(lines.contains("Finished 2026-09-26 07:58:19 +0000 after 2s — Completed with errors"))
        #expect(lines.contains("Snapshot 61b0f11423fd96e36f2fb2ddefdb4d41a4331adf2041828fcef2f679eaf97bfe"))
        #expect(lines.contains("Files: 1 new, 0 changed, 2 unmodified · processed \(Format.bytes(5000)) · added \(Format.bytes(5300))"))
        // Named and kinded, never located: the location can carry a host,
        // a bucket or a user name the log has no business repeating.
        #expect(!text.contains("/Volumes/Secret/repo"))
        #expect(!text.contains("omitted"))
    }

    @Test("an entry that spans lines keeps the text column: continuation lines sit under it, never at the margin")
    func multilineEntryKeepsTheColumn() throws {
        let record = RunRecord(kind: .backup, planName: "Documents", startedAt: at(0))
        // restic's lock refusal, carried whole in a retention-skip note.
        let contents = RunTranscript.Contents(
            entries: [
                .init(
                    time: at(2),
                    kind: .note,
                    text: "Retention skipped: repository is already locked\nlock was created at 2026-09-26 23:15:09\r\nstorage ID 20bfe2fa"
                ),
            ],
            headCount: 1,
            omittedLineCount: 0,
            firstExitCode: nil
        )
        let text = RunLog.render(
            record: record,
            repositoryName: nil,
            repositoryKind: nil,
            versions: versions,
            transcript: contents,
            timeZone: TimeZone(identifier: "UTC")!
        )
        let lines = text.components(separatedBy: "\n")
        let first = try #require(
            lines.firstIndex(of: "07:58:19 note Retention skipped: repository is already locked"),
            "log was \(text)"
        )
        try #require(lines.count > first + 2)
        // "HH:mm:ss " plus the four-character tag and its space.
        #expect(lines[first + 1] == "              lock was created at 2026-09-26 23:15:09", "log was \(text)")
        #expect(lines[first + 2] == "              storage ID 20bfe2fa")
        #expect(!text.contains("\r"))
    }

    @Test("a restore's log says what landed and where")
    func renderedRestoreLog() {
        var record = RunRecord(kind: .restore, planName: "Budget.numbers", startedAt: at(0))
        record.finishedAt = at(1)
        record.snapshotID = "abf72899"
        record.sourcePath = "/src/Documents/Budget.numbers"
        record.destinationPath = "/tmp/restored/Budget.numbers"
        record.filesRestored = 1
        record.bytesProcessed = 14

        let text = RunLog.render(
            record: record,
            repositoryName: nil,
            repositoryKind: nil,
            versions: versions,
            transcript: RunTranscript.Contents(),
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(text.contains("Restore of “Budget.numbers” — repository no longer set up in SwiftRestic"))
        #expect(text.contains("Restored 1 file, \(Format.bytes(14)); 0 kept as they were"))
        #expect(text.contains("Restored to /tmp/restored/Budget.numbers"))
        #expect(text.contains("No restic command ran."))

        record.filesSkipped = 1
        let kept = RunLog.render(
            record: record,
            repositoryName: nil,
            repositoryKind: nil,
            versions: versions,
            transcript: RunTranscript.Contents(),
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(kept.contains("Restored 1 file, \(Format.bytes(14)); 1 kept as it was"), "log was \(kept)")
    }

    @Test("the store writes, reads, removes and sweeps only <UUID>.log files")
    func storeLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticRunLogs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RunLogStore(directory: directory)

        let kept = UUID()
        let removed = UUID()
        let untouched = UUID()
        try store.write("kept log", for: kept)
        try store.write("removed log", for: removed)
        try store.write("untouched log", for: untouched)
        #expect(store.read(kept) == "kept log")
        #expect(store.url(for: kept).lastPathComponent == "\(kept.uuidString).log")

        store.remove([removed])
        #expect(store.read(removed) == nil)
        #expect(store.read(untouched) == "untouched log")

        // The sweep: an unknown old log goes; a known one, a new one and
        // anything not named <UUID>.log stay.
        let orphan = UUID()
        let fresh = UUID()
        try store.write("orphan", for: orphan)
        try store.write("fresh", for: fresh)
        let notes = directory.appendingPathComponent("notes.txt")
        try "keep".write(to: notes, atomically: true, encoding: .utf8)
        let oddName = directory.appendingPathComponent("not-a-uuid.log")
        try "keep".write(to: oddName, atomically: true, encoding: .utf8)
        let old = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01
        let cutoff = Date.now
        for url in [store.url(for: orphan), store.url(for: kept), notes, oddName] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: cutoff.addingTimeInterval(3600)],
            ofItemAtPath: store.url(for: fresh).path
        )

        let swept = store.sweep(keeping: [kept, untouched], olderThan: cutoff)
        #expect(swept == 1)
        #expect(store.read(orphan) == nil)
        #expect(store.read(kept) == "kept log")
        #expect(store.read(fresh) == "fresh")
        #expect(FileManager.default.fileExists(atPath: notes.path))
        #expect(FileManager.default.fileExists(atPath: oddName.path))

        // Removing what is not there, from a directory that never existed,
        // is quiet and creates nothing.
        let absent = RunLogStore(directory: directory.appendingPathComponent("never"))
        absent.remove([UUID()])
        #expect(absent.sweep(keeping: [], olderThan: .now) == 0)
        #expect(!FileManager.default.fileExists(atPath: absent.directory.path))
    }
}
