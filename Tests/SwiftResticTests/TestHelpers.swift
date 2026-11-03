import Foundation
import Testing

/// A deterministic pseudo-random generator (SplitMix64), so a property failure
/// reproduces exactly: the seed in the test is the whole input.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Ends the test process when an `await` never comes back. A main actor that
/// spins never returns to the test, so no in-process timeout can fire; this
/// watchdog runs on its own thread and turns the hang into a crash naming
/// it, which xcodebuild reports (and `./build.sh test` fails on).
final class HangWatchdog: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)

    init(seconds: Int, _ message: String) {
        let done = done
        Thread.detachNewThread {
            if done.wait(timeout: .now() + .seconds(seconds)) == .timedOut {
                fatalError("HangWatchdog: \(message)")
            }
        }
    }

    func disarm() { done.signal() }
}

/// Runs on the caller's actor, so a main-actor test may read main-actor state.
func eventually(
    within seconds: Double,
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// A TCP socket listening on a free loopback port. The kernel completes a
/// connection's handshake into the accept queue, so it answers without an
/// accept loop.
enum LocalPort {
    struct Error: Swift.Error { var call: String }

    static func listening() throws -> (socket: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error(call: "socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); throw Error(call: "bind/listen") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { close(fd); throw Error(call: "getsockname") }
        return (fd, UInt16(bigEndian: address.sin_port))
    }
}

/// `label` names the suite so a leaked directory stays attributable; the
/// caller removes the script's directory.
func writeExecutableScript(
    _ body: String,
    label: String,
    named name: String = "script.sh"
) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftRestic\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = root.appendingPathComponent(name)
    try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

extension PlanActivity {
    /// A run of `plan` as `installPlanActivity` records it, for a test that
    /// sets the strip by hand.
    init(of plan: BackupPlan, phase: Phase = .starting, startedAt: Date = .now) {
        guard let repositoryID = plan.repositoryID else { preconditionFailure("a run is of a plan with a repository") }
        self.init(
            repositoryID: repositoryID,
            planName: plan.label(among: [plan]),
            phase: phase,
            startedAt: startedAt
        )
    }

    /// A run for a presentation test, which reads neither its repository
    /// nor its plan's name.
    init(phase: Phase = .starting) {
        self.init(repositoryID: UUID(), planName: "", phase: phase)
    }
}
