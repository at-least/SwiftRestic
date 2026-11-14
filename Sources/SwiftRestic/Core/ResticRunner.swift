import Foundation

struct ResticInvocation: Sendable {
    var arguments: [String]
    var environment: [String: String] = [:]
    /// `backup` adds 3: "finished, but some files could not be read". `nil`
    /// accepts any code, for callers that read the exit status themselves.
    var allowedExitCodes: Set<Int32>? = [0]
    var timeout: TimeInterval?
    /// A stall cap: every received chunk resets the clock. For commands that
    /// stream NDJSON while they work (`backup`, `restore`, the index walks)
    /// silence means a hung child, while a total cap would kill slow work.
    /// Commands silent for long stretches (`prune`, `forget`, the console's
    /// `runRaw`) must not set it.
    var idleTimeout: TimeInterval?
    /// For commands that answer with one big JSON array (`snapshots`,
    /// `stats`, `forget`) rather than a line-per-event stream.
    var retainFullOutput: Bool = false
    /// Off for unbounded streams — a `diff` of two home-folder snapshots is
    /// hundreds of thousands of lines — where the caller collects through
    /// `onMessage` under a cap of its own.
    var retainMessages: Bool = true

    /// Leaves the environment out, so the password stays out. Shell-style
    /// quoting keeps a path with spaces one word.
    fileprivate var displayCommand: String {
        CommandLineTokenizer.render(["restic"] + arguments)
    }
}

struct ResticRunResult: Sendable {
    var exitCode: Int32
    var messages: [ResticMessage]
    var stdout: String
    var stderr: String
    /// Lines with a known `message_type` whose payload failed to decode, plus
    /// lines that are not UTF-8. The run record reports it, so a restic
    /// schema change shows up as a count.
    var malformedCount: Int = 0

    private var exitError: ResticExitError? {
        for message in messages.reversed() {
            if case let .exitError(error) = message { return error }
        }
        return nil
    }

    /// restic's JSON fatal-error line, else the tail of stderr. Under
    /// `--json` the fatal line can lose the cause: what ssh said reaches
    /// stderr only as plain lines prefixed "subprocess " ("subprocess ssh:
    /// Host key verification failed.", restic 0.19.1), so the last three of
    /// those follow — ssh's verdict comes after a banner of a dozen lines.
    var failureMessage: String {
        guard let fatal = exitError?.message else { return ResticRunner.tail(of: stderr, limit: 2000) }
        let lines = stderr.split(separator: "\n")
        let subprocess = lines.filter { $0.hasPrefix("subprocess ") }.suffix(3).map(String.init)
        return ([Self.withoutGoStackTrace(fatal)] + subprocess).joined(separator: "\n")
    }

    /// From restic's last "… returned error, retrying after …" stderr line:
    /// "Stat(<config/>) returned error, retrying after 38.6s: Head
    /// "http://…/config": dial tcp 127.0.0.1:18000: connect: connection
    /// refused" gives "connection refused".
    fileprivate static func retryCause(in stderr: String) -> String {
        guard let line = stderr.split(separator: "\n").last(where: { $0.contains(" returned error, retrying after ") }) else { return "" }
        return line.components(separatedBy: ": ").last ?? ""
    }

    /// restic 0.19.1 appends a Go stack to an error that is not one of its
    /// fatal ones (`%+v` in its main.go): "failed to remove one or more
    /// snapshots\nmain.init\n\tgithub.com/restic/restic/cmd/restic/
    /// cmd_forget.go:67\n…". The message ends before the first frame, a line
    /// followed by a tab-indented "….go:<line>". The run's log keeps it all.
    private static func withoutGoStackTrace(_ message: String) -> String {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        for index in lines.indices.dropLast() {
            let next = lines[index + 1]
            if next.hasPrefix("\t"), next.range(of: #"\.go:\d+$"#, options: .regularExpression) != nil {
                return lines[..<index].joined(separator: "\n")
            }
        }
        return message
    }

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

/// Runs restic and decodes its NDJSON into `ResticMessage` values; lines
/// that are not restic JSON decode to nothing. Methods suspend rather than
/// block, so a snapshot listing during a backup is not queued behind it.
actor ResticRunner {
    /// Between SIGTERM and SIGKILL: long enough for restic to flush, short
    /// enough that a quit waiting on the child stays bearable.
    static let killGrace: TimeInterval = 5

    /// A run ends at most this long after its child dies. A healthy pipe
    /// reaches EOF within milliseconds of the exit; when it does not, a
    /// grandchild holds the write end (restic's backend child after a
    /// SIGKILL), and the readers abandon the pipes. The grandchild's later
    /// writes get EPIPE, which usually ends it too.
    private static let grandchildGrace: TimeInterval = 2

    private var running: [UUID: ProcessBox] = [:]
    /// Set by `terminateAll`: quit's drain must not wait on a child that a
    /// still-running task launches after it (a listing's size read began
    /// after `terminateAll` ran out the 300 s refresh timeout).
    private var isStopped = false

    /// - Parameter onMessage: off the main actor.
    /// - Parameter onRawLine: every line of both streams before decoding
    ///   (the plain-text progress `prune` prints). Off the main actor, the
    ///   two streams concurrently and unordered. No back-pressure, so
    ///   unbounded streams (backup, diff) must not pass it.
    ///
    /// A bound `RunTranscript` gets the command line, every line and the
    /// exit code; a child stopped by a cancel or a cap leaves a note
    /// instead, because a signal's termination status is not an exit code.
    func run(
        binary: URL,
        invocation: ResticInvocation,
        onMessage: (@Sendable (ResticMessage) -> Void)? = nil,
        onRawLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ResticRunResult {
        let handle = UUID()
        // Read here in the caller's task: the pipe readers run on GCD
        // threads, where task-locals are not visible.
        let transcript = RunTranscript.current
        let process = Process()
        process.executableURL = binary
        process.arguments = invocation.arguments
        process.environment = Self.baseEnvironment().merging(invocation.environment) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // A backend that prompts (an SFTP host-key confirmation) fails fast
        // instead of hanging on a stdin that never answers.
        process.standardInput = FileHandle.nullDevice

        let box = ProcessBox(process)
        let exit = ExitWaiter()
        process.terminationHandler = { finished in
            exit.complete(finished.terminationStatus)
        }

        // Before launch, so a quit racing the spawn cannot miss the child. A
        // terminate before launch is a no-op (not yet running).
        guard !isStopped else {
            transcript?.note("Stopped")
            throw ResticError.cancelled
        }
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

        // Polls once a second rather than re-arming a sleep per line, which
        // would churn tasks at restic's progress rate.
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

        // Any chunk on either pipe counts, complete line or not.
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

        // The reaper keeps every stop path (caps, cancellation, quit's
        // terminateAll) answerable when a grandchild holds a pipe open; no
        // signal of ours reaches it. It is the second waiter on `exit`.
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
                // restic writes its per-item `error` events and its
                // `exit_error` to stderr, so stderr is decoded too.
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
            transcript?.note("Stopped")
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

        transcript?.exited(exitCode)

        if let allowed = invocation.allowedExitCodes, !allowed.contains(exitCode) {
            throw ResticError.commandFailed(
                exitCode: exitCode,
                message: result.failureMessage
            )
        }

        return result
    }

    /// Every later `run` throws `ResticError.cancelled` without launching.
    func terminateAll() {
        isStopped = true
        for box in running.values { box.terminate() }
    }

    /// stderr's events follow stdout's, so a backup's per-item errors land
    /// after its summary. Every consumer reads one stream's events or looks
    /// up in reverse, so the cross-stream order is never relied on.
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

    /// Keys the app owns: the repository location and every form of the
    /// password. Inherited or extra-environment values would silently point
    /// restic at another repository or break authentication, so the runner
    /// strips them from the inherited environment and `RepositoryContext`
    /// from the repository's extra environment.
    ///
    /// RESTIC_REPOSITORY_FILE: restic 0.19.1 refuses it beside
    /// RESTIC_REPOSITORY ("Options -r and --repository-file are mutually
    /// exclusive"). RESTIC_HOST: would replace this Mac's name on every
    /// backup, which `ResticService.localHostname` assumes is
    /// gethostname(3); it also filters `snapshots`, `ls latest` and `forget`
    /// (0.19.1, probed), so overriding it with `backup --host` is not enough.
    static let protectedEnvironmentKeys: Set<String> = [
        "RESTIC_REPOSITORY", "RESTIC_REPOSITORY_FILE", "RESTIC_PASSWORD", "RESTIC_PASSWORD_FILE",
        "RESTIC_PASSWORD_COMMAND", "RESTIC_HOST",
    ]

    /// Where a Homebrew or MacPorts ssh lives, which an sftp location needs.
    private static let toolDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    /// A GUI app inherits a nearly empty environment, so PATH is rebuilt. It
    /// has no `SSH_AUTH_SOCK` and no terminal, so an SFTP repository's key
    /// must be passphrase-less or named in `~/.ssh/config`. Inherited
    /// repository and password variables would win over the app's (restic
    /// ranks PASSWORD_COMMAND and PASSWORD_FILE above PASSWORD), so they go.
    static func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in Self.protectedEnvironmentKeys {
            env.removeValue(forKey: key)
        }
        let extraPaths = toolDirectories + ["/bin", "/usr/sbin", "/sbin"]
        var merged = env["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        for path in extraPaths where !merged.contains(path) { merged.append(path) }
        env["PATH"] = merged.joined(separator: ":")
        // Progress comes from JSON; restic's own printer stays slow.
        env["RESTIC_PROGRESS_FPS"] = "1"
        return env
    }

    private static func transcriptFeed(
        _ transcript: RunTranscript?,
        stream: RunTranscript.Stream
    ) -> (@Sendable (String, ResticMessage?) -> Void)? {
        guard let transcript else { return nil }
        return { line, message in transcript.output(line, message: message, stream: stream) }
    }

    static func tail(of text: String, limit: Int) -> String {
        String(text.suffix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// `Process` is safe to `terminate()` from another thread but is not
/// annotated `Sendable`.
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var wasTimedOut = false
    private var wasIdleTimedOut = false
    /// `systemUptime`, not wall-clock: it pauses while the Mac sleeps, so a
    /// backup that survives a closed lid is not read as silent for the nap.
    private var lastActivity = ProcessInfo.processInfo.systemUptime

    init(_ process: Process) {
        self.process = process
    }

    func terminate(timeout: Bool = false, idleTimeout: Bool = false) {
        lock.lock()
        let running = process.isRunning
        // A child that exited on its own just before the cap fired reports
        // its own exit, not the cap.
        if timeout && running { wasTimedOut = true }
        if idleTimeout && running { wasIdleTimedOut = true }
        lock.unlock()
        guard running else { return }
        process.terminate()
        escalateToKill()
    }

    /// A child can decline SIGTERM (wedged in uninterruptible I/O), which
    /// would hang every cancel and the quit that drains them, so after
    /// `killGrace` it gets SIGKILL. Two racing terminates arm two
    /// escalations; `isRunning` makes the second a no-op.
    private func escalateToKill() {
        let identifier = process.processIdentifier
        guard identifier > 0 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(ResticRunner.killGrace))
            self?.killIfStillRunning(identifier)
        }
    }

    /// Synchronous because the lock must not be taken from an async context.
    private func killIfStillRunning(_ identifier: pid_t) {
        lock.lock()
        let running = process.isRunning
        lock.unlock()
        guard running else { return }
        kill(identifier, SIGKILL)
    }

    func ping() {
        lock.lock()
        lastActivity = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    var idleInterval: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastActivity
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasTimedOut
    }

    var idleTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasIdleTimedOut
    }
}

/// Two parties wait on one exit, `run` and the reaper, so the waiters are a
/// list: a single slot would strand the first caller's continuation.
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

/// Both pipes are drained concurrently: restic blocks on a full stderr
/// buffer while stdout is still being read.
///
/// The wait is a `poll` over the pipe and a wakeup pipe, not a blocking read:
/// on macOS, closing a descriptor another thread is blocked reading does not
/// wake it, so abandonment has no other way in.
private final class StreamReader: @unchecked Sendable {
    struct Outcome: Sendable {
        var messages: [ResticMessage] = []
        var text: String = ""
        var malformedCount: Int = 0
    }

    static let defaultTextLimit = 64 * 1024

    private let handle: FileHandleBox
    private let textLimit: Int
    private let retainMessages: Bool
    /// Every chunk, before line splitting.
    private let onActivity: (@Sendable () -> Void)?

    /// The write end stays open for the reader's lifetime, so the signal can
    /// always be delivered.
    private let wakeup: Pipe
    private let lock = NSLock()
    /// The loop ended, by EOF or by abandonment.
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

    /// Safe from any thread, any number of times.
    func abandon() {
        lock.lock()
        if finished || abandonSignalled {
            lock.unlock()
            return
        }
        abandonSignalled = true
        lock.unlock()
        var byte: UInt8 = 0x1
        _ = write(wakeup.fileHandleForWriting.fileDescriptor, &byte, 1)
    }

    private func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    /// - Parameter onLine: the run transcript's feed.
    func readAll(
        onMessage: (@Sendable (ResticMessage) -> Void)?,
        onRawLine: (@Sendable (String) -> Void)?,
        onLine: (@Sendable (String, ResticMessage?) -> Void)?
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
                    // utf8.count, not count: grapheme counting is O(n), per line.
                    if retained.utf8.count < limit { retained += line + "\n" }
                    let decoded = ResticMessageDecoder.decode(line: line)
                    onLine?(line, decoded)
                    guard let message = decoded else { return }
                    if case .malformed = message { outcome.malformedCount += 1 }
                    // `failureMessage` needs the exit error.
                    if keepMessages { outcome.messages.append(message) }
                    else if case .exitError = message { outcome.messages.append(message) }
                    onMessage?(message)
                }

                let pipeFD = box.fileDescriptor
                let wakeupFD = wakeup.fileHandleForReading.fileDescriptor
                func absorb(_ chunk: Data) {
                    onActivity?()
                    buffer.append(chunk)
                    // Removed once per chunk: removing per line moves the
                    // rest of the buffer each time.
                    var start = buffer.startIndex
                    while let newline = buffer[start...].firstIndex(of: 0x0A) {
                        let lineData = buffer[start ..< newline]
                        start = buffer.index(after: newline)
                        if let line = String(data: lineData, encoding: .utf8) {
                            consume(line)
                        } else {
                            outcome.malformedCount += 1
                        }
                    }
                    buffer.removeSubrange(buffer.startIndex ..< start)
                }

                loop: while true {
                    // EINTR restarts the poll; it is not readiness.
                    var fds = [pollfd(fd: pipeFD, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: wakeupFD, events: Int16(POLLIN), revents: 0)]
                    while true {
                        let count = Darwin.poll(&fds, 2, -1)
                        if count < 0, errno == EINTR { continue }
                        break
                    }
                    if fds[1].revents != 0 {
                        // Abandoned after the child died: take what is
                        // readable now. The zero-timeout poll bounds the
                        // drain; a plain read would block on the grandchild
                        // that still owns the write end.
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

/// `@unchecked Sendable`: one background queue touches each descriptor for
/// its whole lifetime.
private final class FileHandleBox: @unchecked Sendable {
    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }

    var fileDescriptor: Int32 { handle.fileDescriptor }

    /// Raw `read(2)`, not `FileHandle.read(upToCount:)`: Foundation buffers
    /// pipe reads and would deliver restic's status lines only at exit, a
    /// progress bar stuck at 0%.
    func read(upToCount count: Int) -> Data {
        var storage = [UInt8](repeating: 0, count: count)
        let bytesRead = storage.withUnsafeMutableBufferPointer { buffer -> Int in
            while true {
                let n = Darwin.read(handle.fileDescriptor, buffer.baseAddress, buffer.count)
                // EINTR is not EOF.
                if n < 0, errno == EINTR { continue }
                return n
            }
        }
        guard bytesRead > 0 else { return Data() }
        return Data(storage[0 ..< bytesRead])
    }

    func close() { try? handle.close() }
}
