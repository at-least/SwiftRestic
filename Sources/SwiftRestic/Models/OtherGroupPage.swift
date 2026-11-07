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
