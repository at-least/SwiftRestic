import AppKit
import SwiftUI

/// The first backup in three questions: what, where, a password. Everything
/// else is a plan's and a repository's defaults, and lives in their editors.
struct FirstBackupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let onCreated: (UUID) -> Void
    /// A server or cloud storage: the repository editor's kinds, carrying
    /// what the sheet already holds.
    let onOtherLocation: (FirstBackupHandoff) -> Void

    @State private var source: String
    @State private var folder = ""
    @State private var disks: [ExternalDisk] = []
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isWorking = false
    @State private var failure: String?

    private static let otherTag = "\u{0}other"

    /// `source` is the folder the open panel already answered: the sheet
    /// opens after it (`RootView.startNewPlan`).
    init(source: String, onCreated: @escaping (UUID) -> Void, onOtherLocation: @escaping (FirstBackupHandoff) -> Void) {
        _source = State(initialValue: source)
        self.onCreated = onCreated
        self.onOtherLocation = onOtherLocation
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("What do you want to back up?") {
                    LabeledContent("Folder") {
                        HStack {
                            Text((source as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .accessibilityIdentifier(AccessibilityID.FirstBackup.source)
                            Button("Change…") {
                                if let url = FilePicker.chooseDirectory(message: "Choose the folder to back up") {
                                    source = url.path
                                }
                            }
                            .accessibilityIdentifier(AccessibilityID.FirstBackup.changeSource)
                        }
                    }
                }
                Section("Where should the backups go?") {
                    if disks.isEmpty {
                        // A menu of only Choose and Other… is one button.
                        LabeledContent("Disk") {
                            HStack {
                                if !folder.isEmpty {
                                    Text((folder as NSString).abbreviatingWithTildeInPath)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Button(folder.isEmpty ? "Choose…" : "Change…") {
                                    if let url = FilePicker.chooseDirectory(message: Self.folderPanelMessage) {
                                        folder = url.path
                                    }
                                }
                            }
                        }
                    } else {
                        Picker("Disk", selection: folderChoice) {
                            if folder.isEmpty { Text("Choose").tag("") }
                            ForEach(disks, id: \.path) { disk in
                                Text(disk.name).tag(disk.repositoryFolder)
                            }
                            if !folder.isEmpty, !disks.contains(where: { $0.repositoryFolder == folder }) {
                                Text((folder as NSString).abbreviatingWithTildeInPath).tag(folder)
                            }
                            Divider()
                            Text("Other…").tag(Self.otherTag)
                        }
                        .accessibilityIdentifier(AccessibilityID.FirstBackup.disk)
                    }
                    Button("Use a Server or Cloud Storage…") {
                        onOtherLocation(FirstBackupHandoff(
                            source: source, password: password, confirmPassword: confirmPassword
                        ))
                        dismiss()
                    }
                    .buttonStyle(.link)
                }
                Section("Set a password") {
                    SecureField("Password", text: $password, prompt: Text("Required"))
                        .accessibilityIdentifier(AccessibilityID.FirstBackup.password)
                    SecureField("Confirm password", text: $confirmPassword, prompt: Text("Required"))
                        .accessibilityIdentifier(AccessibilityID.FirstBackup.confirmPassword)
                    Text(PasswordWords.recoveryWarning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.fullDiskAccess != .granted {
                    Section {
                        Text("Without Full Disk Access, macOS hides Documents, Desktop and Mail from backups.")
                            .fixedSize(horizontal: false, vertical: true)
                        FullDiskAccessButton()
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isWorking)

            Divider()

            if let failure {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(Theme.danger)
                        .accessibilityHidden(true)
                    Text(failure)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top], 12)
            }
            HStack {
                if let reason = missingRequirement {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.FirstBackup.requirement)
                }
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button("Back Up") { Task { await backUp() } }
                    .accessibilityIdentifier(AccessibilityID.FirstBackup.backUp)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(missingRequirement != nil || isWorking)
            }
            .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 540)
        .onAppear(perform: readDisks)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in readDisks() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in readDisks() }
    }

    private var folderChoice: Binding<String> {
        Binding {
            folder
        } set: { choice in
            guard choice == Self.otherTag else {
                folder = choice
                return
            }
            // After the picker's menu has finished tracking: a panel run from
            // inside it got no key at all (not Esc, not ⌘⇧G) while the menu
            // stayed up behind it. Not a Task or DispatchQueue.main: both
            // still run inside the tracking, in its run-loop mode.
            let folder = $folder
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated {
                    if let url = FilePicker.chooseDirectory(message: Self.folderPanelMessage) {
                        folder.wrappedValue = url.path
                    }
                }
            }
        }
    }

    private static let folderPanelMessage = "Choose where to keep the backups"

    private var missingRequirement: String? {
        EditorRequirements.firstBackup(
            source: source,
            folder: folder,
            password: password,
            confirmPassword: confirmPassword,
            among: model.configuration.repositories
        )
    }

    private func readDisks() {
        disks = ExternalDisk.mounted()
        // One disk is the answer; two are a question.
        if folder.isEmpty, disks.count == 1 { folder = disks[0].repositoryFolder }
    }

    private func backUp() async {
        guard missingRequirement == nil, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        failure = nil
        do {
            let planID = try await model.createFirstBackup(source: source, folder: folder, password: password)
            onCreated(planID)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// What the first-run sheet hands the repository editor when the backups go
/// to a server or cloud storage: the plan follows the editor's Add on
/// today's defaults (`AppModel.createFirstPlan`).
struct FirstBackupHandoff {
    let source: String
    let password: String
    let confirmPassword: String
}
