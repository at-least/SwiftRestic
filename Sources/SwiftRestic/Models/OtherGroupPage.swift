import Foundation

/// What the page of one group under Other backups shows — a plan-UUID
/// group's or an untagged lineage's: the explanation card's sentence and
/// the Backups card's rows, derived once here so the page and the sidebar's
/// words for the same group (`OtherBackupsGroup.labels`, which names it)
/// can never disagree — and so what the adopt sheet prefills from reads the
/// same facts.
///
/// The group's kind decides the explanation: a UUID no configuration sets
/// up is adoptable — the sentence says what could have happened (deleted
/// here, still running on another Mac) and asserts neither, the labels'
/// own rule — a UUID that names a configured plan is that plan's earlier
/// history here, said with where the plan went, and backups with no plan
/// tag were made outside SwiftRestic and cannot be adopted.
struct OtherGroupPageSummary: Equatable {
    /// The group's label title — the page's name is the sidebar row's.
    var title: String
    /// The explanation card's whole sentence.
    var explanation: String
    /// The one configured plan the group belonged to, when it still is
    /// one: the moved variant's "Open the … Plan" target. Nil for an
    /// adoptable group, whose page offers the adopt verb instead.
    var formerPlan: BackupPlan?
    var newestAt: Date
    var oldestAt: Date
    /// Where the page's Restore Files… lands — the group's newest record.
    var newestSnapshotID: String
    /// The Mac the backups came from, or "N Macs — the list" when several
    /// did — the count first, so a long hostname cannot push it out.
    var madeFrom: String
    /// One line per folder set the history spans, the newest set first —
    /// each in the one folder-list format (`SnapshotLineage.Key.folderList`)
    /// the labels qualify with. Two Macs that spell the same list share the
    /// line: "Made from" already names them both.
    var folders: [String]
    /// Every exclude pattern any of the backups ran with, first-seen order
    /// (newest backup first). Empty when none did — restic omits the key —
    /// and the page then shows no row.
    var excludes: [String]
    /// The user tags among the backups' tags — everything but plan tags,
    /// which are the group's own plumbing. Empty hides the row.
    var userTags: [String]
    /// A plan-UUID group's one honest identifier, selectable on the page;
    /// nil for an untagged lineage, which has none.
    var planTag: String?
    /// The index's chain the group's files are read from
    /// (`SnapshotIndex.chainKey`): the plan tag, or the lineage's host and
    /// folders.
    var chainKey: String

    /// `snapshots` are the group's, newest first as `OtherBackupsGroup`
    /// sorts them, and never empty — a group exists only around backups.
    /// `planID` is the plan tag's UUID, nil for an untagged lineage.
    init(
        snapshots: [Snapshot],
        title: String,
        formerPlan: BackupPlan?,
        repositories: [Repository],
        planID: UUID?
    ) {
        self.title = title
        self.formerPlan = formerPlan
        newestAt = snapshots[0].time
        oldestAt = snapshots[snapshots.count - 1].time
        newestSnapshotID = snapshots[0].id
        planTag = planID.map(ResticService.planTag)
        chainKey = SnapshotIndex.chainKey(for: snapshots[0])

        if planID == nil {
            // The labels' "outside SwiftRestic", as a sentence: no plan
            // made them, so there is no plan to adopt them into.
            explanation = snapshots.count == 1
                ? "This backup carries no plan ID — it was made outside SwiftRestic — so it can't be adopted as a plan."
                : "These \(Format.plural(snapshots.count, "backup")) carry no plan ID — they were made outside SwiftRestic — so they can't be adopted as a plan."
        } else if let formerPlan {
            let name = formerPlan.name.isEmpty ? "Untitled Plan" : formerPlan.name
            // Where it went: the destination the sidebar's caption names,
            // read the same way. A plan that names no reachable repository
            // — its own page says "No repository set" — still left, which
            // is all the sentence can honestly say.
            let moved = repositories.first(where: { $0.id == formerPlan.repositoryID })
                .map { " before it moved to “\($0.name)”" }
                ?? " before it moved away"
            explanation = snapshots.count == 1
                ? "This is the backup “\(name)” made here\(moved)."
                : "These are the \(Format.plural(snapshots.count, "backup")) “\(name)” made here\(moved)."
        } else {
            // Neither cause is knowable from the repository (another Mac's
            // living plan and a deleted plan leave the same tag behind), so
            // the sentence offers both without choosing.
            let carries = snapshots.count == 1 ? "This backup carries" : "These \(Format.plural(snapshots.count, "backup")) carry"
            explanation = "\(carries) the ID of a plan that isn't set up in SwiftRestic"
                + " — it was deleted here, or it's still running on another Mac."
        }

        let hosts = Snapshot.distinctHosts(of: snapshots)
        madeFrom = hosts.count == 1
            ? hosts[0]
            : "\(hosts.count) Macs — \(hosts.joined(separator: ", "))"

        // Dedup on the line itself, first-seen (= newest set) first: two
        // hosts that backed up the same folders are two lineages but one
        // indistinguishable string, and the rows key on the string.
        var folderSets: [String] = []
        for snapshot in snapshots {
            let list = snapshot.lineageKey.folderList
            guard !folderSets.contains(list) else { continue }
            folderSets.append(list)
        }
        folders = folderSets

        excludes = Self.collect(snapshots.flatMap(\.excludes))
        userTags = Self.collect(snapshots.flatMap { $0.tags.filter { !$0.hasPrefix(ResticService.planTagPrefix) } })
    }

    /// In first-seen order, once each.
    private static func collect(_ items: [String]) -> [String] {
        var collected: [String] = []
        for item in items where !collected.contains(item) { collected.append(item) }
        return collected
    }
}

extension BackupShelves {
    /// The group under this repository's Other backups whose plan tag names
    /// `planID` — the page's and the selection revalidation's one lookup.
    /// Nil when it is gone: adopted, its plan moved by the editor, or
    /// refreshed away.
    func orphanPlanGroup(_ planID: UUID) -> OtherBackupsGroup? {
        others.first { $0.id == .plan(planID) }
    }

    /// The untagged lineage under this repository's Other backups whose
    /// host and folders are `key` — its page's and the selection
    /// revalidation's one lookup. Nil when it is gone: forgotten, tagged
    /// by the console, or refreshed away.
    func lineageGroup(_ key: SnapshotLineage.Key) -> OtherBackupsGroup? {
        others.first { $0.id == .lineage(key) }
    }

    /// The page a group's selection shows, either kind, or nil when the
    /// group is not under this repository's Other backups.
    func otherGroupPage(
        _ id: OtherBackupsGroup.ID,
        repositories: [Repository],
        localHost: String
    ) -> OtherGroupPageSummary? {
        let group: OtherBackupsGroup? = switch id {
        case let .plan(planID): orphanPlanGroup(planID)
        case let .lineage(key): lineageGroup(key)
        }
        guard let group else { return nil }
        // The label that named the row names the page; otherLabels names
        // every group it is given.
        let label = otherLabels(repositories: repositories, localHost: localHost)[group.id]!
        let planID: UUID? = if case let .plan(planID) = id { planID } else { nil }
        return OtherGroupPageSummary(
            snapshots: group.snapshots,
            title: label.title,
            formerPlan: formerPlan(of: group),
            repositories: repositories,
            planID: planID
        )
    }
}
