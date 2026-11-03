import Foundation
import Testing

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
