import Foundation

/// What a plan's page offers from the index: the rebuildable folders its
/// newest backup holds (`RebuildableFolder`) and the paths it skips by name
/// that its earlier backups still hold (`EarlierBackupItem`), each with the
/// index's failure in its place when the read threw.
struct PlanIndexOffers: Equatable {
    var planID: UUID
    var rebuildable: [RebuildableFolder] = []
    var rebuildableFailure: String?
    var inEarlierBackups: [EarlierBackupItem] = []
    var inEarlierBackupsFailure: String?
    /// Whether the index had read every listed backup when this round
    /// began: until it has, a later round may find more.
    var isIndexComplete = false

    @MainActor
    static func read(planID: UUID, model: AppModel) async -> PlanIndexOffers {
        var offers = PlanIndexOffers(planID: planID)
        if let repositoryID = model.plan(id: planID)?.repositoryID {
            // Asked before the offers: a completion between the two costs
            // one more round, never a missed one.
            offers.isIndexComplete = await model.indexIsComplete(repositoryID: repositoryID)
        }
        do {
            offers.rebuildable = try await model.rebuildableFolders(planID: planID)
        } catch {
            offers.rebuildableFailure = error.localizedDescription
        }
        do {
            offers.inEarlierBackups = try await model.itemsInEarlierBackups(planID: planID)
        } catch {
            offers.inEarlierBackupsFailure = error.localizedDescription
        }
        return offers
    }

    /// Reads, hands each round to `deliver`, and reads again every
    /// `interval` while the index is still reading backups: no signal says
    /// when it finishes (seen in the app: a fresh index read both backups
    /// seconds after the page's one read, which found nothing indexed yet).
    /// Ends with the round that found the index complete, or on cancel.
    @MainActor
    static func keepReading(
        planID: UUID,
        model: AppModel,
        interval: Duration = FilesTree.recheckInterval,
        deliver: (PlanIndexOffers) -> Void
    ) async {
        while !Task.isCancelled {
            let offers = await read(planID: planID, model: model)
            guard !Task.isCancelled else { return }
            deliver(offers)
            if offers.isIndexComplete { return }
            try? await Task.sleep(for: interval)
        }
    }
}
