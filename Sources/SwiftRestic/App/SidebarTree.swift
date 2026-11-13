import Foundation

/// The sidebar's second and last level under a repository (the HIG: "no
/// more than two levels of hierarchy in a sidebar"). The repository row
/// never collapses. A page's backups are its Backups tab's, not rows of
/// their own.
///
/// Each value is unique across the whole sidebar, so the repository-wide
/// cases carry their repository's ID: the List gives every repository's
/// children one identity space, and a bare `otherBackups` case showed one
/// repository's node, empty, under the others too.
enum SidebarChild: Hashable {
    case plan(UUID)
    /// "Back Up a Folder…", only while the repository has no plan.
    case addPlan(repositoryID: UUID)
    /// The caption over `BackupShelves.others`, whose groups are each a page
    /// at the plans' level. Only while there are some.
    case otherBackups(repositoryID: UUID)
}

enum SidebarTree {
    static func children(of repositoryID: UUID, in plans: [BackupPlan], hasOtherBackups: Bool) -> [SidebarChild] {
        let own = plans.filter { $0.repositoryID == repositoryID }.map { SidebarChild.plan($0.id) }
        return (own.isEmpty ? [.addPlan(repositoryID: repositoryID)] : own)
            + (hasOtherBackups ? [.otherBackups(repositoryID: repositoryID)] : [])
    }

    /// "Other" only beside plans: in a repository with none — one added
    /// with an existing history — every backup is simply there.
    static func otherBackupsTitle(repositoryHasPlans: Bool) -> String {
        repositoryHasPlans ? "Other backups" : "Backups"
    }

    /// Where the window lands at launch and after its pane disappears: one
    /// repository with one plan has one thing to show; otherwise the first
    /// repository's page, its overview, or the welcome with no repository.
    static func landingSelection(repositories: [Repository], plans: [BackupPlan]) -> SidebarItem? {
        if repositories.count == 1, plans.count == 1, plans[0].repositoryID == repositories[0].id {
            return .plan(plans[0].id)
        }
        return repositories.first.map { .repository($0.id) }
    }
}

/// One repository's backups, each on exactly one page: the plan of this
/// repository whose tag (`ResticService.planTag`) it carries, else a group
/// under Other backups — by plan UUID when a plan tag names one, by lineage
/// otherwise.
///
/// Equatable so the root view can watch the shelves themselves: when a plan
/// is adopted or removed, backups change shelves while no count and no
/// listing changes, and `reshelve` rewriting the shelves is the one signal.
struct BackupShelves: Equatable {
    /// The repository's plans, in configuration order.
    let plans: [BackupPlan]
    /// Every configured plan: a plan-UUID group naming one of them is a plan
    /// that now backs up to another repository, and must never read as
    /// adoptable; any other UUID is a plan no configuration sets up.
    let allPlans: [BackupPlan]
    /// Each plan's backups, newest first, one flat list even when the plan's
    /// folders changed: `SnapshotLineage.changeBaseline` finds a baseline by
    /// lineage, not by the row below. A plan with none here has no entry.
    let byPlan: [UUID: [Snapshot]]
    /// Backups with no plan tag come from another Mac or the console.
    let others: [OtherBackupsGroup]

    var hasOtherBackups: Bool { !others.isEmpty }

    /// Every surface that shows this count reads it here, so no two disagree.
    var otherBackupsCount: Int {
        others.reduce(0) { $0 + $1.snapshots.count }
    }

    func adoptableGroups(localHost: String) -> [OtherBackupsGroup] {
        others.filter { adoptablePath(of: $0, localHost: localHost) != nil }
    }

    /// The path a plan adopting `group` would back up; nil when it cannot be
    /// adopted. Only a plan-UUID group no configuration sets up (a deleted
    /// plan's, or one still running on another Mac) whose prefill backup
    /// holds one path, as a plan does. The one adoptability rule every
    /// caller reads.
    func adoptablePath(of group: OtherBackupsGroup, localHost: String) -> String? {
        guard case let .plan(_, snapshots) = group, formerPlan(of: group) == nil,
              let prefill = Self.prefillSnapshot(among: snapshots, localHost: localHost),
              prefill.paths.count == 1
        else { return nil }
        return prefill.paths[0]
    }

    /// The newest this Mac made, else the newest of all: the folder most
    /// likely to exist here. `snapshots` newest first.
    static func prefillSnapshot(among snapshots: [Snapshot], localHost: String) -> Snapshot? {
        snapshots.first { $0.hostname == localHost } ?? snapshots.first
    }

    /// `listing` newest first, as `ResticService.snapshots` sorts it;
    /// `plans` the repository's own and `allPlans` every configured plan,
    /// both in configuration order.
    init(listing: [Snapshot], plans repositoryPlans: [BackupPlan], allPlans: [BackupPlan]) {
        self.plans = repositoryPlans
        self.allPlans = allPlans
        let tags = Self.tags(of: repositoryPlans)
        var byPlan: [UUID: [Snapshot]] = [:]
        var rest: [Snapshot] = []
        for snapshot in listing {
            if let planID = Self.owner(of: snapshot, tags: tags) {
                byPlan[planID, default: []].append(snapshot)
            } else {
                rest.append(snapshot)
            }
        }
        self.byPlan = byPlan
        others = OtherBackupsGroup.grouping(rest)
    }

    /// The first of `plans`, in order, whose tag the backup carries. Only an
    /// outside `restic tag` gives a backup two plans' tags; this keeps it in
    /// one place.
    static func owner(of snapshot: Snapshot, among plans: [BackupPlan]) -> UUID? {
        owner(of: snapshot, tags: tags(of: plans))
    }

    private static func tags(of plans: [BackupPlan]) -> [(id: UUID, tag: String)] {
        plans.map { ($0.id, ResticService.planTag($0.id)) }
    }

    private static func owner(of snapshot: Snapshot, tags: [(id: UUID, tag: String)]) -> UUID? {
        tags.first { snapshot.tags.contains($0.tag) }?.id
    }

    /// Labels distinct among the groups the sidebar shows together.
    func otherLabels(
        repositories: [Repository],
        localHost: String
    ) -> [OtherBackupsGroup.ID: SnapshotLineage.Label] {
        OtherBackupsGroup.labels(for: others, plans: allPlans, repositories: repositories, localHost: localHost)
    }

    /// A single backup's name, matching where the sidebar shows it: its
    /// plan's label (with folders or Mac when the plan's backups here span
    /// several), else its Other backups group's label.
    func label(of record: Snapshot, repositories: [Repository], localHost: String) -> SnapshotLineage.Label? {
        guard let planID = Self.owner(of: record, among: plans),
              let plan = plans.withID(planID)
        else { return otherLabels(repositories: repositories, localHost: localHost)[record.otherGroupID] }
        let lineages = SnapshotLineage.grouping(byPlan[planID] ?? [])
        var label = SnapshotLineage.labels(for: lineages, plans: [plan])[record.lineageKey]
        label?.title = plan.label(among: allPlans)
        return label
    }

    func page(of record: Snapshot, repositoryID: UUID) -> SidebarItem {
        if let planID = Self.owner(of: record, among: plans) { return .plan(planID) }
        return .otherGroup(repositoryID: repositoryID, id: record.otherGroupID)
    }

    /// The configured plan a group belongs to, which backs up to another
    /// repository now. Nil for a group no configuration sets up and for an
    /// untagged lineage.
    func formerPlan(of group: OtherBackupsGroup) -> BackupPlan? {
        guard case let .plan(id, _) = group else { return nil }
        return allPlans.withID(id)
    }
}

extension BackupShelves {
    /// Nil when nothing here can be continued.
    func continuePrompt(repositories: [Repository], localHost: String) -> ContinueBackupsPrompt? {
        let groups = adoptableGroups(localHost: localHost)
        guard let first = groups.first, case let .plan(firstPlanID, _) = first else { return nil }
        guard groups.count == 1 else {
            return ContinueBackupsPrompt(
                text: "\(groups.count) plans have backups here. You can continue them from this Mac.",
                isOne: false,
                firstPlanID: firstPlanID
            )
        }
        let name = otherLabels(repositories: repositories, localHost: localHost)[first.id]!.title
        return ContinueBackupsPrompt(
            text: "“\(name)” has backups here. You can continue them from this Mac.",
            isOne: true,
            firstPlanID: firstPlanID
        )
    }

    /// Nil when it is gone: adopted, or refreshed away.
    func orphanPlanGroup(_ planID: UUID) -> OtherBackupsGroup? {
        others.first { $0.id == .plan(planID) }
    }

    /// A configured plan's shelf, so a backup two plans' tags claim counts
    /// once; a plan being adopted has no shelf yet, so its group under Other
    /// backups.
    func backupCount(ofPlan planID: UUID) -> Int {
        byPlan[planID]?.count ?? orphanPlanGroup(planID)?.snapshots.count ?? 0
    }

    /// Nil when it is gone: forgotten, tagged by the console, or refreshed
    /// away.
    func lineageGroup(_ key: SnapshotLineage.Key) -> OtherBackupsGroup? {
        others.first { $0.id == .lineage(key) }
    }

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
        // otherLabels names every group it is given.
        let label = otherLabels(repositories: repositories, localHost: localHost)[group.id]!
        let planID: UUID? = if case let .plan(planID) = id { planID } else { nil }
        return OtherGroupPageSummary(
            snapshots: group.snapshots,
            title: label.title,
            isMovedPlan: formerPlan(of: group) != nil,
            isAdoptable: adoptablePath(of: group, localHost: localHost) != nil,
            planID: planID
        )
    }
}
