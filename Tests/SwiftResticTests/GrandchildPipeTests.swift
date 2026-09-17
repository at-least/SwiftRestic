import Foundation
import Testing

/// The grandchild-pipe hang: a shell hook that backgrounds a long-lived
/// command (`curl ... &`) leaves the command holding the pipes' write end
/// after the shell itself is gone, and no signal of ours reaches it. Before
/// the reaper, `run` blocked on the reader's EOF for the grandchild's whole
/// lifetime — the hook's timeout never answered, a cancel never returned, and
/// quit's `terminateAll` hung the drain. Raw scripts rather than `StubRestic`
/// — the pipe inheritance is the behaviour under test.
@Suite("restic runner grandchild pipes", .serialized)
struct GrandchildPipeTests {
    /// Each case gets its own sleep duration so the deferred cleanup kills
    /// this case's orphan only — the grandchild is never signalled by us (no
    /// signal can reach it; that is the point), so it must be reaped manually.
    private func installScript(_ body: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticGrandchild-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("script.sh")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func killOrphan(matching marker: String) {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", marker]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()
    }

    /// The hook shape: the shell earns its exit immediately, but the
    /// backgrounded command holds the pipe for `sleep 291` seconds. The run
    /// must still answer — promptly, with the exit the shell earned — not
    /// ride along with the grandchild.
    @Test("a backgrounded grandchild cannot outlive a finished hook's answer")
    func finishedChildIsNotHeldByGrandchild() async throws {
        let script = try installScript("""
            echo '{"message_type":"status","percent_done":0}'
            sleep 291 &
            exit 0
            """)
        defer {
            try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
            killOrphan(matching: "sleep 291")
        }

        let start = Date()
        let result = try await ResticRunner().run(
            binary: script,
            invocation: ResticInvocation(arguments: [], timeout: 1)
        )
        let elapsed = Date().timeIntervalSince(start)
        // Child's own lifetime plus the reaper's grace, with room for a
        // loaded test host — but never the grandchild's 291 seconds.
        #expect(elapsed < 30, "run took \(elapsed)s; the grandchild is holding the pipes")
        #expect(result.exitCode == 0)
    }

    /// The watchdog shape: the shell is still alive under its cap, gets
    /// SIGTERM'd, and its orphaned job keeps the pipe open. The run must end
    /// as `timedOut` on the child's death plus the reaper's grace.
    @Test("a timed-out child's orphaned job cannot hold the run open")
    func timedOutChildIsNotHeldByGrandchild() async throws {
        let script = try installScript("""
            echo '{"message_type":"status","percent_done":0}'
            sleep 292 &
            wait
            """)
        defer {
            try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
            killOrphan(matching: "sleep 292")
        }

        let start = Date()
        do {
            _ = try await ResticRunner().run(
                binary: script,
                invocation: ResticInvocation(arguments: [], timeout: 1)
            )
            Issue.record("the capped run should have been stopped by the timeout")
        } catch let error as ResticError {
            guard case .timedOut = error else {
                Issue.record("expected timedOut, got \(error)")
                return
            }
            let elapsed = Date().timeIntervalSince(start)
            #expect(elapsed < 30, "run took \(elapsed)s; the grandchild is holding the pipes")
        }
    }

    /// Cancelling a run whose child is alive, with an orphaned job holding
    /// the pipe, must return as cancelled instead of blocking the reader.
    @Test("cancelling a run answers even when a grandchild holds the pipes")
    func cancelledRunIsNotHeldByGrandchild() async throws {
        let script = try installScript("""
            echo '{"message_type":"status","percent_done":0}'
            sleep 293 &
            wait
            """)
        defer {
            try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
            killOrphan(matching: "sleep 293")
        }

        let runner = ResticRunner()
        let task = Task {
            try? await runner.run(binary: script, invocation: ResticInvocation(arguments: []))
        }
        // Let the hang establish: the child is in `wait`, the grandchild holds.
        try? await Task.sleep(for: .seconds(1))
        let start = Date()
        task.cancel()
        _ = await task.value
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 30, "cancel took \(elapsed)s to answer; the grandchild is holding the pipes")
        await runner.terminateAll()
    }
}
