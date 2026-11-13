import Foundation

/// From restic's `forget --dry-run` answer, not projected.
struct RetentionPreview: Sendable, Equatable {
    var kept: [Snapshot]
    /// Newest first.
    var removed: [Snapshot]

    /// restic writes an empty list as `null` (a Go nil slice).
    private struct Group: Decodable {
        var keep: [Snapshot]?
        var remove: [Snapshot]?
    }

    init(kept: [Snapshot], removed: [Snapshot]) {
        self.kept = kept
        self.removed = removed
    }

    /// A tag that matches nothing prints nothing (not `[]`): an empty
    /// preview. Undecodable output throws: "nothing would be removed" is a
    /// claim about the user's history.
    init(forgetOutput: String) throws {
        let groups: [Group]
        do {
            groups = try ResticMessageDecoder.decodeArray(Group.self, from: forgetOutput)
        } catch {
            throw ResticError.malformedOutput(
                                detail: "couldn’t read which backups would be removed"
            )
        }
        self.init(
            kept: groups.flatMap { $0.keep ?? [] }.sorted(by: SnapshotLineage.newestFirst),
            removed: groups.flatMap { $0.remove ?? [] }.sorted(by: SnapshotLineage.newestFirst)
        )
    }

    /// What the history becomes, never what goes: nothing is removed yet.
    var outcomeLine: String {
        let total = kept.count + removed.count
        guard total > 0 else { return "This plan has no backups in this location yet." }
        if removed.isEmpty {
            return total == 1 ? "The backup stays." : "All \(Format.plural(total, "backup")) stay."
        }
        return "At the next backup, \(Format.plural(total, "backup")) become \(kept.count)."
    }
}
