import SwiftUI

/// The fix for a refused password (`RunFix.enterPassword`): the password
/// alone, checked by restic before the sheet closes
/// (`AppModel.enterPassword`). Edit Location… keeps the whole editor.
struct PasswordPromptSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let repository: Repository

    @State private var password = ""
    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter the password for “\(model.label(of: repository))”.")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password)
                .accessibilityIdentifier(AccessibilityID.PasswordPrompt.password)
                .disabled(isWorking)
            if let failure {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(Theme.danger)
                        .accessibilityHidden(true)
                    Text(failure)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(AccessibilityID.PasswordPrompt.failure)
                }
            }
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button("Open") { Task { await open() } }
                    .accessibilityIdentifier(AccessibilityID.PasswordPrompt.open)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || isWorking)
            }
        }
        .padding(20)
        .frame(width: 420)
        // A refusal is about the password that was typed, not the next one.
        .onChange(of: password) { failure = nil }
    }

    private func open() async {
        guard !password.isEmpty, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        failure = nil
        do {
            try await model.enterPassword(password, forRepository: repository.id)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
