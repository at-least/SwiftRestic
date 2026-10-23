import Foundation

/// One restic command line plus the environment it needs.
struct ResticInvocation: Sendable {
    var arguments: [String]
    var environment: [String: String] = [:]
    /// Where the child runs. `nil` inherits the app's own working directory,
    /// which for a Finder-launched GUI app is `/` — a surprise no script
    /// should have to guess at, so callers that run user-authored commands
    /// (hooks) name a directory explicitly.
    var workingDirectory: String?
    /// Exit codes that should not be treated as failure. `backup` adds 3, which
    /// means "finished, but some files could not be read".
    ///
    /// `nil` accepts any code, for callers that read the exit status themselves
    /// rather than treating it as an error — a shell hook, for instance.
    var allowedExitCodes: Set<Int32>? = [0]
    /// Kill the child after this many seconds. A hook that never returns must not
    /// hang the backup that triggered it.
    var timeout: TimeInterval?
    /// Kill the child after it has produced no output at all for this many
    /// seconds — a stall cap, not a runtime cap: every received chunk resets
    /// the clock. For commands that stream NDJSON while they work (`backup`,
    /// `restore`, the index walks) total silence means the child is hung, while
    /// a total cap would kill work that was merely slow. Commands that are
    /// legitimately silent for long stretches (`prune`, `forget`, a console
    /// `runRaw`) must not set this.
    var idleTimeout: TimeInterval?
    /// Keep the whole stdout text rather than a bounded tail. Needed for the
    /// commands that answer with one big JSON array (`snapshots`, `stats`,
    /// `forget`) instead of a line-per-event stream.
    var retainFullOutput: Bool = false
    /// Keep every decoded message in the result. Off for commands whose stream
    /// is unbounded — a `diff` of two home-folder snapshots is hundreds of
    /// thousands of lines — where the caller collects through `onMessage` and
    /// stops keeping them at some cap of its own.
    var retainMessages: Bool = true

    /// The arguments for logs and error messages — without the environment,
    /// so the password stays out, but every argument as given — through the
    /// console tokenizer's shell-style quoting, so a path with spaces stays
    /// one word on screen instead of reading as two arguments the run never
    /// received.
    var displayCommand: String {
        CommandLineTokenizer.render(["restic"] + arguments)
    }
}

struct ResticRunResult: Sendable {
    var exitCode: Int32
    var messages: [ResticMessage]
    var stdout: String
    var stderr: String
    /// Lines carrying a known `message_type` whose payload failed to decode.
    /// A schema change under us must be countable, not silent — the run
    /// record reports this number instead of dropping the lines.
    var malformedCount: Int = 0

    /// The fatal error restic reported, if it wrote one as JSON.
    var exitError: ResticExitError? {
        for message in messages.reversed() {
            if case let .exitError(error) = message { return error }
        }
        return nil
    }

    /// restic's fatal-error line when it wrote one as JSON, else the tail of
    /// stderr — what a failed command's error carries. Under `--json` the
    /// fatal line can lose the cause: what ssh or rclone said reaches
    /// stderr only as plain lines restic prefixes "subprocess " ("subprocess
    /// ssh: Host key verification failed.", restic 0.19.1) or "rclone: "
    /// ("rclone: 2026/10/16 02:54:34 CRITICAL: Failed to create file system
    /// for …", rclone 1.75.2), so the last of those follow the fatal line —
    /// ssh's verdict is its last lines, after a warning banner that runs to
    /// a dozen; rclone's are its errors, not its notices.
    var failureMessage: String {
        guard let fatal = exitError?.message else { return ResticRunner.tail(of: stderr, limit: 2000) }
        let lines = stderr.split(separator: "\n")
        let subprocess = lines.filter { $0.hasPrefix("subprocess ") }.suffix(3).map(String.init)
        let rclone = lines.compactMap(Self.rcloneComplaint).suffix(3)
        return ([Self.withoutGoStackTrace(fatal)] + subprocess + rclone).joined(separator: "\n")
    }

    /// What restic was retrying, from its last "… returned error, retrying
    /// after …" line on stderr — "Stat(<config/>) returned error, retrying
    /// after 38.6s: Head "http://…/config": dial tcp 127.0.0.1:18000:
    /// connect: connection refused" gives "connection refused" — or empty.
    static func retryCause(in stderr: String) -> String {
        guard let line = stderr.split(separator: "\n").last(where: { $0.contains(" returned error, retrying after ") }) else { return "" }
        return line.components(separatedBy: ": ").last ?? ""
    }

    /// restic's message without the Go stack restic 0.19.1 appends to an
    /// error that is not one of its fatal ones (`%+v` in its main.go) —
    /// "failed to remove one or more snapshots\nmain.init\n\tgithub.com/
    /// restic/restic/cmd/restic/cmd_forget.go:67\n…". It ends before the
    /// first frame: a line followed by a tab-indented "….go:<line>". The
    /// run's log keeps the whole line.
    static func withoutGoStackTrace(_ message: String) -> String {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        for index in lines.indices.dropLast() {
            let next = lines[index + 1]
            if next.hasPrefix("\t"), next.range(of: #"\.go:\d+$"#, options: .regularExpression) != nil {
                return lines[..<index].joined(separator: "\n")
            }
        }
        return message
    }

    /// "rclone: Failed to create file system for …" for one of rclone's
    /// errors as restic passes it on — "rclone: <date> <time> CRITICAL: …"
    /// or "… ERROR : …" — without the date and the level; nil for any other
    /// line, rclone's notices among them.
    static func rcloneComplaint(_ line: Substring) -> String? {
        guard line.hasPrefix("rclone: ") else { return nil }
        for level in [" CRITICAL: ", " ERROR : "] {
            if let range = line.range(of: level) { return "rclone: " + line[range.upperBound...] }
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
    /// Grace between SIGTERM and SIGKILL when a child is being stopped —
    /// long enough for restic to flush and a shell to unwind, short enough
    /// that a quit waiting on the child does not outwait the user's patience.
    static let killGrace: TimeInterval = 5

    /// How long the pipe readers may keep draining after the child has died.
    /// A healthy pipe reaches EOF within milliseconds of the child's exit;
    /// when it does not, someone else is holding the write end — a shell hook
    /// that backgrounded a long-lived command (`notify-me &`), or restic's own
    /// backend child after a SIGKILL. Abandoning the pipes then is what lets
    /// every stop path answer: the invariant is that a run ends at most this
    /// long after its child dies, whatever a grandchild does. Bytes a
    /// grandchild writes afterwards get EPIPE, which usually ends it too.
    static let grandchildGrace: TimeInterval = 2

    private var running: [UUID: ProcessBox] = [:]

    /// Runs restic to completion.
    ///
    /// - Parameter onMessage: called for every decoded NDJSON line as it arrives,
    ///   off the main actor.
    /// - Parameter onRawLine: called for every raw line of both streams before
    ///   JSON decoding — the human-readable progress `prune` prints, which
    ///   decodes to nothing. Fires off the main actor, possibly concurrently
    ///   for the two streams, with no ordering guarantee between them; keep
    ///   the callback cheap. Commands whose streams are unbounded (backup,
    ///   diff) must not pass it: there is no back-pressure.
    /// - Throws: `ResticError.commandFailed` for a disallowed exit code, or
    ///   `ResticError.cancelled` if the surrounding task was cancelled.
    ///
    /// When a `RunTranscript` is bound (a run engine's service call), the
    /// command line, every line either stream printed and the exit code are
    /// recorded into it; a child stopped by a cancel or a cap leaves a note
    /// instead of an exit code, because a signal's termination status is
    /// not one.
    func run(
        binary: URL,
        invocation: ResticInvocation,
        onMessage: (@Sendable (ResticMessage) -> Void)? = nil,
        onRawLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ResticRunResult {
        let handle = UUID()
        // Read once, here in the caller's task: the pipe readers run on GCD
        // threads, where task-locals are not visible — they get the
        // reference itself.
        let transcript = RunTranscript.current
        let process = Process()
        process.executableURL = binary
        process.arguments = invocation.arguments
        if let workingDirectory = invocation.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        process.environment = Self.baseEnvironment().merging(invocation.environment) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
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

        // Registered before launch, not after: a quit racing a cold spawn
        // must not miss a child that is already running. The ProcessBox
        // treats a not-yet-launched process as not running, so a terminate
        // that arrives in this window is a harmless no-op, and the defer
        // covers the launch-failure path.
        running[handle] = box
        defer { running[handle] = nil }

        transcript?.command(invocation.displayCommand)
        do {
            try process.run()
        } catch {
            let failure = ResticError.processLaunchFailed(error.localizedDescription)
            transcript?.note(failure.localizedDescription)
            throw failure
        }

        let watchdog: Task<Void, Never>? = invocation.timeout.map { seconds in
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                box.terminate(timeout: true)
            }
        }
        defer { watchdog?.cancel() }

        // The stall cap: a once-a-second look at how long since the last
        // chunk. Polling rather than re-arming a sleep per line, which would
        // churn tasks at restic's progress rate.
        let idleWatchdog: Task<Void, Never>? = invocation.idleTimeout.map { seconds in
            Task { [weak box] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    if let box, box.idleInterval >= seconds {
                        box.terminate(idleTimeout: true)
                        return
                    }
                }
            }
        }
        defer { idleWatchdog?.cancel() }

        // Any chunk on either pipe proves the child is alive and counts
        // against the stall cap — complete lines are not required.
        let activity: @Sendable () -> Void = { [weak box] in
            guard let box else { return }
            box.ping()
        }
        let stdoutReader = StreamReader(
            handle: stdoutPipe.fileHandleForReading,
            textLimit: invocation.retainFullOutput ? .max : StreamReader.defaultTextLimit,
            retainMessages: invocation.retainMessages,
            onActivity: activity
        )
        let stderrReader = StreamReader(
            handle: stderrPipe.fileHandleForReading,
            textLimit: StreamReader.defaultTextLimit,
            retainMessages: true,
            onActivity: activity
        )
        let stdoutLine = Self.transcriptFeed(transcript, stream: .stdout)
        let stderrLine = Self.transcriptFeed(transcript, stream: .stderr)

        // The reaper: a pipe that has not reached EOF within `grandchildGrace`
        // of the child's death is being held open by an inherited copy — a
        // backgrounded hook command, a backend child that outlived a SIGKILL —
        // and no signal of ours can reach it. Abandoning the read then is what
        // keeps every stop path (caps, cancellation, quit's terminateAll)
        // answerable; a healthy run never sees it, because EOF lands in
        // milliseconds. A second waiter on `exit` is exactly why ExitWaiter
        // keeps a list of continuations rather than one.
        let reaper = Task {
            _ = await exit.value()
            try? await Task.sleep(for: .seconds(Self.grandchildGrace))
            stdoutReader.abandon()
            stderrReader.abandon()
        }
        defer { reaper.cancel() }

        let result: ResticRunResult
        do {
            result = try await withTaskCancellationHandler {
                // restic writes its per-item error events to stderr, not stdout —
                // a partial backup's `message_type: error` lines (and its exit_error)
                // only reach the result if stderr is decoded too. The decoder drops
                // every non-JSON line, so human-readable stderr noise is unaffected.
                async let stderrOutcome = stderrReader.readAll(
                    onMessage: onMessage,
                    onRawLine: onRawLine,
                    onLine: stderrLine
                )
                let stdoutOutcome = await stdoutReader.readAll(
                    onMessage: onMessage,
                    onRawLine: onRawLine,
                    onLine: stdoutLine
                )
                let stderr = await stderrOutcome
                let code = await exit.value()
                try Task.checkCancellation()
                return Self.result(exitCode: code, stdout: stdoutOutcome, stderr: stderr)
            } onCancel: {
                box.terminate()
            }
        } catch is CancellationError {
            transcript?.note("Stopped: cancelled")
            throw ResticError.cancelled
        }
        let exitCode = result.exitCode

        if box.idleTimedOut {
            let seconds = invocation.idleTimeout ?? 0
            transcript?.note("Stopped: no output for \(Int(seconds)) s")
            throw ResticError.idleStalled(seconds: seconds)
        }

        if box.timedOut {
            let seconds = invocation.timeout ?? 0
            transcript?.note("Stopped: timed out after \(Int(seconds)) s")
            throw ResticError.timedOut(seconds: seconds, cause: ResticRunResult.retryCause(in: result.stderr))
        }

        // Before the verdict below, so a failing exit is logged too.
        transcript?.exited(exitCode)

        if let allowed = invocation.allowedExitCodes, !allowed.contains(exitCode) {
            throw ResticError.commandFailed(
                exitCode: exitCode,
                message: result.failureMessage
            )
        }

        return result
    }

    /// Terminates every running restic process. Used when the app quits.
    func terminateAll() {
        for box in running.values { box.terminate() }
    }

    // MARK: - Capture

    /// stderr's decoded events are appended after stdout's, so a backup's
    /// per-item errors land after its summary. Order within each stream is
    /// preserved, and every consumer reads one stream's events or does reversed
    /// lookup, so the interleaving is never load-bearing.
    private static func result(
        exitCode: Int32,
        stdout: StreamReader.Outcome,
        stderr: StreamReader.Outcome
    ) -> ResticRunResult {
        ResticRunResult(
            exitCode: exitCode,
            messages: stdout.messages + stderr.messages,
            stdout: stdout.text,
            stderr: stderr.text,
            malformedCount: stdout.malformedCount + stderr.malformedCount
        )
    }

    // MARK: - Environment

    /// Keys the app itself owns: the repository location and every form of the
    /// password restic can read. Letting the environment override these would
    /// silently point restic at another repository or break authentication —
    /// the class of bug behind backrest's issue #1139 — so they are stripped
    /// from every child's inheritance here, and
    /// `RepositoryContext.overriddenExtraEnvironmentKeys` reads the same set
    /// to flag the settings that can have no effect.
    static let protectedEnvironmentKeys: Set<String> = [
        "RESTIC_REPOSITORY", "RESTIC_PASSWORD", "RESTIC_PASSWORD_FILE", "RESTIC_PASSWORD_COMMAND",
    ]

    /// A predictable environment for the child. A GUI app's inherited environment
    /// is nearly empty, so we rebuild the parts restic actually reads.
    ///
    /// restic's own repository and password variables are stripped from whatever
    /// we inherited: they would win over the per-repository values restic is
    /// handed (restic ranks PASSWORD_COMMAND and PASSWORD_FILE above PASSWORD),
    /// and the app always supplies them explicitly.
    private static func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in Self.protectedEnvironmentKeys {
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

    /// A reader's line callback that records into the run's transcript, or
    /// none when no transcript is bound.
    private static func transcriptFeed(
        _ transcript: RunTranscript?,
        stream: RunTranscript.Stream
    ) -> (@Sendable (String, ResticMessage?) -> Void)? {
        guard let transcript else { return nil }
        return { line, message in transcript.output(line, message: message, stream: stream) }
    }

    static func tail(of text: String, limit: Int) -> String {
        guard text.count > limit else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(text.suffix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Sendable shims

/// `Process` is safe to `terminate()` from another thread but is not annotated
/// `Sendable`. A lock-guarded `@unchecked Sendable` shim — one of several
/// across the codebase; keep it small.
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var wasTimedOut = false
    private var wasIdleTimedOut = false
    /// In `systemUptime` terms, not wall-clock time: the uptime clock pauses
    /// while the Mac sleeps, so a backup that survives a closed lid is not
    /// read as having been silent for the whole nap.
    private var lastActivity = ProcessInfo.processInfo.systemUptime

    init(_ process: Process) {
        self.process = process
    }

    /// Ends the process. The two flags record *why*: one for the wall-clock
    /// cap killing slow work, one for the idle cap killing silent work — so
    /// the two caps report differently.
    func terminate(timeout: Bool = false, idleTimeout: Bool = false) {
        lock.lock()
        let running = process.isRunning
        // Only a live process can be killed by the watchdog — a child that
        // exited on its own in the race window between poll and terminate
        // must still report as the success (or failure) it earned.
        if timeout && running { wasTimedOut = true }
        if idleTimeout && running { wasIdleTimedOut = true }
        lock.unlock()
        guard running else { return }
        process.terminate()
        escalateToKill()
    }

    /// SIGTERM is a request, and children may decline it — a shell script
    /// wearing a `trap "" TERM`, a helper wedged in uninterruptible I/O. A
    /// runner that cannot stop its children hangs every cancel and the quit
    /// that drains them, so after the grace it stops asking: SIGKILL. Two
    /// terminate calls racing arm two escalations; the second finds the
    /// process already gone (`isRunning` is the real guard — the pid itself
    /// never changes, so there is nothing to re-verify, and the reuse window
    /// between the check and the kill is not a real one). A grandchild that
    /// inherited the pipes can still hold the streams open after the child
    /// dies; no signal reaches it — the reaper's abandonment (`grandchildGrace`)
    /// is the answer there.
    private func escalateToKill() {
        let identifier = process.processIdentifier
        guard identifier > 0 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(ResticRunner.killGrace))
            self?.killIfStillRunning(identifier)
        }
    }

    /// Synchronous on purpose: the lock must never be taken from an async
    /// context, so the sleeping escalation lands here to do its checking.
    private func killIfStillRunning(_ identifier: pid_t) {
        lock.lock()
        let running = process.isRunning
        lock.unlock()
        guard running else { return }
        kill(identifier, SIGKILL)
    }

    /// Marks the child as alive — called for every chunk read off either pipe.
    func ping() {
        lock.lock()
        lastActivity = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    /// Seconds since the last chunk was read, in uptime terms.
    var idleInterval: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastActivity
    }

    /// Whether the watchdog, rather than the user, ended this process.
    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasTimedOut
    }

    /// Whether the stall cap, rather than the runtime cap, ended this process.
    var idleTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasIdleTimedOut
    }
}

/// Bridges `Process.terminationHandler` to `async`. The handler is installed
/// before `run()`, so an immediate exit cannot be missed.
///
/// Several parties wait on one exit: `run` itself and the reaper task that
/// abandons the pipes `grandchildGrace` later — so the waiter list is an
/// array, never a single slot. A second `value()` overwriting the first
/// caller's continuation would strand it forever.
private final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuations: [CheckedContinuation<Int32, Never>] = []

    func complete(_ code: Int32) {
        lock.lock()
        guard status == nil else { lock.unlock(); return }
        status = code
        let waiting = continuations
        continuations = []
        lock.unlock()
        for continuation in waiting {
            continuation.resume(returning: code)
        }
    }

    func value() async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            lock.lock()
            if let status {
                lock.unlock()
                cont.resume(returning: status)
            } else {
                continuations.append(cont)
                lock.unlock()
            }
        }
    }
}

/// Reads one pipe to EOF, splitting it into lines, until the pipe ends or
/// `abandon()` is called.
///
/// Both pipes must be drained concurrently: restic will block on a full stderr
/// buffer while we are still reading stdout, and the command would never finish.
///
/// The wait is a `poll` over the pipe and a wakeup pipe rather than a plain
/// blocking read: closing a descriptor another thread is blocked reading does
/// not wake it on macOS, so abandonment could not be delivered any other way.
/// The read itself stays raw `read(2)` — Foundation's read buffers on pipes,
/// which would turn restic's progress stream into one lump at process exit
/// (see `FileHandleBox`).
private final class StreamReader: @unchecked Sendable {
    struct Outcome: Sendable {
        var messages: [ResticMessage] = []
        var text: String = ""
        var malformedCount: Int = 0
    }

    static let defaultTextLimit = 64 * 1024

    let handle: FileHandleBox
    let textLimit: Int
    let retainMessages: Bool
    /// Fires for every chunk read, before any line splitting — liveness is
    /// cheaper to prove than progress, and a stall cap only needs liveness.
    let onActivity: (@Sendable () -> Void)?

    /// Wakes the reader out of its `poll` when the run is being abandoned.
    /// The write end is kept open for the reader's lifetime so the signal can
    /// always be delivered; a `write` after the loop has ended fails with
    /// EPIPE and is ignored.
    private let wakeup: Pipe
    private let lock = NSLock()
    /// `true` once the loop has ended, by EOF or by abandonment — makes
    /// `abandon` idempotent and a no-op for an already-finished reader.
    private var finished = false
    private var abandonSignalled = false

    init(
        handle: FileHandle,
        textLimit: Int,
        retainMessages: Bool,
        onActivity: (@Sendable () -> Void)?
    ) {
        self.handle = FileHandleBox(handle)
        self.textLimit = textLimit
        self.retainMessages = retainMessages
        self.onActivity = onActivity
        self.wakeup = Pipe()
    }

    /// Stops the reader at its next `poll`, returning whatever it has. Safe
    /// from any thread, any number of times; a finished reader ignores it.
    func abandon() {
        lock.lock()
        if finished || abandonSignalled {
            lock.unlock()
            return
        }
        abandonSignalled = true
        lock.unlock()
        // One byte is the whole message; the pipe's own buffer makes the
        // write non-blocking.
        var byte: UInt8 = 0x1
        _ = write(wakeup.fileHandleForWriting.fileDescriptor, &byte, 1)
    }

    /// Marks the loop as over, so a later `abandon` cannot resurrect anything.
    private func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    /// - Parameter onLine: every line with what it decoded to (nil for a
    ///   line that is not restic JSON) — the run transcript's feed.
    func readAll(
        onMessage: (@Sendable (ResticMessage) -> Void)?,
        onRawLine: (@Sendable (String) -> Void)? = nil,
        onLine: (@Sendable (String, ResticMessage?) -> Void)? = nil
    ) async -> Outcome {
        let box = handle
        return await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            DispatchQueue.global(qos: .utility).async { [self] in
                var outcome = Outcome()
                var buffer = Data()
                var retained = ""
                let limit = textLimit
                let keepMessages = retainMessages

                func consume(_ line: String) {
                    onRawLine?(line)
                    // utf8.count, not count: grapheme counting is O(n) and this
                    // runs once per line for the whole stream.
                    if retained.utf8.count < limit { retained += line + "\n" }
                    let decoded = ResticMessageDecoder.decode(line: line)
                    onLine?(line, decoded)
                    guard let message = decoded else { return }
                    if case .malformed = message { outcome.malformedCount += 1 }
                    // Fatal errors are always kept: the runner reads them back to
                    // build the failure message when the exit code is bad.
                    if keepMessages { outcome.messages.append(message) }
                    else if case .exitError = message { outcome.messages.append(message) }
                    onMessage?(message)
                }

                let pipeFD = box.fileDescriptor
                let wakeupFD = wakeup.fileHandleForReading.fileDescriptor
                // Whatever one 64 KB read brings in gets line-split by
                // `absorb`; both the running loop and the abandonment drain
                // below go through it.
                func absorb(_ chunk: Data) {
                    onActivity?()
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex ..< newline]
                        buffer.removeSubrange(buffer.startIndex ... newline)
                        if let line = String(data: lineData, encoding: .utf8) {
                            consume(line)
                        } else {
                            // A line that is not valid UTF-8 cannot decode as
                            // restic JSON — count it as the reporting gap it
                            // is, exactly like a known message with a bad
                            // payload, rather than dropping it silently.
                            outcome.malformedCount += 1
                        }
                    }
                }

                loop: while true {
                    // Wait for either the pipe or the abandonment signal. An
                    // EINTR must restart the poll, not read as readiness.
                    var fds = [pollfd(fd: pipeFD, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: wakeupFD, events: Int16(POLLIN), revents: 0)]
                    while true {
                        let count = Darwin.poll(&fds, 2, -1)
                        if count < 0, errno == EINTR { continue }
                        break
                    }
                    if fds[1].revents != 0 {
                        // Abandoned: the child's death plus `grandchildGrace`
                        // proved someone else is holding the pipe. Drain the
                        // signal byte, then take whatever the pipe still
                        // holds readable *right now* — the reaper only fires
                        // after the child died, so this is the run's last
                        // bytes, never live output. A zero-timeout poll
                        // bounds the drain: nothing readable means a
                        // grandchild still owns the write end, and a plain
                        // read here would block on it exactly as before.
                        var sink = [UInt8](repeating: 0, count: 16)
                        _ = Darwin.read(wakeupFD, &sink, sink.count)
                        while true {
                            var readable = [pollfd(fd: pipeFD, events: Int16(POLLIN), revents: 0)]
                            let ready = Darwin.poll(&readable, 1, 0)
                            if ready <= 0 || readable[0].revents == 0 { break }
                            let chunk = box.read(upToCount: 64 * 1024)
                            if chunk.isEmpty { break }
                            absorb(chunk)
                        }
                        break loop
                    }
                    if fds[0].revents == 0 { continue }

                    let chunk = box.read(upToCount: 64 * 1024)
                    if chunk.isEmpty { break }
                    absorb(chunk)
                }
                if !buffer.isEmpty {
                    if let line = String(data: buffer, encoding: .utf8) {
                        consume(line)
                    } else {
                        outcome.malformedCount += 1
                    }
                }
                box.close()
                markFinished()
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

    /// The descriptor behind the handle — `StreamReader.poll`s it alongside
    /// the abandonment wakeup, then reads it raw below.
    var fileDescriptor: Int32 { handle.fileDescriptor }

    /// Raw `read(2)` on the descriptor, not `FileHandle.read(upToCount:)`:
    /// Foundation's read buffers on pipes, so `FileHandle.read` would deliver
    /// restic's status lines only at process exit — a progress bar stuck at
    /// 0% instead of one that moves.
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
