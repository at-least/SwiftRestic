import Foundation

/// What the restore pane's Change column was computed against, as the pane
/// last set it: written where the record's diff starts and where it lands,
/// so the header names exactly the comparison the marks on screen came from
/// — never a re-derivation that could disagree with them.
enum ChangeComparison: Equatable, Sendable {
    /// No earlier backup of these folders from this host: no diff runs, and
    /// the restore pane shows no Change column.
    case firstBackup
    case comparing(baseline: Snapshot)
    /// The diff finished: `changeCount` of the items this backup holds
    /// changed, zero meaning none.
    case compared(baseline: Snapshot, changeCount: Int)
    /// The diff stopped short. Marks that streamed before the failure stay —
    /// each is still true — but a blank row no longer means "unchanged".
    case failed(baseline: Snapshot, reason: String)
}

extension ChangeComparison {
    /// The backup compared with; nil for a first backup.
    var baseline: Snapshot? {
        switch self {
        case let .comparing(baseline), let .compared(baseline, _), let .failed(baseline, _): baseline
        case .firstBackup: nil
        }
    }

    /// The changes the Change column marks: the items this backup holds. A
    /// removal has no row in its tree, and counting one in a folder's tally
    /// would promise a row the folder does not have; Show Changes Only lists
    /// them.
    static func heldChanges(_ changes: [PathKey: ResticDiffChange]) -> [PathKey: ResticDiffChange] {
        changes.filter { $0.value.category != .removed }
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
    static func changesInside(_ changes: [PathKey: ResticDiffChange]) -> [PathKey: ChangesInside] {
        var inside: [PathKey: ChangesInside] = [:]
        for (key, change) in changes {
            for folder in ResticPath.ancestors(of: key.path) {
                inside[PathKey(folder), default: ChangesInside()].add(change.category)
            }
        }
        return inside
    }
}

/// What a backup's own run could not read (`AppModel.unreadItems(inBackup:)`),
/// each item with restic's line, by its normalized path's bytes. restic
/// leaves such an item — a folder with all it holds — out of the snapshot,
/// so the backup lacks it while the disk may still have it: not read, not
/// removed.
struct UnreadItems: Equatable, Sendable {
    var lines: [PathKey: String] = [:]

    func item(holding path: String) -> (path: String, line: String)? {
        guard !lines.isEmpty else { return nil }
        let path = ResticPath.normalized(path)
        for candidate in [path] + ResticPath.ancestors(of: path) {
            if let line = lines[PathKey(candidate)] { return (candidate, line) }
        }
        return nil
    }

    func reason(for path: String) -> String? {
        item(holding: path).map { RunRecordPresentation.unreadableReason(line: $0.line, path: $0.path) }
    }
}

/// What the restore pane says of its Change column: a line above the tree
/// only when the comparison failed — a blank column then means "not known",
/// not "unchanged" — and otherwise its title's tooltip (`columnHelp`). Pure,
/// so the wording is pinned by tests; the pane only lays it out.
struct RestoreRecordHeading: Equatable, Sendable {
    var name: String
    /// Kept apart from `name` so the view can truncate a
    /// long qualifier and never the day.
    var time: String
    var caption: String
    /// The tooltip: the backup's folders (with host and writers when the
    /// label has them), when it was made, and that the comparison failed.
    /// No IDs: the run drawer's copied details carry those.
    var detail: String
    var isProblem: Bool

    init(record: Snapshot, label: SnapshotLineage.Label?, comparison: ChangeComparison?) {
        name = SnapshotLineage.displayName(of: record, label: label)
        time = Format.timestamp(record.time)

        let about: String?
        switch comparison {
        case nil:
            about = nil
        case .firstBackup:
            about = "First backup of this folder — nothing to compare with"
        case let .comparing(baseline):
            about = "Comparing with \(Format.timestamp(baseline.time))…"
        case let .compared(baseline, count):
            let since = Format.timestamp(baseline.time)
            about = count == 0
                ? "No changes since \(since)"
                : "\(Format.plural(count, "change")) since \(since)"
        case let .failed(baseline, reason):
            about = "Couldn’t compare with \(Format.timestamp(baseline.time)): \(Format.firstSentence(reason))"
        }
        caption = about ?? ""
        let folders = label?.detail ?? record.lineageKey.folderList
        var lines = [folders, "Backed up \(time)"]
        if case .failed = comparison { lines.append("Couldn’t compare with the previous backup.") }
        detail = lines.joined(separator: "\n")
        if case .failed = comparison { isProblem = true } else { isProblem = false }
    }

    /// The Change column title's tooltip: what the marks are measured
    /// against, and that what this backup no longer holds is not among
    /// them — its tree has no row for it. nil for a first backup, which has
    /// no Change column, and when the comparison failed: the line above the
    /// tree is that fact's carrier.
    static func columnHelp(for comparison: ChangeComparison?) -> String? {
        switch comparison {
        case nil:
            "How each item changed since the previous backup of these folders from this Mac"
        case let .comparing(baseline):
            "Comparing with the backup of \(Format.timestamp(baseline.time))…"
        case let .compared(baseline, _):
            // restic diff without --metadata lists no metadata-only (U)
            // changes, so a blank row can still hide a chmod or a touch.
            "Added or modified since the backup of \(Format.timestamp(baseline.time)). "
                + "Changes to permissions or timestamps alone are not marked"
        case .firstBackup, .failed:
            nil
        }
    }
}
