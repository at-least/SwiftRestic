import Foundation

/// What restic said during one run, for the run's plain-text log.
///
/// A task-local rather than a parameter, so neither `ResticClient` nor any
/// call site grows one. The run engines bind it around their restic service
/// calls only, never the closing snapshot refresh or the index walks, which
/// are not part of the run. A `Task {}` started inside a bound scope
/// inherits the binding and could append after the run ended;
/// `Task.detached` does not.
///
/// Capped in memory rather than streamed to disk: the first `headByteLimit`
/// bytes, then the last `tailEntryLimit` entries, the lines between counted.
/// restic's final exit_error and the engine's closing notes are in the
/// tail, so they survive. The two reader threads write concurrently, so the
/// lock is taken only inside the synchronous methods.
final class RunTranscript: @unchecked Sendable {
    @TaskLocal static var current: RunTranscript?

    enum Stream: Sendable, Equatable {
        case stdout, stderr
    }

    struct Entry: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case command
            case output(Stream)
            case exit(Int32)
            /// App-written: retention's result, a stop that ended the child
            /// before it could exit.
            case note
        }

        var time: Date
        var kind: Kind
        var text: String
    }

    struct Contents: Sendable, Equatable {
        var entries: [Entry] = []
        /// Omitted lines fall between the first `headCount` entries and the rest.
        var headCount: Int = 0
        var omittedLineCount: Int = 0
        /// The run's primary command (a backup before its forget). Apart from
        /// `entries`, so it survives when its entry was omitted.
        var firstExitCode: Int32?
    }

    static let headByteLimit = 256 * 1024
    static let tailEntryLimit = 200
    static let lineByteLimit = 4096
    /// A plan's switches alone pass some 150 excludes, past `lineByteLimit`,
    /// and the command line is what the log is read for first.
    static let commandByteLimit = 64 * 1024

    private let lock = NSLock()
    private var head: [Entry] = []
    private var headBytes = 0
    /// A ring once full: `tailStart` is the oldest entry's index.
    private var tail: [Entry] = []
    private var tailStart = 0
    private var omitted = 0
    private var firstExitCode: Int32?

    func command(_ text: String) {
        append(Entry(time: .now, kind: .command, text: Self.capped(text, at: Self.commandByteLimit)))
    }

    /// Progress ticks and blank lines are dropped: they make a backup's
    /// output unbounded.
    func output(_ line: String, message: ResticMessage?, stream: Stream) {
        switch message {
        case .status?, .verboseStatus?: return
        default: break
        }
        guard !line.allSatisfy(\.isWhitespace) else { return }
        append(Entry(time: .now, kind: .output(stream), text: Self.capped(line)))
    }

    func exited(_ code: Int32) {
        lock.lock()
        if firstExitCode == nil { firstExitCode = code }
        lock.unlock()
        append(Entry(time: .now, kind: .exit(code), text: String(code)))
    }

    func note(_ text: String) {
        append(Entry(time: .now, kind: .note, text: Self.capped(text)))
    }

    var contents: Contents {
        lock.lock()
        defer { lock.unlock() }
        let ordered = Array(tail[tailStart...] + tail[..<tailStart])
        return Contents(
            entries: head + ordered,
            headCount: head.count,
            omittedLineCount: omitted,
            firstExitCode: firstExitCode
        )
    }

    private func append(_ entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        if headBytes < Self.headByteLimit {
            head.append(entry)
            headBytes += entry.text.utf8.count
            return
        }
        if tail.count < Self.tailEntryLimit {
            tail.append(entry)
            return
        }
        tail[tailStart] = entry
        tailStart = (tailStart + 1) % Self.tailEntryLimit
        omitted += 1
    }

    /// Cut on a scalar boundary, so one pathological line cannot eat the head.
    private static func capped(_ line: String, at limit: Int = lineByteLimit) -> String {
        let length = line.utf8.count
        guard length > limit else { return line }
        let scalars = line.unicodeScalars
        var end = line.utf8.index(line.utf8.startIndex, offsetBy: limit)
        while end.samePosition(in: scalars) == nil {
            end = line.utf8.index(before: end)
        }
        return String(scalars[..<end]) + " …(truncated, \(length.formatted(.number)) bytes)"
    }
}
