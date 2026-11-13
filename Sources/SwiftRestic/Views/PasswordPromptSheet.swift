import SwiftUI

/// The fix for a refused password (`RunFix.enterPassword`): the password
/// alone, checked by restic before the sheet closes
/// (`AppModel.enterPassword`). Edit Location… keeps the whole editor.
struct PasswordPromptSheet: View {
    @Environment(AppModel.self) private var model

    let repository: Repository

    var body: some View {
        PasswordPrompt(
            prompt: "Enter the password for “\(model.label(of: repository))”.",
            save: { try await model.enterPassword($0, forRepository: repository.id) }
        )
    }
}

/// The fix for a network share that refused to reconnect
/// (`RunFix.enterSharePassword`): its password alone.
/// Saving reruns the failed backups that needed the share
/// (`AppModel.saveNetworkShare`).
struct SharePasswordPromptSheet: View {
    @Environment(AppModel.self) private var model

    let share: NetworkShare

    var body: some View {
        PasswordPrompt(
            prompt: "Enter the password for the network share “\(share.url)”.",
            save: { try await model.saveNetworkShare(MountedShare(volumeName: share.volumeName, url: share.url), password: $0) }
        )
    }
}

private struct PasswordPrompt: View {
    @Environment(\.dismiss) private var dismiss

    let prompt: String
    let save: @MainActor (String) async throws -> Void

    @State private var password = ""
    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                SecureField("Password", text: $password)
                    .accessibilityIdentifier(AccessibilityID.PasswordPrompt.password)
                    .disabled(isWorking)
                // A form's inline error: red words under the field it is
                // about, no glyph — the octagon is a failed run's.
                if let failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(Theme.danger)
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
                Button("Save Password") { Task { await submit() } }
                    .accessibilityIdentifier(AccessibilityID.PasswordPrompt.save)
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

    private func submit() async {
        guard !password.isEmpty, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        failure = nil
        do {
            try await save(password)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
