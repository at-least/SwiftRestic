import Foundation

/// What the sidebar lists under one repository, in order. The repository's
/// own row is not one of them: it is the parent, always shown, and never
/// collapses — its children are always in view.
enum SidebarChild: Hashable {
    case plan(UUID)
    /// "New Backup Plan…", only while the repository has no plan: the place
    /// its plans would be names the way to its first one.
    case addPlan
    /// The node whose children are the repository's dated backups.
    case restore
}

/// The sidebar's shape, as rules apart from the view so they can be tested.
enum SidebarTree {
    static func children(of repositoryID: UUID, in plans: [BackupPlan]) -> [SidebarChild] {
        let own = plans.filter { $0.repositoryID == repositoryID }.map { SidebarChild.plan($0.id) }
        return (own.isEmpty ? [.addPlan] : own) + [.restore]
    }

    /// Where the window lands at launch and after its pane disappears: the
    /// first repository's page — each repository's page is its overview —
    /// or the welcome when there is no repository.
    static func landingSelection(repositories: [Repository]) -> SidebarItem? {
        repositories.first.map { .repository($0.id) }
    }
}
