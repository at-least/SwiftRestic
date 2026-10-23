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
            .filter { key, _ in !ResticPath.ancestors(of: key).contains { removed[$0] != nil } }
            .map(\.value)
            .sorted { $0.path < $1.path }
    }
}

/// What a folder's subtree holds of a diff, counted by kind: restic's diff
/// names the leaves — a modified file's folders are never listed — so a
/// collapsed folder would otherwise read as unchanged under a header that
/// counts changes.
struct ChangesInside: Equatable, Sendable {
    /// The kinds present and how many of each; a kind with none is absent.
    var counts: [ResticDiffChange.Category: Int] = [:]

    var total: Int { counts.values.reduce(0, +) }

    /// "2 modified, 1 removed" — the kinds present, in the diff's own order.
    var summary: String {
        ResticDiffChange.Category.allCases
            .compactMap { category in counts[category].map { "\(Format.count($0)) \(category.displayName.lowercased())" } }
            .joined(separator: ", ")
    }

    mutating func add(_ category: ResticDiffChange.Category) {
        counts[category, default: 0] += 1
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
            for folder in ResticPath.ancestors(of: key) {
                inside[folder, default: ChangesInside()].add(change.category)
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
    /// Why the backup's own run could not read it (`UnreadItems.reason`):
    /// set on a "Not read:" line's items, nil on a removal.
    var reason: String? = nil

    /// The last component; the root reads as "/".
    var name: String {
        let last = ResticPath.basename(of: path)
        return last.isEmpty ? path : last
    }
}

/// What a backup's own run could not read (`AppModel.unreadItems(inBackup:)`),
/// each item with restic's line, by its normalized path's bytes. restic
/// leaves such an item — a folder with all it holds — out of the snapshot,
/// so the backup lacks it while the disk may still have it: not read, not
/// removed.
struct UnreadItems: Equatable, Sendable {
    var lines: [PathKey: String] = [:]

    /// The unreadable item that is `path` or a folder above it, with
    /// restic's line; nil when the run read it.
    func item(holding path: String) -> (path: String, line: String)? {
        guard !lines.isEmpty else { return nil }
        let path = ResticPath.normalized(path)
        for candidate in [path] + ResticPath.ancestors(of: path) {
            if let line = lines[PathKey(candidate)] { return (candidate, line) }
        }
        return nil
    }

    /// Why the run could not read `path`, in the app's words
    /// (`RunRecordPresentation.unreadableReason`); nil when it read it.
    func reason(for path: String) -> String? {
        item(holding: path).map { RunRecordPresentation.unreadableReason(line: $0.line, path: $0.path) }
    }
}

/// What a "Removed:" line names — the Restore pane's header and a Files
/// folder's change summary: the first few gone items, each a route, and how
/// many more. Enough names to read on one line.
struct RemovedNames: Equatable, Sendable {
    static let shown = 3

    var items: [RemovedItem]
    var more: Int
    /// "Removed: ", or "Not read: " for what the backup's own run could
    /// not read (`AppModel.unreadItems(inBackup:)`).
    var label: String

    init(_ all: [RemovedItem], label: String = "Removed: ") {
        items = Array(all.prefix(Self.shown))
        more = all.count - items.count
        self.label = label
    }

    /// "Removed: old.txt, sub, and 2 more" — the line as one string, for
    /// VoiceOver and the tests.
    var line: String {
        label + (items.map(\.name) + (more > 0 ? ["and \(Format.count(more)) more"] : [])).joined(separator: ", ")
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
    /// What the Change column compares against; the backup's ID is in
    /// `detail`.
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
    /// What this backup's own run could not read, taken out of `removed`:
    /// restic left it out, and the disk may still hold it.
    var notRead: Removals?

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

    init(record: Snapshot, label: SnapshotLineage.Label?, comparison: ChangeComparison?, unread: UnreadItems = UnreadItems()) {
        name = SnapshotLineage.displayName(of: record, label: label)
        time = Format.timestamp(record.time)

        let about: String?
        let why: String
        switch comparison {
        case nil:
            about = nil
            why = "Backup \(record.id)."
        case .firstBackup:
            about = "First backup of this folder — nothing to compare with"
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
        // The backup's ID stays in the tooltip (`why`); the line is only
        // what the Change column is measured against.
        caption = about ?? ""
        detail = [label?.detail, why].compactMap { $0 }.joined(separator: "\n")
        if case .failed = comparison { isProblem = true } else { isProblem = false }

        if case let .compared(baseline, _, all) = comparison {
            let isUnread = { (change: ResticDiffChange) in unread.item(holding: change.path) != nil }
            let since = Format.timestamp(baseline.time)
            removed = Self.removals(all.filter { !isUnread($0) }, baseline: baseline, unread: unread,
                                    label: "Removed: ", heading: "Removed since \(since):")
            notRead = Self.removals(all.filter(isUnread), baseline: baseline, unread: unread,
                                    label: "Not read: ", heading: "Not read by this backup — restic could not read them; the backup of \(since) has them:")
        }
    }

    private static func removals(
        _ changes: [ResticDiffChange], baseline: Snapshot, unread: UnreadItems, label: String, heading: String
    ) -> Removals? {
        guard !changes.isEmpty else { return nil }
        let names = RemovedNames(changes.map { change in
            let path = ResticPath.normalized(change.path)
            return RemovedItem(path: path, isDirectory: change.isDirectory, reason: unread.reason(for: path))
        }, label: label)
        let paths = changes.prefix(removedPaths).map { change in
            let path = ResticPath.normalized(change.path)
            return change.isDirectory ? "\(path) and everything in it" : path
        }
        let rest = changes.count - paths.count
        let detail = ([heading] + paths + (rest > 0 ? ["and \(Format.count(rest)) more"] : [])).joined(separator: "\n")
        return Removals(names: names, baseline: baseline, detail: detail)
    }

    private static func comparedWith(_ record: Snapshot, _ baseline: Snapshot) -> String {
        "Backup \(record.id), compared with \(baseline.id) — the previous backup "
            + "of these folders from the same Mac."
    }
}
