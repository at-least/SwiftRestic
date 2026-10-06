import SwiftUI

/// Identifies Apply Retention Now…'s sheet by the plan it previews.
struct RetentionTarget: Identifiable, Equatable {
    let planID: UUID
    var id: UUID { planID }
}

/// Every destructive confirmation, once, and Apply Retention Now…'s sheet —
/// wherever they are asked from: the Plan and Repository menus, the panes'
/// toolbars, the sidebar's menus. One dialog with the model's words
/// (`AppModel.confirmationCopy(for:)`), so no two surfaces can word one
/// action two ways, and none adds a dialog of its own. A modifier of its
/// own because RootView's chain sits at the compiler's type-check limit.
struct CommandPresentations: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Binding var pendingConfirmation: CommandConfirmation?
    @Binding var retentionTarget: RetentionTarget?

    func body(content: Content) -> some View {
        // Read on every render: the delete message says whether a run will be
        // stopped, and a run can start or end while the dialog is up.
        let copy = pendingConfirmation.flatMap { model.confirmationCopy(for: $0) }
        return content
            .confirmationDialog(
                copy?.title ?? "",
                isPresented: Binding(
                    get: { pendingConfirmation != nil },
                    set: { if !$0 { pendingConfirmation = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingConfirmation
            ) { confirmation in
                actions(for: confirmation)
            } message: { _ in
                Text(copy?.message ?? "")
            }
            .sheet(item: $retentionTarget) { target in
                ApplyRetentionSheet(planID: target.planID)
                    .environment(model)
            }
    }

    @ViewBuilder
    private func actions(for confirmation: CommandConfirmation) -> some View {
        switch confirmation {
        case let .deletePlan(id):
            Button("Delete Plan", role: .destructive) { model.deletePlan(id: id) }
        case let .removeRepository(id):
            Button("Remove", role: .destructive) { model.deleteRepository(id: id) }
        case let .check(id):
            Button("Check Structure") { check(id, readDataPercent: 0) }
            Button("Check + Read 5% of Data") { check(id, readDataPercent: 5) }
            Button("Check + Read All Data") { check(id, readDataPercent: 100) }
            // Three plain choices and no cancel of their own: SwiftUI then
            // adds its dismiss button titled "OK", which under "Check the
            // integrity of …?" reads as a yes.
            Button("Cancel", role: .cancel) {}
        case let .prune(id):
            Button("Prune", role: .destructive) {
                model.runMaintenance(repositoryID: id, task: .prune)
                showMaintenance(of: id)
            }
        case let .unlock(id):
            Button("Remove Locks", role: .destructive) { model.unlockRepository(id: id) }
        case let .rebuildIndex(id):
            Button("Rebuild Index", role: .destructive) { model.rebuildIndex(repositoryID: id) }
        }
    }

    private func check(_ id: UUID, readDataPercent: Int) {
        model.runMaintenance(repositoryID: id, task: .check, readDataPercent: readDataPercent)
        showMaintenance(of: id)
    }

    /// The repository page's Maintenance card is the only place a check or
    /// prune shows its progress — elapsed time, restic's last line, Cancel —
    /// and a check that passes posts no banner. Asked from anywhere else,
    /// it would run from start to finish with nothing in the window.
    /// (Unlock and a rebuild announce themselves, or have nothing to show.)
    private func showMaintenance(of id: UUID) {
        if router.selection != .repository(id) {
            router.selection = .repository(id)
        }
    }
}
