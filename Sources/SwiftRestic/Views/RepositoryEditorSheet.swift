import SwiftUI

/// Add or edit a repository, including the one-time `restic init`.
struct RepositoryEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Repository
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var providerSecret = ""
    /// The state the sheet settled into after loading, including the secrets
    /// pulled from the Keychain. Cancel compares against it so Esc cannot
    /// silently discard a half-filled SFTP form.
    @State private var initial: Repository?
    @State private var initialPassword = ""
    @State private var initialProviderSecret = ""
    @State private var status: Status?
    @State private var isWorking = false
    @State private var isConfirmingDiscard = false
    @State private var tab: Tab = .repository

    private let isNew: Bool

    private enum Tab: Hashable { case repository, hooks }

    init(repository: Repository) {
        _draft = State(initialValue: repository)
        isNew = repository.name.isEmpty && repository.localPath.isEmpty
        #if DEBUG
        // Debug-only: lets a capture run land on the Hooks tab.
        if ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_SHEET"] == "repositoryHooks" {
            _tab = State(initialValue: .hooks)
        }
        #endif
    }

    private enum Status: Equatable {
        case ok(String)
        case failure(String)

        var isError: Bool { if case .failure = self { true } else { false } }
        var text: String {
            switch self {
            case let .ok(message), let .failure(message): message
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                settingsForm
                    .tabItem { Label("Repository", systemImage: "externaldrive") }
                    .tag(Tab.repository)
                HookEditor(hooks: $draft.hooks, events: BackupHook.Event.maintenanceEvents)
                    .padding(12)
                    .tabItem { Label("Hooks", systemImage: "terminal") }
                    .tag(Tab.hooks)
            }
            .padding(12)

            Divider()

            HStack {
                // A greyed Save or Test Connection owes the user the reason
                // at the button — a mismatched confirm password must not be
                // a hunt across fields.
                if let reason = missingRequirement {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Test Connection") { Task { await test(initializeIfMissing: false) } }
                    .disabled(!canSubmit || isWorking)
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Repository" : "Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || isWorking)
            }
            .padding(12)
        }
        // Resizable, not fixed: the SFTP notes pushed a fixed 600x660 sheet
        // into scrolling at default font sizes and buried the maintenance
        // section. A minimum keeps it usable; the user can grow it.
        .frame(minWidth: 600, idealWidth: 660, minHeight: 560, idealHeight: 660)
        .task {
            // Snapshot before the keychain await: an edit typed during the
            // load must already register as a change.
            initial = draft
            await loadExistingSecrets()
            // The stored secrets are the sheet's baseline, not edits to be
            // warned about.
            initialPassword = password
            initialProviderSecret = providerSecret
        }
        .confirmationDialog(
            "Discard changes?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("The repository has unsaved changes.")
        }
    }

    private var isDirty: Bool {
        if let initial, draft != initial { return true }
        if password != initialPassword { return true }
        if providerSecret != initialProviderSecret { return true }
        return false
    }

    private func cancel() {
        if isDirty {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private var settingsForm: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("Home backups"))
                // Grouped by how a restic backend is actually reached, so the
                // eight kinds read as three decisions instead of one wall.
                Picker("Type", selection: $draft.kind) {
                    Section("Local and direct") {
                        Text(Repository.Kind.local.displayName).tag(Repository.Kind.local)
                        Text(Repository.Kind.sftp.displayName).tag(Repository.Kind.sftp)
                    }
                    Section("Cloud storage") {
                        Text(Repository.Kind.s3.displayName).tag(Repository.Kind.s3)
                        Text(Repository.Kind.b2.displayName).tag(Repository.Kind.b2)
                        Text(Repository.Kind.azure.displayName).tag(Repository.Kind.azure)
                        Text(Repository.Kind.gcs.displayName).tag(Repository.Kind.gcs)
                    }
                    Section("Gateways") {
                        Text(Repository.Kind.rest.displayName).tag(Repository.Kind.rest)
                        Text(Repository.Kind.rclone.displayName).tag(Repository.Kind.rclone)
                    }
                }
            }

            Section("Location") { locationFields }

            Section("Encryption") {
                SecureField("Repository password", text: $password)
                if isNew {
                    SecureField("Confirm password", text: $confirmPassword)
                }
                Text(
                    isNew
                        ? "restic encrypts everything with this password. There is no recovery if you lose it — store it in your password manager."
                        : "Leave blank to keep the password already saved in your Keychain."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let label = draft.secretFieldLabel {
                Section("Credentials") {
                    if draft.kind == .sftp {
                        Text(label)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(
                            "SwiftRestic launches restic without a terminal, so it cannot answer an SSH passphrase prompt and does not inherit your ssh-agent. Use a key without a passphrase, or add the host to ~/.ssh/config with IdentityFile."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        SecureField(label, text: $providerSecret)
                    }
                }
            }

            Section("Maintenance") {
                Toggle("Check integrity periodically", isOn: $draft.maintenance.checkEnabled)
                Stepper(value: $draft.maintenance.checkIntervalDays, in: 1 ... 365) {
                    LabeledContent("Every", value: "\(draft.maintenance.checkIntervalDays) day(s)")
                }
                .disabled(!draft.maintenance.checkEnabled)
                Picker("Depth", selection: $draft.maintenance.checkReadDataPercent) {
                    Text("Structure only (fast)").tag(0)
                    Text("Read 5% of data").tag(5)
                    Text("Read 25% of data").tag(25)
                    Text("Read all data (slow)").tag(100)
                }
                .disabled(!draft.maintenance.checkEnabled)

                Toggle("Prune periodically", isOn: $draft.maintenance.pruneEnabled)
                Stepper(value: $draft.maintenance.pruneIntervalDays, in: 1 ... 365) {
                    LabeledContent("Every", value: "\(draft.maintenance.pruneIntervalDays) day(s)")
                }
                .disabled(!draft.maintenance.pruneEnabled)
                Text("Pruning reclaims the space that retention freed. It rewrites pack files, takes an exclusive lock and can run for a long time, so backups to this repository wait for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let status {
                Section {
                    Label(status.text, systemImage: status.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(status.isError ? Theme.danger : Theme.success)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Fields

    @ViewBuilder
    private var locationFields: some View {
        switch draft.kind {
        case .local:
            HStack {
                TextField("Folder", text: $draft.localPath, prompt: Text("/Volumes/Backup/restic"))
                Button("Choose…") {
                    if let url = FilePicker.chooseDirectory(message: "Choose the repository folder") {
                        draft.localPath = url.path
                    }
                }
            }
        case .sftp:
            TextField("User", text: $draft.sftpUser, prompt: Text("backup"))
            TextField("Host", text: $draft.sftpHost, prompt: Text("nas.local"))
            TextField("Path", text: $draft.sftpPath, prompt: Text("/volume1/restic"))
        case .s3:
            TextField("Endpoint", text: $draft.s3Endpoint, prompt: Text("s3.amazonaws.com"))
            TextField("Bucket", text: $draft.s3Bucket)
            TextField("Prefix (optional)", text: $draft.s3Prefix)
            TextField("Access key ID", text: $draft.s3AccessKeyID)
        case .b2:
            TextField("Bucket", text: $draft.b2Bucket)
            TextField("Prefix (optional)", text: $draft.b2Prefix)
            TextField("Account ID / key ID", text: $draft.b2AccountID)
        case .azure:
            TextField("Container", text: $draft.azureContainer)
            TextField("Prefix (optional)", text: $draft.azurePrefix)
            TextField("Account name", text: $draft.azureAccountName)
        case .gcs:
            TextField("Bucket", text: $draft.gcsBucket)
            TextField("Prefix (optional)", text: $draft.gcsPrefix)
            TextField("Project ID (optional)", text: $draft.gcsProjectID)
            HStack {
                TextField(
                    "Service account JSON",
                    text: $draft.gcsCredentialsPath,
                    prompt: Text("~/.config/gcloud/key.json")
                )
                Button("Choose…") {
                    if let url = FilePicker.chooseFile(message: "Choose the service account JSON file") {
                        draft.gcsCredentialsPath = url.path
                    }
                }
            }
            Text("restic reads the key file from disk itself, so the path is stored in your configuration rather than the Keychain. Keep the file readable only by you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .rest:
            TextField("URL", text: $draft.restURL, prompt: Text("https://user:pass@host:8000/"))
        case .rclone:
            TextField("Remote", text: $draft.rcloneRemote, prompt: Text("mydrive"))
            TextField("Path", text: $draft.rclonePath, prompt: Text("backups/mac"))
            Text("restic launches the rclone binary itself, so rclone has to be installed (`brew install rclone`) and its remote already configured with `rclone config`.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        LabeledContent("restic will use") {
            Text(draft.resticRepositoryString.isEmpty ? "—" : draft.resticRepositoryString)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    // MARK: - Logic

    private var canSubmit: Bool {
        guard draft.isConfigurationComplete else { return false }
        if isNew {
            return !password.isEmpty && password == confirmPassword
        }
        return true
    }

    private var missingRequirement: String? {
        EditorRequirements.repository(
            draft,
            password: password,
            confirmPassword: confirmPassword,
            isNew: isNew
        )
    }

    private func loadExistingSecrets() async {
        guard !isNew else { return }
        let secrets = await model.storedSecrets(for: draft.id)
        password = secrets.password ?? ""
        confirmPassword = password
        providerSecret = secrets.providerSecret ?? ""
    }

    private func effectivePassword() async -> String {
        password.isEmpty ? (await model.storedPassword(for: draft.id) ?? "") : password
    }

    /// Probes the repository, optionally running `restic init` when it is missing.
    @discardableResult
    private func test(initializeIfMissing: Bool) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        return await probe(initializeIfMissing: initializeIfMissing)
    }

    /// The probe itself, without touching `isWorking`: `save()` holds the flag
    /// across the probe *and* the persistence that follows, so the buttons stay
    /// disabled until the sheet actually closes and a second click cannot
    /// re-enter the middle of a save.
    private func probe(initializeIfMissing: Bool) async -> Bool {
        status = nil

        // restic shells out to rclone for this backend; catch a missing helper
        // here rather than letting it surface as an opaque failure from restic.
        if draft.requiresRcloneBinary, ResticBinary.locateHelper(named: "rclone") == nil {
            status = .failure("rclone is not installed. Install it with `brew install rclone`.")
            return false
        }

        do {
            let service = try model.service()
            let context = RepositoryContext(
                repository: draft,
                password: await effectivePassword(),
                providerSecret: providerSecret.isEmpty ? nil : providerSecret,
                settings: model.configuration.settings
            )

            if try await service.repositoryExists(context) {
                status = .ok("Connected to the existing repository.")
                return true
            }
            guard initializeIfMissing else {
                status = .failure("No repository at that location yet. Saving will create one.")
                return false
            }
            _ = try await service.initializeRepository(context)
            status = .ok("Created a new repository.")
            return true
        } catch {
            status = .failure(error.localizedDescription)
            return false
        }
    }

    private func save() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        // Creating the repository has to happen before we persist it, so a failed
        // init does not leave an unusable entry in the sidebar.
        if isNew {
            guard await probe(initializeIfMissing: true) else { return }
        }
        await model.upsert(
            repository: draft,
            password: password.isEmpty ? nil : password,
            providerSecret: draft.secretFieldLabel == nil || draft.kind == .sftp ? nil : providerSecret
        )
        await model.flushSave()
        await model.refreshSnapshots(repositoryID: draft.id)
        dismiss()
    }
}
