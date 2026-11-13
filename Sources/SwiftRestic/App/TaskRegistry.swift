import Foundation

/// Every in-flight task the quit path must cancel and await: named slots for
/// runs that own an identity, and an unnamed lane for fire-and-forget sends
/// (start pings). Registering here is what keeps a run kind from being
/// forgotten by the quit path.
@MainActor
final class TaskRegistry {
    enum Slot: Hashable {
        case plan(UUID)
        case maintenance(UUID)
        case restore
    }

    private var slots: [Slot: Task<Void, Never>] = [:]

    /// The one-at-a-time guard each run kind applies to itself.
    func isOccupied(_ slot: Slot) -> Bool {
        slots[slot] != nil
    }

    func task(in slot: Slot) -> Task<Void, Never>? {
        slots[slot]
    }

    /// Callers guard with `isOccupied` first: a silent replace would let two
    /// runs for one plan race over who nils the slot.
    func install(_ task: Task<Void, Never>, in slot: Slot) {
        precondition(slots[slot] == nil, "run slot \(slot) already occupied")
        slots[slot] = task
    }

    func cancel(_ slot: Slot) {
        slots[slot]?.cancel()
    }

    /// Only the run's own completion path calls this.
    func clear(_ slot: Slot) {
        slots[slot] = nil
    }

    /// Sends the quit awaits but nothing cancels individually.
    ///
    /// Keyed by token rather than appended to an array: entries reap
    /// themselves when their task completes. An `isCancelled` sweep would
    /// prune nothing: it is false for a finished task.
    private var background: [UUID: Task<Void, Never>] = [:]

    func addBackground(_ task: Task<Void, Never>) {
        let token = UUID()
        background[token] = task
        Task { [weak self] in
            _ = await task.value
            self?.background[token] = nil
        }
    }

    /// Not the background lane: a start ping in flight is awaited, never
    /// aborted — its monitor must hear that the run started, even one that
    /// quit stopped.
    func cancelSlots() {
        for task in slots.values { task.cancel() }
    }

    /// Awaits until both lanes are empty. Cancelling is the caller's job:
    /// the restic children must be terminated before their Swift tasks can
    /// unwind.
    ///
    /// A loop, not one pass: a task installed while the awaits are suspended
    /// is caught by the next pass. Each pass removes exactly the entries it
    /// awaited, so a fresh install survives to the next pass.
    func drain() async {
        while !slots.isEmpty || !background.isEmpty {
            let awaitedSlots = Array(slots.values)
            let awaitedBackground = Array(background.values)
            for task in awaitedSlots { await task.value }
            for task in awaitedBackground { await task.value }
            slots = slots.filter { !awaitedSlots.contains($0.value) }
            background = background.filter { !awaitedBackground.contains($0.value) }
        }
    }
}
