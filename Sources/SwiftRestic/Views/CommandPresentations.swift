import SwiftUI

/// Every command's confirmation, wherever it is asked from: one dialog with
/// the model's words (`AppModel.confirmationCopy(for:)`), so no two surfaces
/// word one action two ways; no surface adds a dialog of its own. A modifier
/// of its own because RootView's chain sits at the compiler's type-check
/// limit.
struct CommandPresentations: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var pendingConfirmation: CommandConfirmation?

    func body(content: Content) -> some View {
        // Read on every render: the delete message says whether a run will be
        // stopped, and a run can start or end while the dialog is up.
        // A target gone while its question is up takes the question with it:
        // its button would act on nothing.
        let copy = pendingConfirmation.flatMap { model.confirmationCopy(for: $0) }
        let dialog = copy == nil ? nil : pendingConfirmation
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
    }

    @ViewBuilder
    private func actions(for confirmation: CommandConfirmation) -> some View {
        switch confirmation {
        case let .deletePlan(id):
            Button("Remove Plan") { model.deletePlan(id: id) }
        case let .deleteRepository(id):
            Button("Remove") { model.deleteRepository(id: id) }
        }
    }
}
