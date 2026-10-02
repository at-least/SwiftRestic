import Foundation

/// One line of backups in a repository: the snapshots of the same folders
/// from the same host — exactly one group of restic's default
/// `--group-by host,paths`.
///
/// The app's single answer to "the same backup, over time". Under a
/// repository's Other backups it groups the records no plan tag marks (a
/// plan's own, tagged ones group by their plan instead — see
/// `OtherBackupsGroup`), and both the restore pane's Change column and the
/// Compare sheet default to the previous snapshot in it. Retention is
/// narrower on purpose: `forget` runs per plan (`--tag <plan>`), and restic
/// groups that plan's snapshots by host+paths — so a lineage two plans share
/// is thinned as two separate groups, and snapshots without a plan tag are
/// never thinned by the app. The consequence the rule accepts: a plan whose
/// folders change starts a new lineage, and the older one stays behind as a
/// group of its own, of which `forget` keeps a full policy's worth
/// indefinitely.
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
        /// What tells two groups apart when the title alone cannot: the
        /// host — among a plan's own backups when several Macs made them,
        /// under Other backups when it isn't this Mac — the folders when two
        /// groups share a title, the tag's last four hex digits when the
        /// caption still matches. Nil when the title is enough.
        var qualifier: String?
        /// The group row's whole second line — the count, the qualifier's
        /// pieces and which kind of group it is (`OtherBackupsGroup`
        /// derives it). Nil where no row shows the label: a plan's records
        /// sit under a plan row whose caption is `PlanStatus`'s.
        var caption: Caption?
        /// Every folder and the host — and, for a group under Other
        /// backups, who wrote it — for the row's tooltip.
        var detail: String

        /// A group row's second line in the pieces the row lays out: the
        /// count and the kind always read whole, and the qualifiers between
        /// them — a 25-character hostname, a folder list — give way first.
        /// Cut as one string, a long hostname took the kind word with it
        /// ("newlixs…utside SwiftRestic").
        struct Caption: Equatable, Sendable {
            /// "2 backups".
            var count: String
            /// The qualifier's host and folders.
            var qualifiers: [String] = []
            /// Which kind of group it is, then the tag's last four hex digits
            /// when another group's caption still matches. Empty for a
            /// configured plan that names no repository.
            var kind: [String] = []

            /// The whole line, for VoiceOver and for comparing captions.
            var text: String { ([count] + qualifiers + kind).joined(separator: " · ") }
        }
    }

    /// Names for `lineages`, all of one plan's own backups and shown
    /// together: the plan's name when one existing plan wrote every
    /// snapshot in the lineage, otherwise the folders' names, with who
    /// wrote them in the tooltip. A lineage another plan's tag also
    /// marks — only an outside `restic tag` can do that — must not wear
    /// one plan's name, which would claim the other's backups. A plan
    /// whose folders changed leaves two lineages with one plan name, so a
    /// shared title brings the folders into the qualifier.
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
                caption: nil,
                detail: detail
            )
        }
        return labels
    }

    /// The one way a backup is named outside the sidebar's group rows — the
    /// restore pane's header and any prompt that says which backup it acts
    /// on: its group's title, qualified exactly as the sidebar qualifies
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

/// One group among a repository's Other backups: every backup carrying one
/// plan's tag (`swiftrestic-plan-<uuid>`), or — for the backups no plan tag
/// marks — one (host, folders) lineage.
///
/// A plan-tagged group is one plan's whole history in this repository, one
/// flat newest-first list exactly like a plan's own shelf, even when it spans
/// several hosts or sets of folders: the Change column still compares within
/// each snapshot's own lineage (`Snapshot.previousComparable`), not by row.
/// Whether the plan is still configured — a plan that now backs up to
/// another repository, against a deleted one no configuration sets up — is
/// what the labels say, not what the grouping depends on.
enum OtherBackupsGroup: Identifiable, Sendable, Equatable {
    enum ID: Hashable, Sendable {
        case plan(UUID)
        case lineage(SnapshotLineage.Key)
    }

    /// The plan whose tag every snapshot in `snapshots` carries.
    case plan(id: UUID, snapshots: [Snapshot])
    /// The backups no plan tag marks, by lineage.
    case lineage(SnapshotLineage)

    var id: ID {
        switch self {
        case let .plan(id, _): .plan(id)
        case let .lineage(lineage): .lineage(lineage.key)
        }
    }

    /// The group's backups, newest first — a plan's own shelf's shape.
    var snapshots: [Snapshot] {
        switch self {
        case let .plan(_, snapshots): snapshots
        case let .lineage(lineage): lineage.snapshots
        }
    }

    /// The groups of `snapshots` — the rest, once every backup a live plan
    /// of the repository made is shelved under it — the one holding the
    /// newest backup first. Input order does not matter.
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
            OtherBackupsGroup.plan(id: $0.key, snapshots: $0.value.sorted(by: newestFirst))
        }
        // The untagged half through the one lineage builder.
        let lineageGroups = SnapshotLineage.grouping(rest).map(OtherBackupsGroup.lineage)
        return (planGroups + lineageGroups).sorted { lhs, rhs in
            let (left, right) = (lhs.snapshots[0], rhs.snapshots[0])
            return left.time != right.time ? left.time > right.time : left.id < right.id
        }
    }

    private static func newestFirst(_ lhs: Snapshot, _ rhs: Snapshot) -> Bool {
        lhs.time != rhs.time ? lhs.time > rhs.time : lhs.id < rhs.id
    }
}

extension OtherBackupsGroup {
    /// Names for `groups`, all of one repository's Other backups and shown
    /// together: the plan's name when the group is a configured plan's (that
    /// plan backs up to another repository now), the newest backup's folders
    /// otherwise — the newest member decides when a group spans several sets
    /// of them. The caption counts the backups and says which kind of group
    /// it is; the qualifier names the Mac the newest backup came from when it
    /// isn't `localHost`, a title another group shares brings the folders in,
    /// and a caption another group still matches brings the tag's last four
    /// hex digits — the one identifier left. `plans` is every configured
    /// plan, not just the repository's own.
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
            let title = titles[group.id] ?? ""
            // The lineage key's sorted paths: the one order every folder
            // list reads, whatever order the snapshot lists them in.
            let folders = newest.lineageKey.paths
                .map { ($0 as NSString).abbreviatingWithTildeInPath }
                .joined(separator: ", ")
            let host = newest.hostname ?? "Unknown host"
            var qualifiers: [String] = []
            // Another Mac's backups are what a name here must warn about;
            // this Mac's own name said nothing, and at 25 characters (the
            // Mac these rows were measured on) it crowded the line.
            if newest.hostname != localHost { qualifiers.append(host) }
            if titleCounts[title, default: 0] > 1 { qualifiers.append(folders) }
            var caption = SnapshotLineage.Label.Caption(
                count: Format.plural(group.snapshots.count, "backup"),
                qualifiers: qualifiers
            )
            var detail = "\(folders) — from \(host)"
            if case let .plan(id, _) = group {
                let plan = plans.first { $0.id == id }
                // A configured plan: it backs up elsewhere now, which is why
                // these backups are not under it. Its repository can be read
                // whenever the configuration is one of the app's own flows —
                // removing a repository takes its plans — so a plan that
                // names none says no destination rather than a wrong one.
                if let plan, let destination = repositories.first(where: { $0.id == plan.repositoryID }) {
                    caption.kind = ["now backs up to “\(destination.name)”"]
                    detail += "\nThe “\(title)” plan backs up to “\(destination.name)” now; these are its earlier backups."
                } else if plan == nil {
                    // No configuration holds this plan: it was deleted here,
                    // or is still running on another Mac — the two cannot be
                    // told apart, so the row asserts neither.
                    caption.kind = ["not set up here"]
                    detail += "\nBacked up by a plan not set up here"
                }
            } else {
                caption.kind = ["outside SwiftRestic"]
                detail += "\nThese backups carry no plan ID, so they can't be adopted. "
                    + "restic's `tag` command (Repository ▸ restic Console…) can give them one, "
                    + "but it rewrites every snapshot's ID."
            }
            labels[group.id] = SnapshotLineage.Label(
                title: title,
                qualifier: qualifiers.isEmpty ? nil : qualifiers.joined(separator: " · "),
                caption: caption,
                detail: detail
            )
        }

        // A caption another group still matches gets the tag's last four hex
        // digits. Only plan groups can get this far: two untagged groups with
        // the same folders from the same host would be one lineage, and the
        // kind word always tells an untagged group from a plan one. Two UUIDs
        // that share their last four digits would still read alike — the one
        // collision the rule accepts.
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
        return labels
    }

    /// The plan's name when the group is a configured plan's, the newest
    /// backup's folders otherwise.
    private static func title(of group: OtherBackupsGroup, plans: [BackupPlan]) -> String {
        if case let .plan(id, _) = group,
           let plan = plans.first(where: { $0.id == id }), !plan.name.isEmpty {
            return plan.name
        }
        let names = group.snapshots[0].lineageKey.paths.map { ($0 as NSString).lastPathComponent }
        return names.isEmpty ? "Untitled backup" : names.joined(separator: ", ")
    }
}

extension Snapshot {
    /// Which lineage this snapshot belongs to.
    var lineageKey: SnapshotLineage.Key {
        SnapshotLineage.Key(hostname: hostname, paths: paths.sorted())
    }

    /// The plan this snapshot's tag names: the lexicographically first
    /// `swiftrestic-plan-` tag that parses — the snapshot index's own rule
    /// for a backup several plans' tags claim, which only an outside
    /// `restic tag` can produce (restic's listing already sorts tags;
    /// sorting again keeps other writers' in step). Nil when no plan tag
    /// marks it.
    var planID: UUID? {
        tags
            .filter { $0.hasPrefix(ResticService.planTagPrefix) }
            .sorted()
            .lazy
            .compactMap { ResticService.planUUID(fromTag: $0) }
            .first
    }

    /// The group under Other backups that holds this snapshot — the rule
    /// `OtherBackupsGroup.grouping` groups by, read where one record's group
    /// is looked up without regrouping.
    var otherGroupID: OtherBackupsGroup.ID {
        planID.map(OtherBackupsGroup.ID.plan) ?? .lineage(lineageKey)
    }
}
