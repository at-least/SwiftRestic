import Foundation
import Testing

/// The run census the quit path drains.
///
/// The registry is the structural replacement for hand-maintained task
/// dictionaries, and `shutdown` leans on one property: when `drain` returns,
/// everything it was tracking — including anything that landed while it was
/// draining — has finished unwinding, so the final save cannot race a run
/// record into existence.
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

        // A is in the registry when drain begins. It signals that drain must
        // now be suspended awaiting it, then holds well past B's lifetime.
        let aSlot = TaskRegistry.Slot.plan(UUID())
        registry.install(Task {
            flags.mark("a-started")
            try? await Task.sleep(for: .milliseconds(500))
            flags.mark("a")
            registry.clear(aSlot)
        }, in: aSlot)

        // B lands while drain is suspended on A, and outlives A by a wide
        // margin — the old single-pass drain returned the moment A finished
        // and dropped B un-awaited.
        Task {
            while !flags.isMarked("a-started") {
                try? await Task.sleep(for: .milliseconds(5))
            }
            try? await Task.sleep(for: .milliseconds(200))
            let bSlot = TaskRegistry.Slot.plan(UUID())
            registry.install(Task {
                try? await Task.sleep(for: .milliseconds(500))
                flags.mark("b")
                registry.clear(bSlot)
            }, in: bSlot)
        }

        await registry.drain()

        #expect(flags.isMarked("a"))
        #expect(flags.isMarked("b"))
    }
}
