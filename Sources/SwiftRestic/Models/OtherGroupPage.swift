import Foundation

/// What the page of one group under Other backups shows — a plan-UUID
/// group's or an untagged lineage's: the explanation card's sentence and
/// the Backups card's rows, derived once here so the page and the sidebar's
/// words for the same group (`OtherBackupsGroup.labels`, which names it)
/// can never disagree, and the adopt sheet reads the same facts.
///
/// The group's kind decides the explanation: a UUID no configuration sets
/// up is adoptable — the sentence offers both causes (deleted here, still
/// running on another Mac) and asserts neither; a UUID naming a configured
/// plan is that plan's earlier history here, said with where the plan went;
/// backups with no plan tag were made outside SwiftRestic and cannot be
/// adopted.
struct OtherGroupPageSummary: Equatable {
    /// The group's label title — the page's name is the sidebar row's.
    var title: String
    /// The explanation card's whole sentence.
    var explanation: String
    /// The one configured plan the group belonged to, when it still is
    /// one: the moved variant's "Open the … Plan" target. Nil for an
    /// adoptable group, whose page offers the adopt verb instead.
    var formerPlan: BackupPlan?
    /// Whether the page offers Adopt (`BackupShelves.adoptablePath`).
    var isAdoptable: Bool
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
    /// line: "Made on" already names them both.
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

    /// `snapshots` are the group's, newest first as `OtherBackupsGroup`
    /// sorts them, and never empty — a group exists only around backups.
    /// `planID` is the plan tag's UUID, nil for an untagged lineage;
    /// `allPlans` every configured plan, which `formerPlan`'s label reads.
    init(
        snapshots: [Snapshot],
        title: String,
        formerPlan: BackupPlan?,
        allPlans: [BackupPlan],
        isAdoptable: Bool,
        repositories: [Repository],
        planID: UUID?
    ) {
        self.title = title
        self.formerPlan = formerPlan
        self.isAdoptable = isAdoptable
        newestAt = snapshots[0].time
        oldestAt = snapshots[snapshots.count - 1].time
        newestSnapshotID = snapshots[0].id
        planTag = planID.map(ResticService.planTag)

        if planID == nil {
            // The labels' "outside SwiftRestic", as a sentence: no plan
            // made them, so there is no plan to adopt them into.
            explanation = snapshots.count == 1
                ? "Made outside SwiftRestic, so it can't become a plan."
                : "Made outside SwiftRestic, so they can't become a plan."
        } else if let formerPlan {
            let name = formerPlan.label(among: allPlans)
            // Where it went: the destination the sidebar's caption names,
            // read the same way. A plan that names no reachable repository
            // — its own page says "No repository set" — still left, which
            // is all the sentence can honestly say.
            let moved = repositories.first(where: { $0.id == formerPlan.repositoryID })
                .map { " before it moved to “\($0.label(among: repositories))”" }
                ?? " before it moved away"
            explanation = snapshots.count == 1
                ? "This is the backup “\(name)” made here\(moved)."
                : "These are the \(Format.plural(snapshots.count, "backup")) “\(name)” made here\(moved)."
        } else {
            // Neither cause is knowable from the repository (another Mac's
            // living plan and a deleted plan leave the same tag behind), so
            // the sentence offers both without choosing.
            explanation = "From a plan that isn't set up here — deleted, or still running on another Mac."
            // A history of several folders, from builds that let a plan
            // hold a list: a plan is one path now, so there is no plan to
            // adopt it into.
            if !isAdoptable {
                explanation += snapshots.count == 1
                    ? " It holds several folders and a plan backs up one, so it can't be adopted."
                    : " They hold several folders and a plan backs up one, so they can't be adopted."
            }
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

        excludes = BackupPlan.withoutDuplicates(snapshots.flatMap(\.excludes))
        userTags = BackupPlan.withoutDuplicates(
            snapshots.flatMap { $0.tags.filter { !$0.hasPrefix(ResticService.planTagPrefix) } }
        )
    }
}

extension BackupShelves {
    /// The group under this repository's Other backups whose plan tag names
    /// `planID` — the page's and the selection revalidation's one lookup.
    /// Nil when it is gone: adopted, or refreshed away.
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
            allPlans: allPlans,
            isAdoptable: adoptablePath(of: group, localHost: localHost) != nil,
            repositories: repositories,
            planID: planID
        )
    }
}
