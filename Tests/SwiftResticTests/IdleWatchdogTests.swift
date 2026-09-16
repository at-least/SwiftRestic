import Foundation
import Testing

/// The stall cap (`ResticInvocation.idleTimeout`): a child that reports
/// continuously may run as long as it likes, a child that goes silent is
/// killed as hung and reported as `ResticError.idleStalled`. Raw scripts
/// rather than `StubRestic` — the timing is the behaviour under test.
@Suite("restic runner stall cap", .serialized)
struct IdleWatchdogTests {
    private func installScript(_ body: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticIdle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("script.sh")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    @Test("a child that goes silent is killed as hung, not timed out")
    func idleCapKillsSilentChild() async throws {
        // One line, then nothing: what a network-black-holed backup looks
        // like from the pipe's side. The trap form forwards the runner's
        // SIGTERM to the sleep, so nothing outlives the test.
        let script = try installScript("""
            echo '{"message_type":"status","percent_done":0}'
            trap 'kill -TERM "$child" 2>/dev/null' TERM
            sleep 30 &
            child=$!
            wait "$child"
            exit 0
            """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let runner = ResticRunner()
        do {
            _ = try await runner.run(
                binary: script,
                invocation: ResticInvocation(arguments: [], idleTimeout: 1)
            )
            Issue.record("the silent child should have been stopped by the stall cap")
        } catch let error as ResticError {
            guard case let .idleStalled(seconds, _) = error else {
                Issue.record("expected idleStalled, got \(error)")
                return
            }
            #expect(seconds == 1)
        }
    }

    @Test("a child that keeps reporting is never stopped by the stall cap")
    func idleCapSparesChattyChild() async throws {
        // ~2.8 s of a line every 0.35 s under a 1.5 s cap: each line resets
        // the clock with ~4x margin, so the run must outlive the cap and
        // finish on its own. The margin is deliberate — a loaded test host
        // stretches the shell's sleeps, and a 2.5x margin once let two
        // stacked gaps trip the cap in CI.
        let script = try installScript("""
            i=0
            while [ $i -lt 8 ]; do
                echo '{"message_type":"status","percent_done":0.5}'
                sleep 0.35
                i=$((i+1))
            done
            exit 0
            """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let result = try await ResticRunner().run(
            binary: script,
            invocation: ResticInvocation(arguments: [], idleTimeout: 1.5)
        )
        #expect(result.exitCode == 0)
    }
}
