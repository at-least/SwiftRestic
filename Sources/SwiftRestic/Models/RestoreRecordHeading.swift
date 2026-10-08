import Foundation

/// What the restore pane's Change column was computed against, as the pane
/// last set it: written where the record's diff starts and where it lands,
/// so the header names exactly the comparison the marks on screen came from
/// — never a re-derivation that could disagree with them.
enum ChangeComparison: Equatable, Sendable {
    /// No earlier backup of these folders from this host: no diff runs, and
    /// the Change column stays blank.
    case firstBackup
    /// `restic diff` against the baseline is running.
    case comparing(baseline: Snapshot)
    /// The diff finished: `changeCount` paths differ, zero meaning none.
    /// `removed` is what the baseline held and this backup does not, top-most
    /// first (`removals(in:)`) — the changes no row of this backup's tree can
    /// carry a mark for.
    case compared(baseline: Snapshot, changeCount: Int, removed: [ResticDiffChange] = [])
    /// The diff stopped short. Marks that streamed before the failure stay —
    /// each is still true — but a blank row no longer means "unchanged".
    case failed(baseline: Snapshot, reason: String)
}

extension ChangeComparison {
    /// The removed paths of a diff, each only once: restic lists a removed
    /// folder and then everything it held, and the folder says it all. A
    /// path stays when no folder above it is removed too — its ancestors
    /// walked byte-exact (`ResticPath.parent`), so "/src/data2" is never
    /// inside "/src/data". Sorted by path, so the header reads the same on
    /// every visit.
    static func removals(in changes: [String: ResticDiffChange]) -> [ResticDiffChange] {
        let removed = changes.filter { $0.value.category == .removed }
        return removed
            .filter { key, _ in
                var path = key
                while path != "/", path.contains("/") {
                    path = ResticPath.parent(of: path)
                    if removed[path] != nil { return false }
                }
                return true
            }
            .map(\.value)
            .sorted { $0.path < $1.path }
    }
}

/// What a folder's subtree holds of a diff, counted by kind: restic's diff
/// names the leaves — a modified file's folders are never listed — so a
/// collapsed folder would otherwise read as unchanged under a header that
/// counts changes.
struct ChangesInside: Equatable, Sendable {
    var added = 0
    var removed = 0
    var modified = 0
    var metadata = 0

    var total: Int { added + removed + modified + metadata }

    /// "2 modified, 1 removed" — the kinds present, in the diff's own order.
    var summary: String {
        [(added, "added"), (removed, "removed"), (modified, "modified"), (metadata, "metadata")]
            .filter { $0.0 > 0 }
            .map { "\(Format.count($0.0)) \($0.1)" }
            .joined(separator: ", ")
    }

    mutating func add(_ category: ResticDiffChange.Category) {
        switch category {
        case .added: added += 1
        case .removed: removed += 1
        case .modified: modified += 1
        case .metadataOnly: metadata += 1
        }
    }
}

extension ChangeComparison {
    /// Each folder's tally of the changes beneath it — every entry of the
    /// diff counted once per folder above it, removals included, so the
    /// tree root's total is the header's count. One pass over the map's
    /// keys when the diff lands, not a walk per row. Keys are the diff's
    /// own: normalized paths, no trailing slash.
    static func changesInside(_ changes: [String: ResticDiffChange]) -> [String: ChangesInside] {
        var inside: [String: ChangesInside] = [:]
        for (key, change) in changes {
            var path = key
            while path != "/", path.contains("/") {
                path = ResticPath.parent(of: path)
                inside[path, default: ChangesInside()].add(change.category)
            }
        }
        return inside
    }
}

/// An item a backup no longer holds that the one before it did: a
/// "Removed:" line's route to that copy's versions.
struct RemovedItem: Hashable, Sendable {
    var path: String
    var isDirectory: Bool

    /// The last component; the root reads as "/".
    var name: String {
        let last = ResticPath.basename(of: path)
        return last.isEmpty ? path : last
    }
}

/// What a "Removed:" line names — the Restore pane's header and a Files
/// folder's change summary: the first few gone items, each a route, and how
/// many more. Enough names to read on one line.
struct RemovedNames: Equatable, Sendable {
    static let shown = 3

    var items: [RemovedItem]
    var more: Int

    init(_ all: [RemovedItem]) {
        items = Array(all.prefix(Self.shown))
        more = all.count - items.count
    }

    /// "Removed: old.txt, sub, and 2 more" — the line as one string, for
    /// VoiceOver and the tests.
    var line: String {
        "Removed: " + (items.map(\.name) + (more > 0 ? ["and \(Format.count(more)) more"] : [])).joined(separator: ", ")
    }
}

/// The restore pane's header: which backup is open, and what its Change
/// column compares it with. A blank column means one of four things — first
/// backup, nothing changed, still comparing, or a failed diff — and only this
/// line tells them apart; with the sidebar hidden it is also the only thing
/// naming the backup at all. Pure, so the wording is pinned by tests; the
/// pane only lays it out.
struct RestoreRecordHeading: Equatable, Sendable {
    /// The name of the place the sidebar shows the backup — its plan, or
    /// its group under Other backups — qualified when the name alone is
    /// ambiguous (`BackupShelves.label(of:repositories:localHost:)`).
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
    /// What the backup before held and this one does not — a removal has no
    /// row in this backup's tree to wear a mark, so without this line
    /// "1 change" could point at nothing on screen. Only for a finished
    /// comparison: a partial one's list would pass for the whole.
    var removed: Removals?

    struct Removals: Equatable, Sendable {
        /// The names the line shows, each a route to its versions at
        /// `baseline`, which holds it.
        var names: RemovedNames
        /// The backup compared with.
        var baseline: Snapshot
        /// The paths in full, for the line's tooltip.
        var detail: String

        /// "Removed: old.txt, sub", by name.
        var line: String { names.line }
    }

    /// Enough paths for a tooltip that still fits on screen.
    private static let removedPaths = 20

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
        case let .compared(baseline, count, _):
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

        if case let .compared(baseline, _, removals) = comparison, !removals.isEmpty {
            let names = RemovedNames(removals.map { RemovedItem(path: ResticPath.normalized($0.path), isDirectory: $0.isDirectory) })
            let paths = removals.prefix(Self.removedPaths).map { change in
                let path = ResticPath.normalized(change.path)
                return change.isDirectory ? "\(path) and everything in it" : path
            }
            let rest = removals.count - paths.count
            let detail = (["Removed since \(Format.timestamp(baseline.time)):"] + paths
                + (rest > 0 ? ["and \(Format.count(rest)) more"] : [])).joined(separator: "\n")
            removed = Removals(names: names, baseline: baseline, detail: detail)
        }
    }

    private static func comparedWith(_ record: Snapshot, _ baseline: Snapshot) -> String {
        "Backup \(record.id), compared with \(baseline.id) — the previous backup "
            + "of these folders from the same Mac."
    }
}
