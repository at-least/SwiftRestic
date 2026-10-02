import Foundation

/// One line of backups in a repository: the snapshots of the same folders
/// from the same host — exactly one group of restic's default
/// `--group-by host,paths`.
///
/// The app's single answer to "the same backup, over time". A repository's
/// Other backups node groups its records by it, and both the restore pane's
/// Change column and the Compare sheet default to the previous snapshot in
/// it. Retention is narrower on purpose: `forget` runs per plan
/// (`--tag <plan>`), and restic groups that plan's snapshots by host+paths —
/// so a lineage two plans share is thinned as two separate groups, and
/// snapshots without a plan tag are never thinned by the app. The consequence
/// the rule accepts: a plan whose folders change starts a new lineage, and
/// the older one stays behind as a group of its own, of which `forget` keeps
/// a full policy's worth indefinitely.
struct SnapshotLineage: Identifiable, Sendable, Equatable {
    struct Key: Hashable, Sendable {
        var hostname: String?
        /// Sorted, as restic's grouping compares them. restic already stores
        /// a snapshot's paths sorted (0.19.1: `backup zeta alpha` records
        /// [alpha, zeta]); sorting again keeps other writers' snapshots in step.
        var paths: [String]
    }

    let key: Key
    /// Newest first.
    let snapshots: [Snapshot]
    /// Every `swiftrestic-plan-` tag on the lineage's snapshots, and whether
    /// any snapshot carries none — who wrote it, read once at grouping time
    /// so naming it never rescans the snapshots.
    let planTags: Set<String>
    let hasSnapshotsWithoutPlan: Bool

    var id: Key { key }

    /// The lineages in `snapshots`, the one holding the newest backup first,
    /// each lineage's snapshots newest first. Input order does not matter.
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
                    let tags = snapshot.tags.filter { $0.hasPrefix(ResticService.planTagPrefix) }
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
            .sorted { lhs, rhs in
                let (left, right) = (lhs.snapshots[0], rhs.snapshots[0])
                return left.time != right.time ? left.time > right.time : left.id < right.id
            }
    }

    /// The backup the restore pane's Change column compares `snapshotID`
    /// against: the previous one in its lineage, never merely the row above
    /// in a repository several plans share.
    static func changeBaseline(for snapshotID: String, in listing: [Snapshot]) -> Snapshot? {
        listing.first { $0.id == snapshotID }?.previousComparable(in: listing)
    }

    private static func newestFirst(_ lhs: Snapshot, _ rhs: Snapshot) -> Bool {
        lhs.time != rhs.time ? lhs.time > rhs.time : lhs.id < rhs.id
    }
}

extension SnapshotLineage {
    /// How a group of backups is named among the others shown beside it.
    struct Label: Equatable, Sendable {
        var title: String
        /// What tells two lineages apart when the title alone cannot: the
        /// host when the repository holds several, the folders when two
        /// lineages share a title. Nil when the title is enough.
        var qualifier: String?
        /// Every folder and the host — and, when no single plan wrote the
        /// lineage, who did — for the row's tooltip.
        var detail: String
    }

    /// Names for `lineages`, all of one repository and shown together: the
    /// plan's name when one
    /// existing plan wrote every snapshot in the lineage, otherwise the
    /// folders' names, with who wrote them in the tooltip. A group two plans
    /// share (or one plan and the Console) must not wear one plan's name —
    /// that name flipped with whichever ran last, and claimed the other's
    /// backups. A plan whose folders changed leaves two lineages with one
    /// plan name, so a shared title brings the folders into the qualifier.
    static func labels(for lineages: [SnapshotLineage], plans: [BackupPlan]) -> [Key: Label] {
        let titles = Dictionary(uniqueKeysWithValues: lineages.map { ($0.key, title(of: $0, plans: plans)) })
        var titleCounts: [String: Int] = [:]
        for title in titles.values { titleCounts[title, default: 0] += 1 }
        let severalHosts = Set(lineages.map(\.key.hostname)).count > 1

        var labels: [Key: Label] = [:]
        for lineage in lineages {
            let title = titles[lineage.key] ?? ""
            let folders = lineage.key.paths
                .map { ($0 as NSString).abbreviatingWithTildeInPath }
                .joined(separator: ", ")
            let host = lineage.key.hostname ?? "Unknown host"
            var qualifiers: [String] = []
            if severalHosts { qualifiers.append(host) }
            if titleCounts[title, default: 0] > 1 { qualifiers.append(folders) }
            var detail = "\(folders) — from \(host)"
            if soleWriter(of: lineage, plans: plans) == nil, !lineage.planTags.isEmpty {
                let named = plans.filter { lineage.planTags.contains(ResticService.planTag($0.id)) }
                var writers = named.map(\.name)
                if named.count < lineage.planTags.count { writers.append("a removed plan") }
                if lineage.hasSnapshotsWithoutPlan { writers.append("outside SwiftRestic") }
                detail += "\nBacked up by \(listing(writers))"
            }
            labels[lineage.key] = Label(
                title: title,
                qualifier: qualifiers.isEmpty ? nil : qualifiers.joined(separator: " · "),
                detail: detail
            )
        }
        return labels
    }

    /// The one way a backup is named outside the sidebar's group rows — the
    /// restore pane's header and any prompt that says which backup it acts
    /// on: its lineage's title, qualified exactly as the sidebar qualifies
    /// the group, so the two never disagree.
    static func displayName(of record: Snapshot, label: Label?) -> String {
        if let label {
            return [label.title, label.qualifier].compactMap { $0 }.joined(separator: " · ")
        }
        // Only reachable while the lineages lag the listing, which the
        // model's didSet rules out; the folders still say which backup.
        let folders = record.paths.map { ($0 as NSString).lastPathComponent }
        return folders.isEmpty ? "Backup" : folders.joined(separator: ", ")
    }

    private static func title(of lineage: SnapshotLineage, plans: [BackupPlan]) -> String {
        if let plan = soleWriter(of: lineage, plans: plans), !plan.name.isEmpty {
            return plan.name
        }
        let names = lineage.key.paths.map { ($0 as NSString).lastPathComponent }
        return names.isEmpty ? "Untitled backup" : names.joined(separator: ", ")
    }

    /// The one existing plan every snapshot in the lineage carries the tag
    /// of, or nil when the lineage mixes writers or its plan is gone.
    static func soleWriter(of lineage: SnapshotLineage, plans: [BackupPlan]) -> BackupPlan? {
        guard lineage.planTags.count == 1, !lineage.hasSnapshotsWithoutPlan,
              let tag = lineage.planTags.first
        else { return nil }
        return plans.first { ResticService.planTag($0.id) == tag }
    }

    /// "A", "A and B", "A, B and C".
    private static func listing(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}

extension Snapshot {
    /// Which lineage this snapshot belongs to.
    var lineageKey: SnapshotLineage.Key {
        SnapshotLineage.Key(hostname: hostname, paths: paths.sorted())
    }
}
