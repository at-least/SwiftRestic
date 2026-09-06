import Foundation

/// One restic command line plus the environment it needs.
struct ResticInvocation: Sendable {
    var arguments: [String]
    var environment: [String: String] = [:]
    /// Exit codes that should not be treated as failure. `backup` adds 3, which
    /// means "finished, but some files could not be read".
    ///
    /// `nil` accepts any code, for callers that read the exit status themselves
    /// rather than treating it as an error — a shell hook, for instance.
    var allowedExitCodes: Set<Int32>? = [0]
    /// Where raw stdout should go instead of being parsed (used by `restic dump`).
    var stdoutFile: URL?
    /// Kill the child after this many seconds. A hook that never returns must not
    /// hang the backup that triggered it.
    var timeout: TimeInterval?
    /// Keep the whole stdout text rather than a bounded tail. Needed for the
    /// commands that answer with one big JSON array (`snapshots`, `stats`,
    /// `forget`) instead of a line-per-event stream.
    var retainFullOutput: Bool = false
    /// Keep every decoded message in the result. Off for commands whose stream
    /// is unbounded — a `diff` of two home-folder snapshots is hundreds of
    /// thousands of lines — where the caller collects through `onMessage` and
    /// stops keeping them at some cap of its own.
    var retainMessages: Bool = true

    /// A redacted rendering for logs and error messages.
    var displayCommand: String {
        (["restic"] + arguments).joined(separator: " ")
    }
}

struct ResticRunResult: Sendable {
    var exitCode: Int32
    var messages: [ResticMessage]
    var stdout: String
    var stderr: String

    /// The fatal error restic reported, if it wrote one as JSON.
    var exitError: ResticExitError? {
        for message in messages.reversed() {
            if case let .exitError(error) = message { return error }
        }
        return nil
    }

    /// Non-fatal per-item errors, in order.
    var itemErrors: [ResticErrorMessage] {
        messages.compactMap { if case let .error(e) = $0 { e } else { nil } }
    }

    var summary: ResticSummary? {
        for message in messages.reversed() {
            if case let .summary(s) = message { return s }
        }
        return nil
    }
}

/// Spawns a child process and turns any NDJSON it writes into `ResticMessage`
/// values.
///
/// Written for restic, and also used to run a plan's shell hooks: they need the
/// same pipe draining, cancellation and timeout handling, and lines that are not
/// restic JSON simply decode to nothing.
///
/// The runner is an actor so that in-flight processes can be tracked and
/// cancelled by handle. Its methods suspend rather than block while restic runs,
/// so concurrent calls (a snapshot listing during a backup, say) are not
/// serialised behind each other.
actor ResticRunner {
    private var running: [UUID: ProcessBox] = [:]

    /// Runs restic to completion.
    ///
    /// - Parameter onMessage: called for every decoded NDJSON line as it arrives,
    ///   off the main actor.
    /// - Throws: `ResticError.commandFailed` for a disallowed exit code, or
    ///   `ResticError.cancelled` if the surrounding task was cancelled.
    func run(
        binary: URL,
        invocation: ResticInvocation,
        onMessage: (@Sendable (ResticMessage) -> Void)? = nil
    ) async throws -> ResticRunResult {
        let handle = UUID()
        let process = Process()
        process.executableURL = binary
        process.arguments = invocation.arguments
        process.environment = Self.baseEnvironment().merging(invocation.environment) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        var stdoutFileHandle: FileHandle?
        if let stdoutFile = invocation.stdoutFile {
            FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
            let fh = try FileHandle(forWritingTo: stdoutFile)
            stdoutFileHandle = fh
            process.standardOutput = fh
        } else {
            process.standardOutput = stdoutPipe
        }
        process.standardError = stderrPipe
        // No terminal is attached, so a backend that tries to prompt (an SFTP
        // host-key confirmation, say) must fail fast rather than hang on a stdin
        // that will never answer.
        process.standardInput = FileHandle.nullDevice

        let box = ProcessBox(process)
        let exit = ExitWaiter()
        process.terminationHandler = { finished in
            exit.complete(finished.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            throw ResticError.processLaunchFailed(error.localizedDescription)
        }
        running[handle] = box
        defer { running[handle] = nil }

        let watchdog: Task<Void, Never>? = invocation.timeout.map { seconds in
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                box.terminate(dueToTimeout: true)
            }
        }
        defer { watchdog?.cancel() }

        let parseStdout = invocation.stdoutFile == nil
        let stdoutReader = StreamReader(
            handle: stdoutPipe.fileHandleForReading,
            active: parseStdout,
            textLimit: invocation.retainFullOutput ? .max : StreamReader.defaultTextLimit,
            retainMessages: invocation.retainMessages
        )
        let stderrReader = StreamReader(
            handle: stderrPipe.fileHandleForReading,
            active: true,
            textLimit: StreamReader.defaultTextLimit,
            retainMessages: true
        )

        let exitCode: Int32
        do {
            exitCode = try await withTaskCancellationHandler {
                // restic writes its per-item error events to stderr, not stdout —
                // a partial backup's `message_type: error` lines (and its exit_error)
                // only reach the result if stderr is decoded too. The decoder drops
                // every non-JSON line, so human-readable stderr noise is unaffected.
                async let stderrOutcome = stderrReader.readAll(decodeMessages: true, onMessage: onMessage)
                let stdoutOutcome = await stdoutReader.readAll(
                    decodeMessages: true,
                    onMessage: onMessage
                )
                let stderr = await stderrOutcome
                let code = await exit.value()

                // Same-actor call: nothing here actually suspends.
                self.store(
                    handle: handle,
                    stdout: stdoutOutcome,
                    stderr: stderr.text,
                    stderrMessages: stderr.messages
                )
                try Task.checkCancellation()
                return code
            } onCancel: {
                box.terminate()
            }
        } catch is CancellationError {
            // Nothing will read this run's captured output; dropping it keeps a
            // cancelled command from squatting on memory inside the actor.
            _ = takeCaptured(handle: handle)
            throw ResticError.cancelled
        }

        try? stdoutFileHandle?.close()
        let captured = takeCaptured(handle: handle)

        if box.timedOut {
            throw ResticError.timedOut(
                seconds: invocation.timeout ?? 0,
                command: invocation.displayCommand
            )
        }

        if let allowed = invocation.allowedExitCodes, !allowed.contains(exitCode) {
            let message = captured.messages.compactMap { message -> String? in
                if case let .exitError(error) = message { return error.message }
                return nil
            }.last ?? Self.tail(of: captured.stderr, limit: 2000)
            throw ResticError.commandFailed(
                exitCode: exitCode,
                message: message,
                command: invocation.displayCommand
            )
        }

        return ResticRunResult(
            exitCode: exitCode,
            messages: captured.messages,
            stdout: captured.stdout,
            stderr: captured.stderr
        )
    }

    /// Terminates every running restic process. Used when the app quits.
    func terminateAll() {
        for box in running.values { box.terminate() }
    }

    // MARK: - Capture bookkeeping

    private var captured: [UUID: (messages: [ResticMessage], stdout: String, stderr: String)] = [:]

    /// stderr's decoded events are appended after stdout's, so a backup's
    /// per-item errors land after its summary. Order within each stream is
    /// preserved, and every consumer reads one stream's events or does reversed
    /// lookup, so the interleaving is never load-bearing.
    private func store(
        handle: UUID,
        stdout: StreamReader.Outcome,
        stderr: String,
        stderrMessages: [ResticMessage]
    ) {
        captured[handle] = (stdout.messages + stderrMessages, stdout.text, stderr)
    }

    private func takeCaptured(handle: UUID) -> (messages: [ResticMessage], stdout: String, stderr: String) {
        defer { captured[handle] = nil }
        return captured[handle] ?? ([], "", "")
    }

    // MARK: - Environment

    /// A predictable environment for the child. A GUI app's inherited environment
    /// is nearly empty, so we rebuild the parts restic actually reads.
    ///
    /// restic's own repository and password variables are stripped from whatever
    /// we inherited: they would win over the per-repository values restic is
    /// handed (restic ranks PASSWORD_COMMAND and PASSWORD_FILE above PASSWORD),
    /// and the app always supplies them explicitly — backrest issue #1139.
    private static func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["RESTIC_REPOSITORY", "RESTIC_PASSWORD", "RESTIC_PASSWORD_FILE", "RESTIC_PASSWORD_COMMAND"] {
            env.removeValue(forKey: key)
        }
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = env["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        var merged = existing
        for path in extraPaths where !merged.contains(path) { merged.append(path) }
        env["PATH"] = merged.joined(separator: ":")
        // Keep restic's own progress printer quiet; we drive progress from JSON.
        env["RESTIC_PROGRESS_FPS"] = "1"
        return env
    }

    static func tail(of text: String, limit: Int) -> String {
        guard text.count > limit else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(text.suffix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Sendable shims

/// `Process` is safe to `terminate()` from another thread but is not annotated
/// `Sendable`. This is the one deliberate wrapper in the codebase; keep it small.
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var wasTimedOut = false

    init(_ process: Process) { self.process = process }

    func terminate(dueToTimeout: Bool = false) {
        lock.lock()
        if dueToTimeout { wasTimedOut = true }
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    /// Whether the watchdog, rather than the user, ended this process.
    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasTimedOut
    }
}

/// Bridges `Process.terminationHandler` to `async`. The handler is installed
/// before `run()`, so an immediate exit cannot be missed.
private final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func complete(_ code: Int32) {
        lock.lock()
        guard status == nil else { lock.unlock(); return }
        status = code
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: code)
    }

    func value() async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            lock.lock()
            if let status {
                lock.unlock()
                cont.resume(returning: status)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }
}

/// Reads one pipe to EOF on a background queue, splitting it into lines.
///
/// Both pipes must be drained concurrently: restic will block on a full stderr
/// buffer while we are still reading stdout, and the command would never finish.
private struct StreamReader: Sendable {
    struct Outcome: Sendable {
        var messages: [ResticMessage] = []
        var text: String = ""
    }

    static let defaultTextLimit = 64 * 1024

    let handle: FileHandleBox
    let active: Bool
    let textLimit: Int
    let retainMessages: Bool

    init(handle: FileHandle, active: Bool, textLimit: Int, retainMessages: Bool) {
        self.handle = FileHandleBox(handle)
        self.active = active
        self.textLimit = textLimit
        self.retainMessages = retainMessages
    }

    func readAll(
        decodeMessages: Bool,
        onMessage: (@Sendable (ResticMessage) -> Void)?
    ) async -> Outcome {
        guard active else { return Outcome() }
        let box = handle
        return await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            DispatchQueue.global(qos: .utility).async {
                var outcome = Outcome()
                var buffer = Data()
                var retained = ""
                let limit = textLimit
                let keepMessages = retainMessages

                func consume(_ line: String) {
                    // utf8.count, not count: grapheme counting is O(n) and this
                    // runs once per line for the whole stream.
                    if retained.utf8.count < limit { retained += line + "\n" }
                    guard decodeMessages, let message = ResticMessageDecoder.decode(line: line) else { return }
                    // Fatal errors are always kept: the runner reads them back to
                    // build the failure message when the exit code is bad.
                    if keepMessages { outcome.messages.append(message) }
                    else if case .exitError = message { outcome.messages.append(message) }
                    onMessage?(message)
                }

                while true {
                    let chunk = box.read(upToCount: 64 * 1024)
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex ..< newline]
                        buffer.removeSubrange(buffer.startIndex ... newline)
                        if let line = String(data: lineData, encoding: .utf8) { consume(line) }
                    }
                }
                if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
                    consume(line)
                }
                box.close()
                outcome.text = retained
                cont.resume(returning: outcome)
            }
        }
    }
}

/// Reads are thread-confined here: exactly one background queue touches each
/// descriptor for its whole lifetime.
private final class FileHandleBox: @unchecked Sendable {
    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }

    /// Raw `read(2)` on the descriptor, not `FileHandle.read(upToCount:)`.
    /// Foundation's read buffers on pipes: measured against an identical
    /// invocation, `FileHandle.read` delivered restic's status lines only at
    /// process exit while `read(2)` returned each line as it was written — the
    /// difference between a progress bar that moves and one stuck at 0%.
    func read(upToCount count: Int) -> Data {
        var storage = [UInt8](repeating: 0, count: count)
        let bytesRead = storage.withUnsafeMutableBufferPointer { buffer -> Int in
            while true {
                let n = Darwin.read(handle.fileDescriptor, buffer.baseAddress, buffer.count)
                // A signal interrupt must not read as EOF: retry it, or the
                // stream would silently end early.
                if n < 0, errno == EINTR { continue }
                return n
            }
        }
        guard bytesRead > 0 else { return Data() }
        return Data(storage[0 ..< bytesRead])
    }

    func close() { try? handle.close() }
}
