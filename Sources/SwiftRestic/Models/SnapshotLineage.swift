import Foundation

/// The snapshots of the same folders from the same host: one group of
/// restic's default `--group-by host,paths`, and the app's one answer to
/// "the same backup, over time". Under Other backups it groups the
/// snapshots no plan tag marks (tagged ones group by plan,
/// `OtherBackupsGroup`); the Change column compares with the previous
/// snapshot in it.
///
/// Retention is narrower: `forget` runs per plan (`--tag <plan>`), so a
/// lineage two plans share is thinned as two groups, and untagged snapshots
/// are never thinned by the app. Accepted: a plan whose folders change
/// leaves the older lineage behind, of which `forget` keeps a full
/// policy's worth indefinitely.
struct SnapshotLineage: Identifiable, Sendable, Equatable {
    struct Key: Hashable, Sendable {
        var hostname: String?
        /// Sorted, as restic's grouping compares them. restic stores a
        /// snapshot's own paths sorted; sorting again keeps other writers'
        /// snapshots in step.
        var paths: [String]
    }

    let key: Key
    /// Newest first.
    let snapshots: [Snapshot]
    /// Who wrote it, read once at grouping time so naming never rescans.
    private let planTags: Set<String>
    private let hasSnapshotsWithoutPlan: Bool

    var id: Key { key }

    /// The lineage holding the newest backup first, each newest first.
    static func grouping(_ snapshots: [Snapshot]) -> [SnapshotLineage] {
        var buckets: [Key: [Snapshot]] = [:]
        for snapshot in snapshots {
            buckets[snapshot.lineageKey, default: []].append(snapshot)
        }
        return buckets
            .map { key, members in
                var planTags: Set<String> = []
                var withoutPlan = false
                for snapshot in members {
                    let tags = snapshot.planTags
                    planTags.formUnion(tags)
                    if tags.isEmpty { withoutPlan = true }
                }
                return SnapshotLineage(
                    key: key,
                    snapshots: members.sorted(by: newestFirst),
                    planTags: planTags,
                    hasSnapshotsWithoutPlan: withoutPlan
                )
            }
            .sorted { SnapshotLineage.newestFirst($0.snapshots[0], $1.snapshots[0]) }
    }

    static func changeBaseline(for snapshotID: String, in listing: [Snapshot]) -> Snapshot? {
        listing.first { $0.id == snapshotID }?.previousComparable(in: listing)
    }

    static func newestFirst(_ lhs: Snapshot, _ rhs: Snapshot) -> Bool {
        lhs.time != rhs.time ? lhs.time > rhs.time : lhs.id < rhs.id
    }
}

extension SnapshotLineage {
    struct Label: Equatable, Sendable {
        var title: String
        /// What tells two groups apart when the title cannot: the host, the
        /// folders, the tag's last four hex digits. Nil when the title is
        /// enough.
        var qualifier: String?
        /// Nil where no row shows the label: a plan's records sit under a
        /// plan row whose caption is `PlanStatus`'s.
        var caption: Caption?
        /// Every folder and the host: the row tooltip.
        var detail: String

        /// The count and the kind always read whole; the qualifiers between
        /// them give way first.
        struct Caption: Equatable, Sendable {
            var count: String
            var qualifiers: [String] = []
            /// Empty for a configured plan that names no repository.
            var kind: [String] = []

            /// For VoiceOver and for comparing captions.
            var text: String { ([count] + qualifiers + kind).joined(separator: " · ") }
        }
    }

    /// `lineages`: one plan's own backups, shown together. The plan's label
    /// only when one existing plan wrote every snapshot; a lineage another
    /// plan's tag also marks (only an outside `restic tag` can do that)
    /// would otherwise claim the other's backups. A shared title brings the
    /// folders into the qualifier.
    static func labels(for lineages: [SnapshotLineage], plans: [BackupPlan]) -> [Key: Label] {
        let titles = Dictionary(uniqueKeysWithValues: lineages.map { ($0.key, title(of: $0, plans: plans)) })
        var titleCounts: [String: Int] = [:]
        for title in titles.values { titleCounts[title, default: 0] += 1 }
        let severalHosts = Set(lineages.map(\.key.hostname)).count > 1

        var labels: [Key: Label] = [:]
        for lineage in lineages {
            let title = titles[lineage.key]!
            let folders = lineage.key.folderList
            let host = lineage.key.hostname ?? "Unknown Mac"
            var qualifiers: [String] = []
            if severalHosts { qualifiers.append(host) }
            if titleCounts[title, default: 0] > 1 { qualifiers.append(folders) }
            var detail = "\(folders) — from \(host)"
            if soleWriter(of: lineage, plans: plans) == nil, !lineage.planTags.isEmpty {
                let named = plans.filter { lineage.planTags.contains(ResticService.planTag($0.id)) }
                var writers = named.map { $0.label(among: plans) }
                if named.count < lineage.planTags.count { writers.append("a removed plan") }
                if lineage.hasSnapshotsWithoutPlan { writers.append("outside SwiftRestic") }
                detail += "\nBacked up by \(Format.list(writers))"
            }
            labels[lineage.key] = Label(
                title: title,
                qualifier: qualifiers.isEmpty ? nil : qualifiers.joined(separator: " · "),
                caption: nil,
                detail: detail
            )
        }
        return labels
    }

    /// Qualified exactly as the sidebar qualifies the group.
    static func displayName(of record: Snapshot, label: Label?) -> String {
        if let label {
            return [label.title, label.qualifier].compactMap { $0 }.joined(separator: " · ")
        }
        // Only reachable while the lineages lag the listing, which the
        // model's didSet rules out; the folders still say which backup.
        let folders = record.paths.map(Self.component)
        return folders.isEmpty ? "Backup" : folders.joined(separator: ", ")
    }

    /// Not an NSString cut, which can swallow the separator behind a
    /// Prepend character such as U+0600 (`ResticPath`).
    static func component(of path: String) -> String {
        let normalized = ResticPath.normalized(path)
        let last = ResticPath.basename(of: normalized)
        return last.isEmpty ? normalized : last
    }

    private static func title(of lineage: SnapshotLineage, plans: [BackupPlan]) -> String {
        if let plan = soleWriter(of: lineage, plans: plans) {
            return plan.label(among: plans)
        }
        return folderTitle(lineage.key.paths)
    }

    fileprivate static func folderTitle(_ paths: [String]) -> String {
        let names = paths.map(Self.component)
        return names.isEmpty ? "Untitled backup" : names.joined(separator: ", ")
    }

    /// nil when the lineage mixes writers or its plan is gone.
    private static func soleWriter(of lineage: SnapshotLineage, plans: [BackupPlan]) -> BackupPlan? {
        guard lineage.planTags.count == 1, !lineage.hasSnapshotsWithoutPlan,
              let tag = lineage.planTags.first
        else { return nil }
        return ResticService.planUUID(fromTag: tag).flatMap { plans.withID($0) }
    }
}

/// One group under a repository's Other backups: every backup carrying one
/// plan's tag, or for untagged backups one lineage.
///
/// A plan group is one flat newest-first list even when it spans several
/// hosts or sets of folders; the Change column still compares within each
/// snapshot's lineage. Whether the plan is still configured changes the
/// labels, not the grouping.
enum OtherBackupsGroup: Identifiable, Sendable, Equatable {
    enum ID: Hashable, Sendable {
        case plan(UUID)
        case lineage(SnapshotLineage.Key)
    }

    case plan(id: UUID, snapshots: [Snapshot])
    case lineage(SnapshotLineage)

    var id: ID {
        switch self {
        case let .plan(id, _): .plan(id)
        case let .lineage(lineage): .lineage(lineage.key)
        }
    }

    /// Newest first.
    var snapshots: [Snapshot] {
        switch self {
        case let .plan(_, snapshots): snapshots
        case let .lineage(lineage): lineage.snapshots
        }
    }

    /// `snapshots`: what is left once each live plan of the repository took
    /// its own. The group holding the newest backup first.
    static func grouping(_ snapshots: [Snapshot]) -> [OtherBackupsGroup] {
        var byPlan: [UUID: [Snapshot]] = [:]
        var rest: [Snapshot] = []
        for snapshot in snapshots {
            if let planID = snapshot.planID {
                byPlan[planID, default: []].append(snapshot)
            } else {
                rest.append(snapshot)
            }
        }
        let planGroups = byPlan.map {
            OtherBackupsGroup.plan(id: $0.key, snapshots: $0.value.sorted(by: SnapshotLineage.newestFirst))
        }
        let lineageGroups = SnapshotLineage.grouping(rest).map(OtherBackupsGroup.lineage)
        return (planGroups + lineageGroups).sorted {
            SnapshotLineage.newestFirst($0.snapshots[0], $1.snapshots[0])
        }
    }
}

extension OtherBackupsGroup {
    /// The plan's label for a configured plan's group (it backs up to
    /// another repository), else the newest backup's folders. `plans` is
    /// every configured plan, not just the repository's own.
    static func labels(
        for groups: [OtherBackupsGroup],
        plans: [BackupPlan],
        repositories: [Repository],
        localHost: String
    ) -> [ID: SnapshotLineage.Label] {
        var titles: [ID: String] = [:]
        var titleCounts: [String: Int] = [:]
        for group in groups {
            let title = title(of: group, plans: plans)
            titles[group.id] = title
            titleCounts[title, default: 0] += 1
        }

        var labels: [ID: SnapshotLineage.Label] = [:]
        for group in groups {
            let newest = group.snapshots[0]
            let title = titles[group.id]!
            let folders = newest.lineageKey.folderList
            let host = newest.hostname ?? "Unknown Mac"
            var qualifiers: [String] = []
            // This Mac's own name says nothing and crowds the line.
            if newest.hostname != localHost { qualifiers.append(host) }
            if titleCounts[title, default: 0] > 1 { qualifiers.append(folders) }
            var caption = SnapshotLineage.Label.Caption(
                count: Format.plural(group.snapshots.count, "backup"),
                qualifiers: qualifiers
            )
            // The kind's story is on the group's page
            // (`OtherGroupPageSummary.explanation`).
            let detail = "\(folders) — from \(host)"
            if case let .plan(id, _) = group {
                let plan = plans.withID(id)
                // A plan naming no repository says no destination rather
                // than a wrong one.
                if let plan, let destination = repositories.withID(plan.repositoryID) {
                    caption.kind = ["now backs up to \(destination.label(among: repositories))"]
                } else if plan == nil {
                    // Deleted here or running on another Mac: indistinguishable.
                    caption.kind = ["not set up here"]
                }
            } else {
                caption.kind = ["outside SwiftRestic"]
            }
            labels[group.id] = SnapshotLineage.Label(
                title: title,
                qualifier: qualifiers.isEmpty ? nil : qualifiers.joined(separator: " · "),
                caption: caption,
                detail: detail
            )
        }

        disambiguateCollidingCaptions(&labels, groups: groups)
        return labels
    }

    /// Only plan groups can collide: two untagged groups with the same
    /// folders and host would be one lineage, and the kind word tells
    /// untagged from plan. Two UUIDs sharing their last four digits still
    /// read alike; accepted.
    private static func disambiguateCollidingCaptions(
        _ labels: inout [ID: SnapshotLineage.Label],
        groups: [OtherBackupsGroup]
    ) {
        var captionCounts: [String: Int] = [:]
        for label in labels.values {
            captionCounts[label.title + "\n" + label.caption!.text, default: 0] += 1
        }
        for group in groups {
            guard case let .plan(id, _) = group,
                  var label = labels[group.id],
                  captionCounts[label.title + "\n" + label.caption!.text, default: 0] > 1
            else { continue }
            let hex = String(id.uuidString.lowercased().suffix(4))
            label.qualifier = label.qualifier.map { "\($0) · \(hex)" } ?? hex
            label.caption?.kind.append(hex)
            labels[group.id] = label
        }
    }

    private static func title(of group: OtherBackupsGroup, plans: [BackupPlan]) -> String {
        if case let .plan(id, _) = group, let plan = plans.withID(id) {
            return plan.label(among: plans)
        }
        return SnapshotLineage.folderTitle(group.snapshots[0].lineageKey.paths)
    }
}

extension SnapshotLineage.Key {
    /// Every folder list's one spelling.
    var folderList: String {
        paths.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
    }
}

extension Snapshot {
    var lineageKey: SnapshotLineage.Key {
        SnapshotLineage.Key(hostname: hostname, paths: paths.sorted())
    }

    /// The lexicographically first plan tag that parses: the snapshot
    /// index's rule for a backup several plans' tags claim (only an outside
    /// `restic tag` can do that).
    var planID: UUID? {
        planTags
            .sorted()
            .lazy
            .compactMap { ResticService.planUUID(fromTag: $0) }
            .first
    }

    var planTags: [String] {
        tags.filter { $0.hasPrefix(ResticService.planTagPrefix) }
    }

    var userTags: [String] {
        tags.filter { !$0.hasPrefix(ResticService.planTagPrefix) }
    }

    /// `OtherBackupsGroup.grouping`'s rule, without regrouping.
    var otherGroupID: OtherBackupsGroup.ID {
        planID.map(OtherBackupsGroup.ID.plan) ?? .lineage(lineageKey)
    }
}
