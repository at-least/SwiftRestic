import AppKit
import SwiftUI

/// The first backup in three questions: what, where, a password. Everything
/// else is a plan's and a repository's defaults, and lives in their editors.
struct FirstBackupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let onCreated: (UUID) -> Void
    /// A server or cloud storage: the repository editor's kinds.
    let onOtherLocation: () -> Void

    @State private var source = ""
    @State private var folder = ""
    @State private var disks: [ExternalDisk] = []
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isWorking = false
    @State private var failure: String?

    private static let otherTag = "\u{0}other"

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("What do you want to back up?") {
                    LabeledContent("Folder") {
                        HStack {
                            Text(source.isEmpty ? "None" : (source as NSString).abbreviatingWithTildeInPath)
                                .foregroundStyle(source.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…") {
                                if let url = FilePicker.chooseDirectory(message: "Choose the folder to back up") {
                                    source = url.path
                                }
                            }
                        }
                    }
                }
                Section("Where should the backups go?") {
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
                    Button("Use a Server or Cloud Storage…") {
                        onOtherLocation()
                        dismiss()
                    }
                    .buttonStyle(.link)
                }
                Section("Set a password") {
                    SecureField("Password", text: $password, prompt: Text("Required"))
                    SecureField("Confirm password", text: $confirmPassword, prompt: Text("Required"))
                    Text("Everything is encrypted with it, and it can’t be recovered — keep it in your password manager.")
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
                Label(failure, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top], 12)
            }
            HStack {
                if let reason = missingRequirement {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button("Back Up") { Task { await backUp() } }
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
            if let url = FilePicker.chooseDirectory(message: "Choose where to keep the backups") {
                folder = url.path
            }
        }
    }

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
