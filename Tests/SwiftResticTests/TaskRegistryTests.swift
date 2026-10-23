import Foundation
import Testing

/// The run census the quit path drains.
///
/// `shutdown` leans on one property: when `drain` returns, everything it
/// was tracking — including anything that landed while it was draining —
/// has finished unwinding, so the final save cannot race a run record into
/// existence.
@Suite("Task registry")
@MainActor
struct TaskRegistryTests {
    /// Flag box the tracked tasks write from their own suspension points and
    /// the assertions read after `drain` returns.
    private final class Flags: @unchecked Sendable {
        private let lock = NSLock()
        private var marked: Set<String> = []

        func mark(_ name: String) {
            lock.lock()
            marked.insert(name)
            lock.unlock()
        }

        func isMarked(_ name: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return marked.contains(name)
        }
    }

    @Test("drain awaits every task installed before it began")
    func drainAwaitsInstalledTasks() async {
        let registry = TaskRegistry()
        let flags = Flags()
        for name in ["a", "b"] {
            let slot = TaskRegistry.Slot.plan(UUID())
            registry.install(Task {
                try? await Task.sleep(for: .milliseconds(20))
                flags.mark(name)
                registry.clear(slot)
            }, in: slot)
        }

        await registry.drain()

        #expect(flags.isMarked("a") && flags.isMarked("b"))
    }

    @Test("drain keeps draining until a task installed mid-drain has finished")
    func drainAwaitsTaskInstalledAfterItBegan() async {
        let registry = TaskRegistry()
        let flags = Flags()

        // A is in the registry when drain begins, and finishes only once B
        // is installed — a handoff, so B lands while drain is suspended on A
        // however load stretches the clocks.
        let aSlot = TaskRegistry.Slot.plan(UUID())
        registry.install(Task {
            while !flags.isMarked("b-installed") {
                try? await Task.sleep(for: .milliseconds(5))
            }
            flags.mark("a")
            registry.clear(aSlot)
        }, in: aSlot)

        // B outlives A: a drain that stopped once A finished would drop B
        // un-awaited.
        Task {
            let bSlot = TaskRegistry.Slot.plan(UUID())
            registry.install(Task {
                try? await Task.sleep(for: .milliseconds(500))
                flags.mark("b")
                registry.clear(bSlot)
            }, in: bSlot)
            flags.mark("b-installed")
        }

        await registry.drain()

        #expect(flags.isMarked("a"))
        #expect(flags.isMarked("b"))
    }
}
