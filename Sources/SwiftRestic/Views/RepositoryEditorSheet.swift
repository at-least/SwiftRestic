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
    /// Whether this Mac holds a password for the repository: nil until the
    /// Keychain has answered, and still nil when its read failed — a failure
    /// is reported as itself, never read as "nothing stored".
    @State private var hasStoredPassword: Bool?
    @State private var status: Status?
    @State private var isWorking = false
    /// The edit Save could not verify. Save Anyway stands only while the
    /// sheet still holds that very edit; any change asks again.
    @State private var unverifiedEdit: Edit?
    /// Change Password's own fields: never part of Save or of the discard
    /// check — the change is its own act, done or not when its button is.
    @State private var isChangingPassword = false
    @State private var newPassword = ""
    @State private var confirmNewPassword = ""
    @State private var isConfirmingPasswordChange = false
    @State private var isConfirmingDiscard = false
    @State private var tab: Tab = .repository
    /// Remotes reported by the user's own rclone, or `nil` when unknown or
    /// unavailable — the Remote field then stays a plain text field.
    @State private var rcloneRemotes: [RcloneRemote]?

    private let isNew: Bool
    /// Told the new repository's id once it is created and saved — never on
    /// an edit, a cancel or a failed probe — so the window can open the
    /// page that offers its first plan.
    private let onCreated: (UUID) -> Void

    private enum Tab: Hashable { case repository, hooks }

    private struct Edit: Equatable {
        var draft: Repository
        var password: String
        var providerSecret: String
    }

    private var currentEdit: Edit {
        Edit(draft: draft, password: password, providerSecret: providerSecret)
    }

    /// Bounds Test Connection and Save's check: against a REST server that
    /// refuses connections restic 0.19.1 retried for over ten minutes, with
    /// the sheet's buttons grey all the while.
    private static let probeTimeout: TimeInterval = 60

    init(repository: Repository, onCreated: @escaping (UUID) -> Void = { _ in }) {
        isNew = repository.name.isEmpty && repository.localPath.isEmpty
        var repository = repository
        // A new repository prunes by default; one being edited keeps what
        // was saved for it.
        if isNew { repository.maintenance = .forNewRepository }
        _draft = State(initialValue: repository)
        self.onCreated = onCreated
        #if DEBUG
        // Debug-only: lets a capture run land on the Hooks tab.
        if ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_SHEET"] == "repositoryHooks" {
            _tab = State(initialValue: .hooks)
        }
        #endif
    }

    private enum Status: Equatable {
        case ok(String)
        /// An expected state, not a problem: a new repository's empty
        /// location, which Save fills.
        case info(String)
        case failure(String)

        var text: String {
            switch self {
            case let .ok(message), let .info(message), let .failure(message): message
            }
        }

        var symbolName: String {
            switch self {
            case .ok: "checkmark.circle.fill"
            case .info: "info.circle"
            case .failure: "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .ok: Theme.success
            case .info: .secondary
            case .failure: Theme.danger
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
            // Held while restic is asked: the probe checks the fields as
            // they were when it began, and Save then stores the fields as
            // they are — an edit typed in between would be saved unchecked,
            // under an answer about the location the fields no longer show.
            .disabled(isWorking)

            Divider()

            // Test Connection's answer, and Save's or Change Password's,
            // beside the buttons on either tab: at the end of the scrolled
            // form it landed below the fold, or behind the Hooks tab.
            if let status {
                Label(status.text, systemImage: status.symbolName)
                    .foregroundStyle(status.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top], 12)
            }

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
                // Cancel waits with Save while work is in flight: dismissing
                // mid-probe would leave a half-finished save — the init the
                // probe kicked off, the upsert after it — running for an
                // editor the user believes they cancelled out of.
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                if !isNew, unverifiedEdit == currentEdit {
                    // A server that is down while its path is being fixed
                    // must not block the fix; the answer above says what
                    // the check met.
                    Button("Save Anyway") { Task { await save(verifying: false) } }
                        .disabled(isWorking)
                }
                Button(isNew ? "Add Repository" : "Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || isWorking)
            }
            .padding(12)
        }
        // Resizable, not fixed: the SFTP notes do not fit a fixed 600x660
        // sheet at default font sizes without scrolling, which buries the
        // maintenance section. A minimum keeps it usable; the user can grow
        // it.
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
        // An answer about another location would stand above the buttons
        // as if it were this one's.
        .onChange(of: draft.resticRepositoryString) { status = nil }
        .task(id: draft.kind) {
            // Requeried on every return to the rclone kind: remotes are edited
            // outside the app, so a list from a previous visit may be stale.
            guard draft.kind == .rclone else {
                rcloneRemotes = nil
                return
            }
            let remotes = await loadRcloneRemotes()
            // A cancelled query must not write over its successor's fresher list.
            guard !Task.isCancelled else { return }
            rcloneRemotes = remotes
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

    /// The SSH note's first-contact step, with this repository's server
    /// once its name is typed.
    private var firstContact: String {
        guard !draft.sftpHost.isEmpty else { return "connect to it once in Terminal with ssh and accept its key." }
        let user = draft.sftpUser.isEmpty ? "" : "\(draft.sftpUser)@"
        let port = draft.sftpCustomPort.map { "-p \($0) " } ?? ""
        return "connect once in Terminal (ssh \(port)\(user)\(draft.sftpHost)) and accept its key."
    }

    private var settingsForm: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("Home backups"))
                // The eight kinds grouped by where the backup lives: the
                // destination answers "where is it" as the section header
                // above each kind, so one control carries both questions.
                // The same grouping when the repository is edited — what the
                // user knows of it is the place they picked it by.
                Picker("Where is it?", selection: $draft.kind) {
                    Section("On this Mac") {
                        Text(Repository.Kind.local.displayName).tag(Repository.Kind.local)
                    }
                    Section("On another machine") {
                        Text(Repository.Kind.sftp.displayName).tag(Repository.Kind.sftp)
                        Text(Repository.Kind.rest.displayName).tag(Repository.Kind.rest)
                    }
                    Section("In the cloud") {
                        Text(Repository.Kind.s3.displayName).tag(Repository.Kind.s3)
                        Text(Repository.Kind.b2.displayName).tag(Repository.Kind.b2)
                        Text(Repository.Kind.azure.displayName).tag(Repository.Kind.azure)
                        Text(Repository.Kind.gcs.displayName).tag(Repository.Kind.gcs)
                    }
                    Section("Through a gateway") {
                        Text(Repository.Kind.rclone.displayName).tag(Repository.Kind.rclone)
                    }
                }
                Text(draft.kind.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Location") { locationFields }

            Section("Encryption") {
                SecureField("Repository password", text: $password)
                if isNew {
                    SecureField("Confirm password", text: $confirmPassword)
                }
                Text(encryptionHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if !isNew {
                    changePasswordGroup
                }
            }

            if let label = draft.secretFieldLabel {
                Section("Credentials") {
                    if draft.kind == .sftp {
                        Text(label)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(
                            "SwiftRestic launches restic without a terminal, so it cannot answer an SSH passphrase prompt and does not inherit your ssh-agent. Use a key without a passphrase, or add the host to ~/.ssh/config with IdentityFile. "
                                + "Nor can it accept a server's key on first contact: \(firstContact) SSH then refuses the server if its key ever changes."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    } else if draft.kind == .rest {
                        // A server without logins leaves both blank.
                        TextField("User", text: $draft.restUser, prompt: Text("Optional"))
                        SecureField(label, text: $providerSecret, prompt: Text("Optional"))
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
                ExpandableCaption(
                    summary: "Pruning reclaims the space that retention freed.",
                    detail: "It rewrites pack files, takes an exclusive lock and can run for a long time, so backups to this repository wait for it."
                )
            }

        }
        .formStyle(.grouped)
    }

    // MARK: - Change Password

    /// The repository's own password changed in place: restic adds a key
    /// for the new one and removes the old, then the Keychain follows
    /// (`AppModel.changeRepositoryPassword`). Not the field above, which
    /// only corrects what the Keychain holds.
    private var changePasswordGroup: some View {
        DisclosureGroup("Change Password…", isExpanded: $isChangingPassword) {
            SecureField("New password", text: $newPassword)
            SecureField("Confirm new password", text: $confirmNewPassword)
            HStack {
                if let reason = passwordChangeBlock {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Change Password") { isConfirmingPasswordChange = true }
                    .disabled(passwordChangeBlock != nil || isWorking)
            }
            Text("There is no recovery if you lose the new password either — store it in your password manager.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(
            "Change the password of “\(draft.name)”?",
            isPresented: $isConfirmingPasswordChange,
            titleVisibility: .visible
        ) {
            Button("Change Password") { Task { await changePassword() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The old password stops opening it — everywhere. Another Mac or a script that backs up to it needs the new one.")
        }
    }

    /// Why Change Password waits, or nil. restic needs the repository to
    /// itself: under a backup's or a check's lock it fails at once (exit 11).
    private var passwordChangeBlock: String? {
        if model.busyRepositoryIDs.contains(draft.id) {
            return "Waits while a backup or maintenance job uses this repository."
        }
        if !model.isResticAvailable { return "Needs restic, which could not be found." }
        return EditorRequirements.newPassword(newPassword, confirm: confirmNewPassword)
    }

    private func changePassword() async {
        guard passwordChangeBlock == nil, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        status = nil
        do {
            try await model.changeRepositoryPassword(repositoryID: draft.id, to: newPassword)
            // The Keychain now holds the new password: it is the sheet's
            // baseline, so Save writes nothing back over it.
            password = newPassword
            confirmPassword = newPassword
            initialPassword = newPassword
            newPassword = ""
            confirmNewPassword = ""
            isChangingPassword = false
            status = .ok("Password changed. The old password no longer opens “\(draft.name)”.")
        } catch {
            status = .failure(error.localizedDescription)
        }
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
            TextField("Port", text: $draft.sftpPort, prompt: Text("22"))
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
            ExpandableCaption(
                summary: "The key file's path is stored in your configuration, not the Keychain.",
                detail: "restic reads the key file from disk itself. Keep the file readable only by you."
            )
        case .rest:
            TextField("URL", text: $draft.restURL, prompt: Text("https://host:8000/"))
                // A URL pasted with its login sheds it into User and the
                // Keychain, so the configuration file and the "restic will
                // use" line below never hold the password.
                .onChange(of: draft.restURL) { _, url in
                    guard let split = Repository.splittingRESTCredentials(url) else { return }
                    draft.restURL = split.url
                    draft.restUser = split.user
                    if let password = split.password { providerSecret = password }
                }
        case .rclone:
            HStack {
                TextField("Remote", text: $draft.rcloneRemote, prompt: Text("mydrive"))
                // Recognition over recall: the names rclone already knows, as
                // suggestions — never a replacement for the field, since
                // `:backend:` connection strings and env-defined remotes are
                // typed, not picked.
                if let rcloneRemotes, !rcloneRemotes.isEmpty {
                    Menu {
                        ForEach(rcloneRemotes, id: \.name) { remote in
                            Button(remote.menuTitle) { draft.rcloneRemote = remote.name }
                        }
                    } label: {
                        Label("Remotes", systemImage: "chevron.up.chevron.down")
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Remotes configured with `rclone config` on this Mac")
                }
            }
            TextField("Path", text: $draft.rclonePath, prompt: Text("backups/mac"))
            ExpandableCaption(
                summary: "rclone has to be installed and its remote already configured.",
                detail: "restic launches the rclone binary itself: install it (`brew install rclone`) and set the remote up with `rclone config`."
            )
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

    /// The footer's reason and the buttons' state are one derivation: a
    /// greyed button always has its reason beside it.
    private var canSubmit: Bool { missingRequirement == nil }

    private var missingRequirement: String? {
        EditorRequirements.repository(
            draft,
            password: password,
            confirmPassword: confirmPassword,
            isNew: isNew,
            hasStoredPassword: hasStoredPassword
        )
    }

    /// The Encryption section's caption. For an existing repository the
    /// blank field means "unchanged" only while a password is stored; when
    /// none is — a configuration carried to another Mac, a Keychain item
    /// removed — the caption says so in the words every run and the
    /// listing already use (`ResticError.passwordMissing`), and the footer
    /// asks for the password before Save.
    private var encryptionHint: String {
        if isNew {
            return "restic encrypts everything with this password. There is no recovery if you lose it — store it in your password manager."
        }
        if hasStoredPassword == false {
            return ResticError.passwordMissing(repositoryName: draft.name).localizedDescription
                + " Enter it here to read it and back up to it."
        }
        return "Leave blank to keep the password already saved in your Keychain."
    }

    private func loadExistingSecrets() async {
        guard !isNew else { return }
        do {
            let secrets = try await model.storedSecrets(for: draft.id)
            // The prefill must not clobber what arrived during the await:
            // anything typed into the fields while the Keychain answered is
            // already the user's edit, and overwriting it would not even
            // register as a change against the baseline taken above.
            if password.isEmpty {
                password = secrets.password ?? ""
                confirmPassword = password
            }
            if providerSecret.isEmpty {
                providerSecret = secrets.providerSecret ?? ""
            }
            hasStoredPassword = !(secrets.password ?? "").isEmpty
        } catch {
            // Prefill failed — say so. Blank fields would read as "no
            // password stored" and a save would silently keep whatever the
            // Keychain actually holds, hiding the failure either way.
            status = .failure("Could not read the stored secrets: \(error.localizedDescription)")
        }
    }

    /// Asks the user's rclone what it has configured. Empty on any failure —
    /// without rclone the field is simply free text, and the save-time probe
    /// already explains a missing binary.
    private func loadRcloneRemotes() async -> [RcloneRemote] {
        // The helper lookup stats the PATH — off the main actor, the same
        // rule resolveBinary's own probe follows.
        guard let rclone = await Task.detached { ResticBinary.locateHelper(named: "rclone") }.value
        else { return [] }
        return await RcloneRemoteLister(runner: model.runner).list(binary: rclone)
    }

    /// The typed password, else the stored one; neither throws
    /// `passwordMissing` — the run path's answer — so an empty password never
    /// reaches restic, whose own refusal advises `--insecure-no-password`.
    private func effectivePassword() async throws -> String {
        try EditorRequirements.probePassword(
            typed: password,
            stored: password.isEmpty ? try await model.storedPassword(for: draft.id) : nil,
            repositoryName: draft.name
        )
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
        if draft.requiresRcloneBinary,
           await Task.detached { ResticBinary.locateHelper(named: "rclone") }.value == nil
        {
            status = .failure("rclone is not installed. Install it with `brew install rclone`.")
            return false
        }

        do {
            let service = try model.service()
            let context = RepositoryContext(
                repository: draft,
                password: try await effectivePassword(),
                providerSecret: providerSecret.isEmpty ? nil : providerSecret,
                settings: model.configuration.settings
            )

            if try await service.repositoryExists(context, timeout: Self.probeTimeout) {
                status = .ok("Connected to the existing repository.")
                return true
            }
            guard initializeIfMissing else {
                // Where a new repository goes, nothing there yet is the
                // expected first answer; for an edit it is a problem.
                let answer = EditorRequirements.noRepositoryYet(isNew: isNew)
                status = isNew ? .info(answer) : .failure(answer)
                return false
            }
            _ = try await service.initializeRepository(context)
            status = .ok("Created a new repository.")
            return true
        } catch ResticError.timedOut {
            status = .failure("No answer from the repository in \(Int(Self.probeTimeout)) seconds — check that it is reachable.")
            return false
        } catch {
            status = .failure(error.localizedDescription)
            return false
        }
    }

    private func save(verifying: Bool = true) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        // Creating the repository has to happen before we persist it, so a failed
        // init does not leave an unusable entry in the sidebar.
        if isNew {
            guard await probe(initializeIfMissing: true) else { return }
        } else if verifying, model.isResticAvailable, let initial,
                  EditorRequirements.editReachesRestic(
                      draft: draft,
                      initial: initial,
                      password: password,
                      initialPassword: initialPassword,
                      providerSecret: providerSecret,
                      initialProviderSecret: initialProviderSecret
                  )
        {
            // Checked before it replaces what works: a mistyped password
            // would overwrite the Keychain's working one, a mistyped path
            // repoint every plan of the repository.
            guard await probe(initializeIfMissing: false) else {
                unverifiedEdit = currentEdit
                return
            }
        }
        await model.upsert(
            repository: draft,
            password: password.isEmpty ? nil : password,
            providerSecret: draft.secretFieldLabel == nil || draft.kind == .sftp ? nil : providerSecret
        )
        await model.flushSave()
        await model.refreshSnapshots(repositoryID: draft.id)
        if isNew { onCreated(draft.id) }
        dismiss()
    }
}

/// The one-line orientation the new-repository picker owes each kind: the
/// picker names the backend, this names what it is for. Editor-local teaching
/// copy, so `Repository.Kind` stays a plain configuration model.
extension Repository.Kind {
    var summary: String {
        switch self {
        case .local: "A folder or an external drive attached to this Mac."
        case .sftp: "A NAS or server you reach over SSH."
        case .rest: "A machine running the restic REST server."
        case .s3: "Amazon S3, Wasabi, MinIO, Cloudflare R2 and other S3-compatible services."
        case .b2: "Backblaze B2 cloud storage."
        case .azure: "Microsoft Azure Blob Storage."
        case .gcs: "Google Cloud Storage."
        case .rclone: "Any of rclone's many backends, through a remote you configure once."
        }
    }
}
