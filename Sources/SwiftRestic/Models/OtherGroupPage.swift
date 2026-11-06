import Foundation

/// What the page of one group under Other backups says above its backups,
/// derived once here so the page and the sidebar's words for the same group
/// (`OtherBackupsGroup.labels`, which names it) can never disagree.
struct OtherGroupPageSummary: Equatable {
    /// The group's label title — the page's name is the sidebar row's.
    var title: String
    var explanation: String
    var isAdoptable: Bool

    /// `snapshots` are the group's, never empty — a group exists only around
    /// backups. `isMovedPlan`: the group's UUID names a plan set up in
    /// another repository.
    init(
        snapshots: [Snapshot],
        title: String,
        isMovedPlan: Bool,
        isAdoptable: Bool,
        planID: UUID?
    ) {
        self.title = title
        self.isAdoptable = isAdoptable

        if planID == nil {
            explanation = snapshots.count == 1
                ? "Made outside SwiftRestic, so it can’t be continued."
                : "Made outside SwiftRestic, so they can’t be continued."
        } else if isMovedPlan {
            explanation = snapshots.count == 1
                ? "From a plan that now backs up somewhere else, so it can’t be continued here."
                : "From a plan that now backs up somewhere else, so they can’t be continued here."
        } else {
            // Neither cause is knowable from the repository (another Mac's
            // living plan and a deleted plan leave the same tag behind), so
            // the sentence offers both without choosing.
            explanation = "From a plan that isn’t set up here — removed, or still running on another Mac."
            // A history of several folders, from builds that let a plan hold
            // a list: a plan is one path now, so there is no plan to adopt it
            // into.
            if !isAdoptable {
                explanation += snapshots.count == 1
                    ? " It holds several folders and a plan backs up one, so it can’t be continued."
                    : " They hold several folders and a plan backs up one, so they can’t be continued."
            }
        }
    }
}

/// What a repository's page offers for the histories a plan on this Mac can
/// continue: one sentence, and one group to start from.
struct ContinueBackupsPrompt: Equatable {
    var text: String
    var isOne: Bool
    var firstPlanID: UUID
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

    /// The backups the plan editor counts as `planID`'s: a configured plan's
    /// shelf, where its page counts them, so a backup two plans' tags claim
    /// counts once; a plan being adopted has no shelf yet, so its group
    /// under Other backups, the history it is about to own.
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
        // The label that named the row names the page; otherLabels names
        // every group it is given.
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
