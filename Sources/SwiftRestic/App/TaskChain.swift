import Foundation

/// Runs work one call at a time, in call order: each call's work starts once
/// every earlier call's work has finished, and the call returns when its own
/// has. The model's configuration writes and its login-item changes each go
/// through one.
///
/// A chain rather than a wait loop. The loop both used —
/// `while let inFlight = handle { await inFlight.value }`, the owner clearing
/// the handle after its own await — spun the main actor at full CPU for
/// good once two calls overlapped: the waiter queued last was woken first,
/// found the handle still set, and awaited a task that had already
/// finished, which returns without suspending, so the owner never ran again
/// to clear it (the final review's probes: two overlapping `flushSave` or
/// `setStartsAtLogin` calls never settled, 99.7% CPU).
@MainActor
final class TaskChain {
    /// The newest call's task while it runs or waits; nil once the chain is
    /// idle.
    private var tail: Task<Void, Never>?

    var isIdle: Bool { tail == nil }

    func run(_ work: @escaping @MainActor @Sendable () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        tail = task
        await task.value
        // A later call queued behind this one owns the handle now.
        if tail == task { tail = nil }
    }
}
