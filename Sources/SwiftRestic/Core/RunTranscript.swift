import Foundation

/// What restic said during one run — the command lines, every line it
/// printed except progress ticks, and its exit codes — for the plain-text
/// log the run leaves beside `config.json`.
///
/// Reached through a task-local rather than a parameter: the run engines
/// bind one around their restic service calls (`$current.withValue`), and
/// `ResticRunner.run` records into whatever is bound, so neither the
/// `ResticClient` protocol nor any call site grows a parameter. The binding
/// is kept narrow on purpose — the service calls only, never the closing
/// snapshot refresh or the index walks, which run restic too but are not
/// part of the run. Any `Task {}` started inside a bound scope inherits the
/// binding and could append after the run has ended; `Task.detached` does
/// not (probed). `HookRunner` shields itself with `withValue(nil)`, so a
/// hook's command and output — which can carry secrets — never land here.
///
/// Memory is capped rather than streamed to disk: the first `headByteLimit`
/// bytes of text are kept, then only the last `tailEntryLimit` entries, and
/// the lines that fell between are counted. restic's final exit_error and
/// the engine's closing notes are in the tail, so they always survive.
/// Every line is also cut at `lineByteLimit`. The two reader threads write
/// concurrently, so all state sits behind one lock, taken only inside the
/// synchronous methods below.
final class RunTranscript: @unchecked Sendable {
    @TaskLocal static var current: RunTranscript?

    enum Stream: Sendable, Equatable {
        case stdout, stderr
    }

    struct Entry: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            /// A command line, as `ResticInvocation.displayCommand` renders it.
            case command
            case output(Stream)
            case exit(Int32)
            /// An app-authored line: a hook's verdict, retention's result, a
            /// stop that ended the child before it could exit.
            case note
        }

        var time: Date
        var kind: Kind
        var text: String
    }

    struct Contents: Sendable, Equatable {
        var entries: [Entry] = []
        /// How many of `entries` were kept from the start; any omitted lines
        /// fell between these and the rest.
        var headCount: Int = 0
        var omittedLineCount: Int = 0
        /// The first exit code recorded — the run's primary command (a
        /// backup before its forget, a restore's one command). Kept apart
        /// from `entries`, so it survives even when its entry was omitted.
        var firstExitCode: Int32?
    }

    static let headByteLimit = 256 * 1024
    static let tailEntryLimit = 200
    static let lineByteLimit = 4096

    private let lock = NSLock()
    private var head: [Entry] = []
    private var headBytes = 0
    /// A ring once full: `tailStart` is the oldest entry's index.
    private var tail: [Entry] = []
    private var tailStart = 0
    private var omitted = 0
    private var firstExitCode: Int32?

    func command(_ text: String) {
        append(Entry(time: .now, kind: .command, text: Self.capped(text)))
    }

    /// One line restic printed. Progress ticks (`status`, `verbose_status`)
    /// and blank lines are dropped: they are what makes a backup's output
    /// unbounded, and the log is a record of what restic said, not of how
    /// fast it went.
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

    /// A line cut at `lineByteLimit` bytes, on a scalar boundary, with the
    /// length it had — one pathological line must not eat the head alone.
    private static func capped(_ line: String) -> String {
        let length = line.utf8.count
        guard length > lineByteLimit else { return line }
        let scalars = line.unicodeScalars
        var end = line.utf8.index(line.utf8.startIndex, offsetBy: lineByteLimit)
        while end.samePosition(in: scalars) == nil {
            end = line.utf8.index(before: end)
        }
        return String(scalars[..<end]) + " …(truncated, \(length.formatted(.number)) bytes)"
    }
}
