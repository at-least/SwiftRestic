import Foundation

/// What the restore pane's Change column was computed against, as the pane
/// last set it: written where the record's diff starts and where it lands,
/// so the header names exactly the comparison the marks on screen came from
/// — never a re-derivation that could disagree with them.
enum ChangeComparison: Equatable, Sendable {
    /// No earlier backup of these folders from this host: no diff runs, and
    /// the Change column stays blank by design.
    case firstBackup
    /// `restic diff` against the baseline is running.
    case comparing(baseline: Snapshot)
    /// The diff finished: `changeCount` paths differ, zero meaning none.
    case compared(baseline: Snapshot, changeCount: Int)
    /// The diff stopped short. Marks that streamed before the failure stay —
    /// each is still true — but a blank row no longer means "unchanged".
    case failed(baseline: Snapshot, reason: String)
}

/// The restore pane's header: which backup is open, and what its Change
/// column compares it with. A blank column means one of four things — first
/// backup, nothing changed, still comparing, or a failed diff — and only this
/// line tells them apart; with the sidebar hidden it is also the only thing
/// naming the backup at all. Pure, so the wording is pinned by tests; the
/// pane only lays it out.
struct RestoreRecordHeading: Equatable, Sendable {
    /// The lineage's name exactly as the Restore sidebar gives it, qualified
    /// the same way when the name alone is ambiguous.
    var name: String
    /// The record's moment. Kept apart from `name` so the view can truncate a
    /// long qualifier and never the day.
    var time: String
    /// The record's short ID and what its Change column compares against.
    var caption: String
    /// The tooltip: folders, host, who wrote them, and both full IDs — the
    /// open record called a backup, as every restore surface calls it.
    var detail: String
    /// The comparison failed: the view adds a warning glyph.
    var isProblem: Bool

    init(record: Snapshot, label: SnapshotLineage.Label?, comparison: ChangeComparison?) {
        name = SnapshotLineage.displayName(of: record, label: label)
        time = Format.timestamp(record.time)

        let about: String?
        let why: String
        switch comparison {
        case nil:
            about = nil
            why = "Backup \(record.id)."
        case .firstBackup:
            about = "No earlier backup of these folders, so no changes are marked"
            why = "Backup \(record.id). The Change column compares a backup with the previous one "
                + "of the same folders from the same Mac, and this is the first."
        case let .comparing(baseline):
            about = "Comparing with \(Format.timestamp(baseline.time))…"
            why = Self.comparedWith(record, baseline)
        case let .compared(baseline, count):
            let since = Format.timestamp(baseline.time)
            about = count == 0
                ? "No changes since \(since)"
                : "\(Format.plural(count, "change")) since \(since)"
            // restic diff without --metadata lists no metadata-only (U)
            // changes, so a blank row can still hide a chmod or a touch.
            why = Self.comparedWith(record, baseline)
                + " Changes to permissions or timestamps alone are not marked."
        case let .failed(baseline, reason):
            about = "Could not compare with \(Format.timestamp(baseline.time)): \(Format.firstSentence(reason))"
            why = Self.comparedWith(record, baseline) + " restic diff failed: \(reason)"
        }
        caption = [record.shortID, about].compactMap { $0 }.joined(separator: " · ")
        detail = [label?.detail, why].compactMap { $0 }.joined(separator: "\n")
        if case .failed = comparison { isProblem = true } else { isProblem = false }
    }

    private static func comparedWith(_ record: Snapshot, _ baseline: Snapshot) -> String {
        "Backup \(record.id), compared with \(baseline.id) — the previous backup "
            + "of these folders from the same Mac."
    }
}
