import Foundation

/// Runs work one call at a time, in call order: each call's work starts once
/// every earlier call's work has finished, and the call returns when its own
/// has. The model's configuration writes and its login-item changes each go
/// through one.
///
/// A chain, not a wait loop on a shared handle: with two overlapping
/// calls, such a loop awaits an already-finished task, which returns
/// without suspending, and spins the main actor forever.
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
