import Foundation

/// What the page of one group under Other backups says above its backups.
struct OtherGroupPageSummary: Equatable {
    /// `OtherBackupsGroup.labels`' title, so page and sidebar row agree.
    var title: String
    var explanation: String
    var isAdoptable: Bool

    /// `isMovedPlan`: the group's UUID names a plan set up in another
    /// repository.
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
            // Another Mac's living plan and a deleted plan leave the same tag
            // behind, so the sentence offers both.
            explanation = "From a plan that isn’t set up here — removed, or still running on another Mac."
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
