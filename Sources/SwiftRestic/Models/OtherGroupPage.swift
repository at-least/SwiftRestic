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

        let restorable = snapshots.count == 1 ? "You can restore from it." : "You can restore from them."
        if planID == nil {
            explanation = "Made by another app. \(restorable)"
        } else if isMovedPlan {
            explanation = "From a plan that now backs up to another location. \(restorable)"
        } else if !isAdoptable {
            // Not adoptable here only because a plan backs up one folder.
            explanation = "From a backup of several folders. \(restorable)"
        } else {
            // Another Mac's living plan and a deleted plan leave the same tag
            // behind, so the sentence offers both.
            explanation = "From a plan that isn’t set up here — removed, or still running on another Mac."
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
