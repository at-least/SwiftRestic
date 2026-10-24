import Foundation

/// What a plan's retention rules would do right now: the snapshots
/// `restic forget --dry-run` would remove and the ones it would keep, read
/// from restic's own answer rather than projected, so the confirmation shows
/// exactly the snapshots the real forget will evaluate (Apply Retention
/// Now).
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
        let trimmed = forgetOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.init(kept: [], removed: [])
            return
        }
        let groups: [Group]
        do {
            groups = try ResticMessageDecoder.jsonDecoder.decode([Group]?.self, from: Data(trimmed.utf8)) ?? []
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

    /// The sheet's sentence: how many of the plan's snapshots go, which
    /// ones by date, and how many stay.
    var summary: String {
        let total = kept.count + removed.count
        guard total > 0 else { return "This plan has no backups in the repository yet." }
        guard let newest = removed.first, let oldest = removed.last else {
            return kept.count == 1
                ? "Nothing to remove — this plan's only backup is within its rules."
                : "Nothing to remove — all \(kept.count) of this plan's backups are within its rules."
        }
        let stay = "\(kept.count) will stay."
        if removed.count == 1 {
            return "1 of this plan's \(total) backups would be removed: the one from \(Format.timestamp(newest.time)). \(stay)"
        }
        return "\(removed.count) of this plan's \(total) backups would be removed, from \(Format.timestamp(oldest.time)) to \(Format.timestamp(newest.time)). \(stay)"
    }

    /// The adopt sheet's one line: what the rules the user just turned on
    /// would leave of the history being adopted. No applying can follow from
    /// the sheet, so unlike `summary` the line never counts removals — only
    /// what the history would become.
    var adoptionLine: String {
        let total = kept.count + removed.count
        guard total > 0 else { return "This plan has no backups in the repository yet." }
        if removed.isEmpty {
            return total == 1 ? "The backup would stay." : "All \(Format.plural(total, "backup")) would stay."
        }
        return "With this policy, \(Format.plural(total, "backup")) would become \(kept.count)."
    }

    /// The run record's Detail after the real forget: what went, and
    /// whether its data went with it (the plan's "Also clean up").
    static func appliedSummary(removed: Int, pruned: Bool) -> String {
        guard removed > 0 else { return "No backups needed removing." }
        let snapshots = Format.plural(removed, "backup")
        return pruned
            ? "Removed \(snapshots) and freed \(removed == 1 ? "its" : "their") space."
            : "Removed \(snapshots). \(removed == 1 ? "Its" : "Their") data stays until the next cleanup."
    }
}
