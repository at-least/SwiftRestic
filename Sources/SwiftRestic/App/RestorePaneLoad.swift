import Foundation

/// The Backups tab's load of one backup: its tree does not wait for the
/// comparison with the previous backup. `restic diff` runs beside the
/// listing, and its marks are shown whole, once, when it ends.
enum RestorePaneLoad {
    /// What the Change column shows.
    struct Marks: Equatable {
        var changes: [String: ResticDiffChange]
        var changesInside: [String: ChangesInside]
        var comparison: ChangeComparison
    }

    /// `show` first gets the blank column of a comparison under way (or of
    /// a first backup, `baseline` nil), then — unless the task was
    /// cancelled, a record switch — the comparison's marks.
    @MainActor
    static func run(
        baseline: Snapshot?,
        compare: @escaping @MainActor (Snapshot) async -> ChangeMarks,
        listTree: @MainActor () async -> Void,
        show: @MainActor (Marks) -> Void
    ) async {
        show(Marks(
            changes: [:],
            changesInside: [:],
            comparison: baseline.map { .comparing(baseline: $0) } ?? .firstBackup
        ))
        async let marks = comparing(baseline, compare)
        await listTree()
        guard let baseline, let marks = await marks else { return }
        guard !Task.isCancelled else { return }
        show(compared(marks, baseline: baseline))
    }

    /// The folders the load opens, in order: every root (the user's call:
    /// roots open by default), then the walk to the folder the user was in.
    /// A root on that walk is left to the walk — opening is a toggle, so a
    /// second open would close it — and the walk goes last so its end is
    /// the deepest folder opened.
    static func foldersToOpen(roots: [String], spine: [String]) -> [String] {
        roots.filter { !spine.contains($0) } + spine
    }

    @MainActor
    private static func comparing(
        _ baseline: Snapshot?,
        _ compare: @MainActor (Snapshot) async -> ChangeMarks
    ) async -> ChangeMarks? {
        guard let baseline else { return nil }
        return await compare(baseline)
    }

    static func compared(_ marks: ChangeMarks, baseline: Snapshot) -> Marks {
        let held = ChangeComparison.heldChanges(marks.changes)
        return Marks(
            changes: held,
            changesInside: ChangeComparison.changesInside(held),
            comparison: marks.failure.map { .failed(baseline: baseline, reason: $0) }
                ?? .compared(baseline: baseline, changeCount: held.count)
        )
    }
}
