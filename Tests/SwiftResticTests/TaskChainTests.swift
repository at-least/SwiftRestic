import Foundation
import Testing

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

@Suite("task chain")
@MainActor
struct TaskChainTests {
    @MainActor
    final class Trace {
        var order: [Int] = []
        var running = 0
        var mostAtOnce = 0
    }

    @Test("overlapping calls run one at a time, in call order, and all return")
    func overlappingCallsSettleInOrder() async {
        let watchdog = HangWatchdog(seconds: 10, "three overlapping TaskChain calls never returned — the main actor is spinning")
        defer { watchdog.disarm() }
        let chain = TaskChain()
        let trace = Trace()

        let calls = (1 ... 3).map { index in
            Task { @MainActor in
                await chain.run {
                    trace.running += 1
                    trace.mostAtOnce = max(trace.mostAtOnce, trace.running)
                    // Suspends, so the later calls are queued while it runs.
                    try? await Task.sleep(for: .milliseconds(20))
                    trace.order.append(index)
                    trace.running -= 1
                }
            }
        }
        for call in calls { await call.value }

        #expect(trace.order == [1, 2, 3])
        #expect(trace.mostAtOnce == 1)
        #expect(chain.isIdle)
    }

    @Test("a call made after the chain went idle runs at once")
    func idleChainRunsImmediately() async {
        let chain = TaskChain()
        let trace = Trace()
        await chain.run { trace.order.append(1) }
        #expect(chain.isIdle)
        await chain.run { trace.order.append(2) }
        #expect(trace.order == [1, 2])
        #expect(chain.isIdle)
    }
}
