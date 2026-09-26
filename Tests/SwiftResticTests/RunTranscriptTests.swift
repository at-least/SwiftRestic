import Foundation
import Testing

/// What a run's log keeps of restic's words, and the caps that keep a
/// pathological run from holding the app's memory hostage.
@Suite("run transcript")
struct RunTranscriptTests {
    private func output(_ transcript: RunTranscript, _ line: String, _ stream: RunTranscript.Stream) {
        transcript.output(line, message: ResticMessageDecoder.decode(line: line), stream: stream)
    }

    @Test("a transcript keeps restic's words and drops its progress ticks")
    func keepsWordsDropsTicks() {
        let transcript = RunTranscript()
        transcript.command("restic backup --json /src")
        output(transcript, #"{"message_type":"status","percent_done":0.5,"total_files":4,"files_done":1}"#, .stdout)
        output(transcript, #"{"message_type":"verbose_status","action":"new","item":"/src/a.txt"}"#, .stdout)
        output(
            transcript,
            #"{"message_type":"error","error":{"message":"open /src/x: permission denied"},"during":"archival","item":"/src/x"}"#,
            .stderr
        )
        output(transcript, "/src/gone does not exist, skipping", .stderr)
        output(transcript, "", .stdout)
        output(transcript, "   ", .stderr)
        transcript.exited(3)

        let contents = transcript.contents
        #expect(contents.entries.map(\.kind) == [.command, .output(.stderr), .output(.stderr), .exit(3)])
        #expect(!contents.entries.contains { $0.text.contains("status") }, "entries were \(contents.entries.map(\.text))")
        #expect(contents.entries[2].text == "/src/gone does not exist, skipping")
        #expect(contents.firstExitCode == 3)
        #expect(contents.omittedLineCount == 0)
    }

    @Test("the first exit is the run's own; later commands never replace it")
    func firstExitWins() {
        let transcript = RunTranscript()
        transcript.command("restic backup --json /src")
        transcript.exited(3)
        transcript.command("restic forget --json")
        transcript.exited(0)
        #expect(transcript.contents.firstExitCode == 3)
    }

    @Test("a flood keeps the head, the last 200 lines and an honest omitted count")
    func floodIsCapped() {
        let transcript = RunTranscript()
        let total = 200_000
        func line(_ index: Int) -> String {
            #"{"message_type":"error","error":{"message":"open /src/file\#(index): permission denied"},"item":"/src/file\#(index)"}"#
        }
        for index in 0 ..< total {
            transcript.output(line(index), message: nil, stream: .stderr)
        }

        let contents = transcript.contents
        let tail = contents.entries.suffix(RunTranscript.tailEntryLimit)
        let head = contents.entries.prefix(contents.headCount)
        #expect(contents.headCount + tail.count == contents.entries.count)
        #expect(tail.count == 200)
        #expect(tail.last?.text == line(total - 1))
        let headBytes = head.reduce(0) { $0 + $1.text.utf8.count }
        #expect(headBytes <= RunTranscript.headByteLimit + line(0).utf8.count, "head held \(headBytes) bytes")
        #expect(headBytes >= RunTranscript.headByteLimit - line(0).utf8.count, "head held only \(headBytes) bytes")
        #expect(contents.omittedLineCount == total - contents.entries.count)

        let record = RunRecord(kind: .backup, planName: "Flood")
        let text = RunLog.render(
            record: record,
            repositoryName: "NAS",
            repositoryKind: "Local folder or disk",
            versions: RunLogVersions(app: "SwiftRestic 0.1.0 (1)", macOS: "macOS 26.6.2", restic: "restic 0.19.1"),
            transcript: contents,
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(text.contains("… \(contents.omittedLineCount.formatted(.number)) lines omitted …"))
    }

    @Test("one giant line is cut, not kept whole")
    func giantLineIsCut() throws {
        let transcript = RunTranscript()
        let giant = String(repeating: "x", count: 1_048_576)
        transcript.output(giant, message: nil, stream: .stdout)

        let stored = try #require(transcript.contents.entries.first).text
        let suffix = " …(truncated, \(1_048_576.formatted(.number)) bytes)"
        #expect(stored.hasSuffix(suffix), "stored line ends \(stored.suffix(40))")
        #expect(stored.utf8.count <= RunTranscript.lineByteLimit + suffix.utf8.count)
        #expect(stored.utf8.count > RunTranscript.lineByteLimit - 8)
    }
}
