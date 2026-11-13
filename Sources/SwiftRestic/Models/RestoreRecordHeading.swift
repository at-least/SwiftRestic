import Foundation

/// What the restore pane's Change column was computed against, written where
/// the diff starts and lands, so the header names the comparison the marks
/// came from — never a re-derivation that could disagree.
enum ChangeComparison: Equatable, Sendable {
    /// No earlier backup of these folders from this host: no diff runs, and
    /// the restore pane shows no Change column.
    case firstBackup
    case comparing(baseline: Snapshot)
    /// `changeCount`: of the items this backup holds.
    case compared(baseline: Snapshot, changeCount: Int)
    /// Marks that streamed before the failure stay, but a blank row no
    /// longer means "unchanged".
    case failed(baseline: Snapshot, reason: String)
}

extension ChangeComparison {
    var baseline: Snapshot? {
        switch self {
        case let .comparing(baseline), let .compared(baseline, _), let .failed(baseline, _): baseline
        case .firstBackup: nil
        }
    }

    /// A removal has no row in this backup's tree, so it is not marked.
    static func heldChanges(_ changes: [PathKey: ResticDiffChange]) -> [PathKey: ResticDiffChange] {
        changes.filter { $0.value.category != .removed }
    }
}

/// restic's diff names the leaves, never a modified file's folders, so a
/// collapsed folder needs its subtree's tally to not read as unchanged.
struct ChangesInside: Equatable, Sendable {
    /// A kind with none is absent.
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
    /// Removals included, so the root's total is the header's count. One
    /// pass when the diff lands, not a walk per row.
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

/// What a backup's own run could not read, with restic's line. restic
/// leaves such an item, a folder with all it holds, out of the snapshot:
/// not read, not removed.
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

/// A line above the tree only when the comparison failed (a blank column
/// then means "not known"), otherwise the column title's tooltip
/// (`columnHelp`). Pure, so tests pin the wording.
struct RestoreRecordHeading: Equatable, Sendable {
    var name: String
    /// Apart from `name`, so the view truncates a long qualifier, never the day.
    var time: String
    var caption: String
    /// The tooltip. No IDs: a run's details text carries those.
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

    /// nil for a first backup (no Change column) and for a failed
    /// comparison, which the line above the tree carries.
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
