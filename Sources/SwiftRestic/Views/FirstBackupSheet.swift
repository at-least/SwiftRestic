import AppKit
import SwiftUI

/// Back Up a Folder… in three questions: what, where, a password. Everything
/// else is a plan's and a repository's defaults, and lives in their editors.
/// With locations set up, where is one of them, and they already have
/// their passwords.
struct FirstBackupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let onCreated: (UUID) -> Void
    /// An SFTP server or S3-compatible storage: the repository editor on
    /// that kind, carrying what the sheet already holds.
    let onServerOrCloud: (FirstBackupHandoff) -> Void

    @State private var source: String
    @State private var destination: FirstBackupDestination?
    @State private var disks: [ExternalDisk] = []
    @State private var password = ""
    @State private var confirmPassword = ""
    /// `EditorRequirements.holdsBackups` for the chosen folder, read off
    /// the main actor: a sleeping disk can hold the stat for seconds.
    @State private var holdsBackups = false
    @State private var isWorking = false
    @State private var failure: String?

    private enum Choice: Hashable {
        case none
        case destination(FirstBackupDestination)
        case otherFolder
        case server(Repository.Kind)
    }

    /// `source` is the folder the open panel already answered: the sheet
    /// opens after it (`RootView.startBackUpAFolder`). `destination` is what
    /// it opens on, nil to ask.
    init(
        source: String,
        destination: FirstBackupDestination?,
        onCreated: @escaping (UUID) -> Void,
        onServerOrCloud: @escaping (FirstBackupHandoff) -> Void
    ) {
        _source = State(initialValue: source)
        _destination = State(initialValue: destination)
        self.onCreated = onCreated
        self.onServerOrCloud = onServerOrCloud
    }

    var body: some View {
        let missingRequirement = self.missingRequirement
        VStack(spacing: 0) {
            Form {
                Section {
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
                    destinationPicker
                }
                passwordSection
                if let notice = model.fullDiskAccessNotice(for: source) {
                    Section {
                        Text(notice)
                            .fixedSize(horizontal: false, vertical: true)
                        FullDiskAccessButton()
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isWorking)

            Divider()

            if let failure {
                // A form's inline error: red text, without a glyph.
                Text(failure)
                    .foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top], 12)
            }
            HStack {
                if let reason = missingRequirement, !isAwaitingAnswer {
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
                    .modifier(TileHelp(help: missingRequirement))
            }
            .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 540)
        .onAppear(perform: readDisks)
        .task(id: chosenFolder) {
            guard let folder = chosenFolder else {
                holdsBackups = false
                return
            }
            let holds = await Task.detached { EditorRequirements.holdsBackups(atLocalPath: folder) }.value
            guard !Task.isCancelled else { return }
            holdsBackups = holds
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in readDisks() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in readDisks() }
    }

    private var repositories: [Repository] { model.configuration.repositories }

    /// The disks a new location could go on: one already holding a location
    /// set up here is that location's row.
    private var newDisks: [ExternalDisk] {
        let taken = Set(repositories.filter { $0.kind == .local }.map(\.resolvedLocalPath))
        return disks.filter { !taken.contains($0.repositoryFolder) }
    }

    private var chosenFolder: String? {
        if case let .folder(folder) = destination { return folder }
        return nil
    }

    /// Every place the backups can go, in one pop-up: the locations set up
    /// here, the disks, a folder chosen in a panel, and the repository
    /// editor's server kinds.
    private var destinationPicker: some View {
        let newDisks = self.newDisks
        return Picker("Back up to", selection: choice) {
            if destination == nil { Text("None").tag(Choice.none) }
            ForEach(repositories) { repository in
                Text(model.label(of: repository)).tag(Choice.destination(.location(repository.id)))
            }
            if !repositories.isEmpty, !newDisks.isEmpty { Divider() }
            ForEach(newDisks, id: \.path) { disk in
                Text(disk.name).tag(Choice.destination(.folder(disk.repositoryFolder)))
            }
            if let folder = chosenFolder, !newDisks.contains(where: { $0.repositoryFolder == folder }) {
                Text((folder as NSString).abbreviatingWithTildeInPath).tag(Choice.destination(.folder(folder)))
            }
            Divider()
            Text("Other Folder…").tag(Choice.otherFolder)
            Text("SFTP Server…").tag(Choice.server(.sftp))
            Text("S3-Compatible Storage…").tag(Choice.server(.s3))
        }
        .accessibilityIdentifier(AccessibilityID.FirstBackup.destination)
    }

    /// None for a location set up here: it has its password. One field for
    /// a folder that already holds backups: theirs.
    @ViewBuilder
    private var passwordSection: some View {
        if chosenFolder != nil {
            if holdsBackups {
                Section {
                    SecureField("Password for these backups", text: $password, prompt: Text("Required"))
                        .accessibilityIdentifier(AccessibilityID.FirstBackup.password)
                }
            } else {
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
            }
        }
    }

    private var choice: Binding<Choice> {
        Binding {
            destination.map(Choice.destination) ?? .none
        } set: { choice in
            switch choice {
            case .none: break
            case let .destination(chosen): destination = chosen
            case .otherFolder:
                // After the picker's menu has finished tracking: a panel run
                // from inside it got no key at all (not Esc, not ⌘⇧G) while
                // the menu stayed up behind it. Not a Task or
                // DispatchQueue.main: both still run inside the tracking, in
                // its run-loop mode.
                let destination = $destination
                RunLoop.main.perform(inModes: [.default]) {
                    MainActor.assumeIsolated {
                        if let url = FilePicker.chooseDirectory(message: Self.folderPanelMessage) {
                            destination.wrappedValue = .folder(url.path)
                        }
                    }
                }
            case let .server(kind):
                // No wait for the menu, unlike the panel: the editor opens
                // in this sheet's onDismiss, after its closing animation.
                onServerOrCloud(FirstBackupHandoff(
                    kind: kind, source: source, password: password, confirmPassword: confirmPassword
                ))
                dismiss()
            }
        }
    }

    private static let folderPanelMessage = "Choose where to keep the backups"

    private var missingRequirement: String? {
        FirstBackupDestination.requirement(
            source: source,
            destination: destination,
            password: password,
            confirmPassword: confirmPassword,
            holdsBackups: holdsBackups,
            plans: model.configuration.plans,
            repositories: repositories
        )
    }

    /// A question still open shows as itself (None, an empty Required
    /// field) and the greyed Back Up as its tooltip; the line beside the
    /// button is for what a glance can't see.
    private var isAwaitingAnswer: Bool {
        source.isEmpty || destination == nil || (chosenFolder != nil && password.isEmpty)
    }

    private func readDisks() {
        disks = ExternalDisk.mounted()
        // One disk is the answer; two are a question.
        if destination == nil, disks.count == 1 { destination = .folder(disks[0].repositoryFolder) }
    }

    private func backUp() async {
        guard missingRequirement == nil, !isWorking, let destination else { return }
        isWorking = true
        defer { isWorking = false }
        failure = nil
        do {
            let planID = switch destination {
            case let .location(repositoryID):
                model.createFirstPlan(source: source, repositoryID: repositoryID)
            case let .folder(folder):
                try await model.createFirstBackup(source: source, folder: folder, password: password)
            }
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
    /// The editor opens on it, with no Type pop-up.
    let kind: Repository.Kind
    let source: String
    let password: String
    let confirmPassword: String
}
