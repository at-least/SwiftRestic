import Foundation

/// What a plan's retention rules would do right now, read from restic's own
/// `forget --dry-run` answer rather than projected.
struct RetentionPreview: Sendable, Equatable {
    var kept: [Snapshot]
    /// Newest first, like every other snapshot list.
    var removed: [Snapshot]

    /// One group of `forget --json`'s answer. restic writes an empty list as
    /// `null` (a Go nil slice): `remove` when nothing goes, `keep` when
    /// nothing stays.
    /// `reasons`, `host`, `paths` and `tags` are not needed: the plan's tag
    /// already scoped the command.
    private struct Group: Decodable {
        var keep: [Snapshot]?
        var remove: [Snapshot]?
    }

    init(kept: [Snapshot], removed: [Snapshot]) {
        self.kept = kept
        self.removed = removed
    }

    /// Reads `restic forget --json`. A tag that matches nothing makes restic
    /// print nothing at all (not `[]`), which is an empty preview; output
    /// that does not decode throws, like the real forget's count does —
    /// "nothing would be removed" is a claim about the user's history.
    init(forgetOutput: String) throws {
        let groups: [Group]
        do {
            groups = try ResticMessageDecoder.decodeArray(Group.self, from: forgetOutput)
        } catch {
            throw ResticError.malformedOutput(
                                detail: "could not read which backups the retention rules would remove"
            )
        }
        self.init(
            kept: groups.flatMap { $0.keep ?? [] }.sorted { $0.time > $1.time },
            removed: groups.flatMap { $0.remove ?? [] }.sorted { $0.time > $1.time }
        )
    }

    /// What the rules would leave of the plan's history. A count, since the
    /// editor's rules are not applied yet: nothing has been removed.
    var outcomeLine: String {
        let total = kept.count + removed.count
        guard total > 0 else { return "This plan has no backups in the repository yet." }
        if removed.isEmpty {
            return total == 1 ? "The backup would stay." : "All \(Format.plural(total, "backup")) would stay."
        }
        return "With these rules, \(Format.plural(total, "backup")) would become \(kept.count)."
    }
}
