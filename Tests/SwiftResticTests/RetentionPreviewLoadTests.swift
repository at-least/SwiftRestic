import Foundation
import Testing

/// The dry-run loader both retention surfaces share (`RetentionPreviewLoad`):
/// the answer, the failure that replaces it, and the cancelled attempt that
/// leaves the state to its successor.
@MainActor
@Suite("Retention preview load")
struct RetentionPreviewLoadTests {
    private struct Refused: LocalizedError {
        var errorDescription: String? { "the repository did not answer" }
    }

    @Test("a completing attempt sets the answer and ends the load")
    func completingAttempt() async {
        let load = RetentionPreviewLoad()
        let answer = RetentionPreview(kept: [], removed: [])
        await load.load { answer }
        #expect(load.result == answer)
        #expect(load.failure == nil)
        #expect(!load.isLoading)
    }

    @Test("a throwing attempt sets the failure and clears the answer")
    func throwingAttempt() async {
        let load = RetentionPreviewLoad()
        await load.load { RetentionPreview(kept: [], removed: []) }
        await load.load { throw Refused() }
        #expect(load.failure == "the repository did not answer")
        #expect(load.result == nil)
        #expect(!load.isLoading)
    }

    @Test("a cancelled attempt leaves the state to its successor")
    func cancelledAttempt() async throws {
        let load = RetentionPreviewLoad()
        // Attempt A hangs inside its fetch until the test resumes it.
        let (held, holdA) = AsyncStream<CheckedContinuation<Void, Never>>.makeStream()
        let attemptA = Task {
            await load.load {
                await withCheckedContinuation { holdA.yield($0) }
                throw Refused()
            }
        }
        var suspended: CheckedContinuation<Void, Never>?
        for await continuation in held { suspended = continuation; break }
        holdA.finish()

        // Attempt B, the successor, runs to completion while A hangs.
        let answer = RetentionPreview(kept: [], removed: [])
        await load.load { answer }
        #expect(load.result == answer)

        attemptA.cancel()
        suspended?.resume()
        await attemptA.value
        #expect(load.result == answer)
        #expect(load.failure == nil)
        #expect(!load.isLoading)
    }
}
