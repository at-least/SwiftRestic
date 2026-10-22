import SwiftUI

/// Identifies Apply Retention Now…'s sheet by the plan it previews.
struct RetentionTarget: Identifiable, Equatable {
    let planID: UUID
    var id: UUID { planID }
}

/// Identifies Check…'s sheet by the repository it checks.
private struct CheckTarget: Identifiable {
    let repositoryID: UUID
    var id: UUID { repositoryID }
}

/// Every destructive confirmation, once, Check…'s sheet and Apply Retention
/// Now…'s sheet —
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
        // Check asks how much data to read as well, which an alert's three
        // buttons cannot hold with a Cancel beside them: it is a sheet.
        let checkTarget: CheckTarget? = if case let .check(id) = pendingConfirmation { CheckTarget(repositoryID: id) } else { nil }
        let dialog = checkTarget == nil ? pendingConfirmation : nil
        return content
            .confirmationDialog(
                copy?.title ?? "",
                isPresented: Binding(
                    get: { dialog != nil },
                    set: { if !$0 { pendingConfirmation = nil } }
                ),
                titleVisibility: .visible,
                presenting: dialog
            ) { confirmation in
                actions(for: confirmation)
            } message: { _ in
                Text(copy?.message ?? "")
            }
            .sheet(item: Binding(
                get: { checkTarget },
                set: { if $0 == nil { pendingConfirmation = nil } }
            )) { target in
                CheckSheet(copy: copy) { readDataPercent in
                    check(target.repositoryID, readDataPercent: readDataPercent)
                }
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
            Button("Delete Plan") { model.deletePlan(id: id) }
        case let .removeRepository(id):
            Button("Remove") { model.deleteRepository(id: id) }
        case .check:
            // A sheet of its own (CheckSheet); never shown as a dialog.
            EmptyView()
        case let .prune(id):
            Button("Clean Up") {
                model.runMaintenance(repositoryID: id, task: .prune)
                showMaintenance(of: id)
            }
        case let .unlock(id):
            // Destructive, unlike the others: the harm is one the person
            // did not choose — a lock another Mac still holds.
            Button("Unlock", role: .destructive) { model.unlockRepository(id: id) }
        case let .rebuildIndex(id):
            Button("Rebuild") { model.rebuildIndex(repositoryID: id) }
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

/// Check…: the confirmation's title and sentence, and how much of the
/// backed-up data to read back — none checks the structure alone.
private struct CheckSheet: View {
    @Environment(\.dismiss) private var dismiss
    let copy: ConfirmationCopy?
    let run: (Int) -> Void
    @State private var readDataPercent = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(copy?.title ?? "")
                .font(.headline)
            Picker("Data to read", selection: $readDataPercent) {
                Text("Structure only").tag(0)
                Text("5% of the data").tag(5)
                Text("All of the data").tag(100)
            }
            .fixedSize()
            .help("Reading data back finds damage the structure check misses, and takes longer.")
            Text(copy?.message ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Check") {
                    run(readDataPercent)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
