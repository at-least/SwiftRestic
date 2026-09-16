import Foundation

/// The model's bookkeeping for in-flight work: named slots for the runs that
/// own their identity (one per plan, one per repository's maintenance, the
/// single restore) and an unnamed lane for fire-and-forget sends (the start
/// pings) that quitting must still drain.
///
/// This replaces the hand-maintained task dictionaries whose every entry
/// `shutdown()` had to enumerate by hand — the census is now structural:
/// cancel everything, await everything, and no future run kind can be
/// forgotten from the quit path by omission. All access is main-actor, like
/// the tasks it tracks.
@MainActor
final class TaskRegistry {
    enum Slot: Hashable {
        case plan(UUID)
        case maintenance(UUID)
        case restore
    }

    private var slots: [Slot: Task<Void, Never>] = [:]

    // MARK: - Slots

    /// Whether the slot already holds a run — the one-at-a-time guard the
    /// run kinds apply to themselves.
    func isOccupied(_ slot: Slot) -> Bool {
        slots[slot] != nil
    }

    func task(in slot: Slot) -> Task<Void, Never>? {
        slots[slot]
    }

    /// Stores a run in its slot, replacing nothing: callers guard with
    /// `isOccupied` first, and a silent replace would let two runs for one
    /// plan race over who nils the slot.
    func install(_ task: Task<Void, Never>, in slot: Slot) {
        precondition(slots[slot] == nil, "run slot \(slot) already occupied")
        slots[slot] = task
    }

    /// Cancels the slot's run, if any.
    func cancel(_ slot: Slot) {
        slots[slot]?.cancel()
    }

    /// Frees a finished run's slot. Only the run's own completion path calls
    /// this — the same owner who nils it today.
    func clear(_ slot: Slot) {
        slots[slot] = nil
    }

    // MARK: - Background lane

    /// A send that must not outlive the quit (a start ping arming a
    /// monitor's timer), but which nothing cancels individually.
    ///
    /// Keyed by token rather than appended to an array: entries reap
    /// themselves when their task completes (`Task.isCancelled` is false for
    /// a *finished* task, so an isCancelled sweep prunes nothing — the leak
    /// the old `pendingPings` array had).
    private var background: [UUID: Task<Void, Never>] = [:]

    func addBackground(_ task: Task<Void, Never>) {
        let token = UUID()
        background[token] = task
        Task { [weak self] in
            _ = await task.value
            self?.background[token] = nil
        }
    }

    // MARK: - Census

    /// Cancels every slotted run. Used by `shutdown`; the runs themselves
    /// unwind and write their own records. Deliberately not the background
    /// lane: a start ping already in flight is awaited, never aborted — its
    /// monitor must hear that the run started, even one that quit stopped.
    func cancelSlots() {
        for task in slots.values { task.cancel() }
    }

    /// Awaits every tracked task, then empties the registry. Cancellation is
    /// the caller's job (terminateAll has to reach the restic children
    /// before their Swift-side tasks can finish unwinding).
    ///
    /// The census holds for the duration because `shutdown` is re-entry
    /// guarded and the scheduler — the only source of new runs at quit — is
    /// cancelled first; anything installed after this loop begins would be
    /// dropped un-awaited, so that ordering is load-bearing.
    func drain() async {
        for task in slots.values { await task.value }
        for task in background.values { await task.value }
        slots.removeAll()
        background.removeAll()
    }
}
