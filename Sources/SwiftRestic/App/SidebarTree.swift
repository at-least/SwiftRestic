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
/// grouped by the plan that made them when a plan tag says which, by lineage
/// otherwise. Every backup has exactly one place, so its selection tag is
/// unique.
///
/// Equatable so the root view can watch the shelves themselves: `reshelve`
/// rewrites them on any plan add, remove, rename or move, which is the one
/// signal that sees a plan leave for another repository — no count changes,
/// the listing does not change. Equality is the synthesized value one, so
/// a reshelve that changes nothing compares equal, and one that moves a
/// backup between shelves — or renames a plan — does not; revalidating on
/// a rename is a no-op.
struct BackupShelves: Equatable {
    /// The repository's plans, in configuration order.
    let plans: [BackupPlan]
    /// Every configured plan, this repository's among them: what tells a
    /// plan-UUID group under Other backups apart — a UUID that names one of
    /// them is a plan that now backs up to another repository, any other is
    /// a plan no configuration sets up. Classification is configuration-wide
    /// on purpose: a UUID that belongs to a configured plan of another
    /// repository must never read as adoptable.
    let allPlans: [BackupPlan]
    /// Each plan's backups, newest first — one flat list even when the plan's
    /// folders changed: the Change column finds its baseline by lineage in
    /// the whole listing (`SnapshotLineage.changeBaseline`), not by the row
    /// below. A plan with none here has no entry.
    let byPlan: [UUID: [Snapshot]]
    /// The rest — a deleted plan's or another repository's plan's backups by
    /// their plan UUID, backups with no plan tag (another Mac, the console)
    /// by lineage.
    let others: [OtherBackupsGroup]

    var hasOtherBackups: Bool { !others.isEmpty }

    /// How many of the repository's backups none of its plans made — the
    /// sidebar's Other backups node, the repository page's Protection line,
    /// its Other backups card and its Snapshots split all count it from
    /// here, so no two of them can disagree.
    var otherBackupsCount: Int {
        others.reduce(0) { $0 + $1.snapshots.count }
    }

    /// The groups a repository's page offers to adopt: plan-UUID groups no
    /// configuration sets up — a deleted plan's history, or one still
    /// running on another Mac. Not a moved plan's (its plan exists, so its
    /// page offers that instead) and not an untagged lineage's (it has no
    /// UUID to adopt). The same classification `AppModel.adoptDraft`'s
    /// guard reads.
    var adoptableGroups: [OtherBackupsGroup] {
        others.filter { group in
            guard case .plan = group else { return false }
            return formerPlan(of: group) == nil
        }
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
    func otherLabels(
        repositories: [Repository],
        localHost: String
    ) -> [OtherBackupsGroup.ID: SnapshotLineage.Label] {
        OtherBackupsGroup.labels(for: others, plans: allPlans, repositories: repositories, localHost: localHost)
    }

    /// How a backup is named where one backup is named — the restore pane's
    /// header, a whole-backup restore — so it matches the place the sidebar
    /// shows it: its plan's name, with the folders when the plan's backups
    /// here span more than one set of them and the Mac when more than one
    /// Mac made them; under Other backups, its group's label.
    func label(of record: Snapshot, repositories: [Repository], localHost: String) -> SnapshotLineage.Label? {
        guard let planID = Self.owner(of: record, among: plans),
              let plan = plans.first(where: { $0.id == planID })
        else { return otherLabels(repositories: repositories, localHost: localHost)[record.otherGroupID] }
        let lineages = SnapshotLineage.grouping(byPlan[planID] ?? [])
        var label = SnapshotLineage.labels(for: lineages, plans: [plan])[record.lineageKey]
        label?.title = plan.name.isEmpty ? "Untitled Plan" : plan.name
        return label
    }

    /// The one configured plan a group under Other backups belongs to: it
    /// backs up to another repository now, which is why its backups here are
    /// not under it. Nil for a group no configuration sets up (a deleted
    /// plan's, or one still running on another Mac) and for an untagged
    /// lineage.
    func formerPlan(of group: OtherBackupsGroup) -> BackupPlan? {
        guard case let .plan(id, _) = group else { return nil }
        return allPlans.first { $0.id == id }
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
    /// Plan-UUID groups under Other backups whose records are showing — the
    /// plan folds' own syntax (closed until opened), where the untagged
    /// lineages' folds are the sidebar's view state and start open.
    var otherGroups: Set<OtherGroupFoldID> = []
    /// Folders open in the Files view's tree. A plan's own fold is `plans`
    /// in both modes: open is open, whatever it opens onto.
    var folders: Set<FileNode> = []

    /// A plan-UUID group's Files tree in view: its repository's Other
    /// backups, the group's fold, and `root` — the folder its tree opens
    /// at — open. The group's page's and menu's Show Files.
    mutating func revealFiles(ofGroup planID: UUID, in repositoryID: UUID, root: FileNode?) {
        otherBackups.insert(repositoryID)
        otherGroups.insert(OtherGroupFoldID(repositoryID: repositoryID, planID: planID))
        if let root { folders.insert(root) }
    }

    /// Opens the fold `record` sits in — its plan's, or its repository's
    /// Other backups and, under it, the plan-UUID group that holds it.
    /// `plans` are the repository's own.
    mutating func reveal(_ record: Snapshot, in repositoryID: UUID, plans repositoryPlans: [BackupPlan]) {
        if let planID = BackupShelves.owner(of: record, among: repositoryPlans) {
            plans.insert(planID)
        } else {
            otherBackups.insert(repositoryID)
            if let planID = record.planID {
                otherGroups.insert(OtherGroupFoldID(repositoryID: repositoryID, planID: planID))
            }
        }
    }
}

/// A plan-UUID group under one repository's Other backups: the same plan can
/// have left backups in two repositories, and each group folds on its own.
struct OtherGroupFoldID: Hashable {
    let repositoryID: UUID
    let planID: UUID
}
