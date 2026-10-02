import Foundation

/// What the sidebar lists under one repository, in order. The repository's
/// own row is not one of them: it is the parent, always shown, and never
/// collapses — its children are always in view.
///
/// Each value is unique across the whole sidebar — the repository-wide
/// rows carry their repository's ID — because the List gives every
/// repository's children one identity space: with a bare `otherBackups`,
/// the node one repository gained showed up, empty, under the others too
/// (captured 2026-10-02).
enum SidebarChild: Hashable {
    /// A plan, which folds open to the backups it made here.
    case plan(UUID)
    /// "New Backup Plan…", only while the repository has no plan: the place
    /// its plans would be names the way to its first one.
    case addPlan(repositoryID: UUID)
    /// The node for the repository's backups no plan of it made — see
    /// `BackupShelves.others`. Only while there are some.
    case otherBackups(repositoryID: UUID)
}

/// The sidebar's shape, as rules apart from the view so they can be tested.
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

    /// Where the window lands at launch and after its pane disappears: the
    /// first repository's page — each repository's page is its overview —
    /// or the welcome when there is no repository.
    static func landingSelection(repositories: [Repository]) -> SidebarItem? {
        repositories.first.map { .repository($0.id) }
    }
}

/// One repository's backups, sorted to where the sidebar shows them: each
/// under the plan of this repository that made it — the plan's tag
/// (`ResticService.planTag`) says which — and the rest under Other backups,
/// by lineage. Every backup has exactly one place, so its selection tag is
/// unique.
struct BackupShelves {
    /// The repository's plans, in configuration order.
    let plans: [BackupPlan]
    /// Each plan's backups, newest first — one flat list even when the plan's
    /// folders changed: the Change column finds its baseline by lineage in
    /// the whole listing (`SnapshotLineage.changeBaseline`), not by the row
    /// below. A plan with none here has no entry.
    let byPlan: [UUID: [Snapshot]]
    /// The rest, by lineage: backups with no plan tag (another Mac, the
    /// console), a deleted plan's, or those of a plan that now backs up to
    /// another repository.
    let others: [SnapshotLineage]

    var hasOtherBackups: Bool { !others.isEmpty }

    /// `listing` newest first, as `ResticService.snapshots` sorts it; `plans`
    /// the repository's own, in configuration order.
    init(listing: [Snapshot], plans: [BackupPlan]) {
        self.plans = plans
        let tags = Self.tags(of: plans)
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
        others = SnapshotLineage.grouping(rest)
    }

    /// The plan among `plans` a backup sits under: the first, in their
    /// order, whose tag it carries. Only an outside `restic tag` can give a
    /// backup two plans' tags — the app never does — and this keeps it in
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

    /// The names of the groups under Other backups, told apart among
    /// themselves — the set the sidebar shows together.
    func otherLabels(allPlans: [BackupPlan]) -> [SnapshotLineage.Key: SnapshotLineage.Label] {
        SnapshotLineage.labels(for: others, plans: allPlans)
    }

    /// How a backup is named where one backup is named — the restore pane's
    /// header, a whole-backup restore — so it matches the place the sidebar
    /// shows it: its plan's name, with the folders when the plan's backups
    /// here span more than one set of them and the Mac when more than one
    /// Mac made them; under Other backups, its group's label.
    func label(of record: Snapshot, allPlans: [BackupPlan]) -> SnapshotLineage.Label? {
        guard let planID = Self.owner(of: record, among: plans),
              let plan = plans.first(where: { $0.id == planID })
        else { return otherLabels(allPlans: allPlans)[record.lineageKey] }
        let lineages = SnapshotLineage.grouping(byPlan[planID] ?? [])
        var label = SnapshotLineage.labels(for: lineages, plans: [plan])[record.lineageKey]
        label?.title = plan.name.isEmpty ? "Untitled Plan" : plan.name
        return label
    }

    /// The one plan that wrote a group under Other backups: it now backs up
    /// to another repository, which is why its backups here are not under
    /// it. Nil when the group mixes writers or its plan is gone.
    func formerPlan(of lineage: SnapshotLineage, allPlans: [BackupPlan]) -> BackupPlan? {
        SnapshotLineage.soleWriter(of: lineage, plans: allPlans)
    }
}

/// Which folds are open in the sidebar, fresh each launch. Held by the root
/// view rather than the sidebar, so the detail column can open the fold a
/// backup picked from anywhere sits in.
struct SidebarFolds: Equatable {
    /// Plans whose backups are showing.
    var plans: Set<UUID> = []
    /// Repositories whose Other backups are showing.
    var otherBackups: Set<UUID> = []

    /// Opens the fold `record` sits in — its plan's, or its repository's
    /// Other backups. `plans` are the repository's own.
    mutating func reveal(_ record: Snapshot, in repositoryID: UUID, plans repositoryPlans: [BackupPlan]) {
        if let planID = BackupShelves.owner(of: record, among: repositoryPlans) {
            plans.insert(planID)
        } else {
            otherBackups.insert(repositoryID)
        }
    }
}
