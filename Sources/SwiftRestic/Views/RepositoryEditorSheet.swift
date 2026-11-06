import SwiftUI

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
    /// What the Keychain holds for the repository: nil until it has
    /// answered, and still nil when its read failed — a failure is reported
    /// as itself, never read as "nothing stored". The requirements' "has a
    /// stored password" and the probe's fallback both read it, so the sheet
    /// asks the Keychain once.
    @State private var storedSecrets: (password: String?, providerSecret: String?)?
    /// The Keychain's read failed: whether a password is stored is
    /// unknown, and the fields must say neither "saved" nor "required".
    @State private var secretsReadFailed = false
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
    /// Asked for by the saved-password row: the password was changed on
    /// another Mac, so what the Keychain holds no longer opens it.
    @State private var isReplacingSavedPassword = false
    @State private var rcloneSetup: RcloneSetup?
    /// Bumped when the app becomes active, so remotes set up in Terminal
    /// meanwhile appear without leaving the sheet.
    @State private var rcloneReadCount = 0
    /// The local folder's network share while it is mounted
    /// (`VolumePresence.mountedShare`), read off the main actor.
    @State private var mountedShare: MountedShare?
    /// The share's password as typed: empty leaves a saved one as it is.
    @State private var sharePassword = ""

    private let isNew: Bool
    /// Told the new repository's id once it is created and saved — never on
    /// an edit, a cancel or a failed probe — so the window can open the
    /// page that offers its first plan.
    private let onCreated: (UUID) -> Void

    private struct RcloneRead: Equatable {
        var kind: Repository.Kind
        var count: Int
    }

    private struct Edit: Equatable {
        var draft: Repository
        var password: String
        var providerSecret: String
    }

    private var currentEdit: Edit {
        Edit(draft: draft, password: password, providerSecret: providerSecret)
    }

    /// Bounds Save's check: against a REST server that
    /// refuses connections restic 0.19.1 retried for over ten minutes, with
    /// the sheet's buttons grey all the while.
    private static let probeTimeout: TimeInterval = 60

    init(repository: Repository, onCreated: @escaping (UUID) -> Void = { _ in }) {
        // A new repository opens as `Repository()`: a local folder not yet
        // chosen. A saved one always has its location (Save requires it).
        isNew = repository.kind == .local && repository.localPath.isEmpty
        _draft = State(initialValue: repository)
        self.onCreated = onCreated
    }

    private enum Status: Equatable {
        case ok(String)
        case failure(String)

        var text: String {
            switch self {
            case let .ok(message), let .failure(message): message
            }
        }

        var symbolName: String {
            switch self {
            case .ok: "checkmark.circle.fill"
            case .failure: "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .ok: Theme.success
            case .failure: Theme.danger
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsForm
            // Held while restic is asked: the probe checks the fields as
            // they were when it began, and Save then stores the fields as
            // they are — an edit typed in between would be saved unchecked,
            // under an answer about the location the fields no longer show.
            .disabled(isWorking)

            Divider()

            // Save's or Change Password's answer, beside the buttons: at the end
            // of the scrolled form it landed below the fold.
            if let status {
                Label(status.text, systemImage: status.symbolName)
                    .foregroundStyle(status.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top], 12)
            }

            HStack {
                // A greyed Save owes the user the reason at the button — a mismatched confirm password must not be
                // a hunt across fields.
                if let reason = missingRequirement {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                    // A server that is down while a credential is being
                    // fixed must not block the fix; the answer above says
                    // what the check met.
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
        // sheet at default font sizes without scrolling.
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
        // The folder's network share, read off the main actor: a stalled
        // share can hold the read for seconds.
        .task(id: draft.kind == .local ? draft.resolvedLocalPath : "") {
            guard draft.kind == .local else {
                mountedShare = nil
                return
            }
            let path = draft.resolvedLocalPath
            let share = await Task.detached { VolumePresence.mountedShare(holding: path) }.value
            guard !Task.isCancelled else { return }
            mountedShare = share
        }
        .task(id: RcloneRead(kind: draft.kind, count: rcloneReadCount)) {
            // Requeried on every return to the rclone kind: remotes are edited
            // outside the app, so a list from a previous visit may be stale.
            guard draft.kind == .rclone, isNew else {
                rcloneSetup = nil
                return
            }
            let setup = await loadRcloneSetup()
            // A cancelled query must not write over its successor's fresher list.
            guard !Task.isCancelled else { return }
            rcloneSetup = setup
            // A remote removed in Terminal meanwhile is no longer a choice.
            if case let .remotes(remotes) = setup, !remotes.contains(where: { $0.name == draft.rcloneRemote }) {
                draft.rcloneRemote = ""
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if isNew, draft.kind == .rclone { rcloneReadCount += 1 }
        }
        .confirmationDialog(
            "Discard changes?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var isDirty: Bool {
        if let initial, draft != initial { return true }
        if password != initialPassword { return true }
        if providerSecret != initialProviderSecret { return true }
        if !sharePassword.isEmpty { return true }
        return false
    }

    private var folderShare: (share: MountedShare, isSaved: Bool)? {
        draft.kind == .local ? model.shareRow(for: draft.resolvedLocalPath, mounted: mountedShare) : nil
    }

    private func cancel() {
        if isDirty {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private var firstContact: String {
        guard !draft.sftpHost.isEmpty else { return "connect once in Terminal with ssh and accept it." }
        let user = draft.sftpUser.isEmpty ? "" : "\(draft.sftpUser)@"
        let port = draft.sftpCustomPort.map { "-p \($0) " } ?? ""
        return "connect once in Terminal (ssh \(port)\(user)\(draft.sftpHost)) and accept it."
    }

    private var settingsForm: some View {
        Form {
            Section {
                // The eight kinds grouped by where the backup lives: the
                // destination answers "where is it" as the section header
                // above each kind, so one control carries both questions.
                // A saved repository's kind is part of where it is, fixed
                // with its location (`locationFields`).
                if isNew {
                    kindPicker
                    Text(draft.kind.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    LabeledContent("Type") { Text(draft.kind.displayName) }
                }
            }

            Section("Location") { locationFields }

            Section("Encryption") {
                // The Keychain's password stays out of sight until it needs
                // replacing: this field is not how a password is changed.
                if hasStoredPassword == true, !isReplacingSavedPassword {
                    LabeledContent("Password", value: "Saved in Keychain")
                    Button("Password Changed on Another Mac…") { isReplacingSavedPassword = true }
                } else if !isNew, storedSecrets == nil, !secretsReadFailed {
                    LabeledContent("Password") { ProgressView().controlSize(.small) }
                } else {
                    // A grouped form draws its fields without a border, so an
                    // empty one needs its prompt to be seen at all.
                    SecureField("Repository password", text: $password, prompt: Text(passwordPrompt))
                }
                if isNew {
                    SecureField("Confirm password", text: $confirmPassword, prompt: Text("Required"))
                }
                if let hint = encryptionHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !isNew {
                    changePasswordGroup
                }
            }

            if draft.secretFieldLabel != nil || draft.kind == .sftp || draft.kind == .gcs {
                Section("Credentials") {
                    if draft.kind == .sftp {
                        Text(
                            "SSH is authenticated with your keys, and restic runs without a terminal, so it can’t ask for a key’s passphrase or use ssh-agent: use a key without one, set in ~/.ssh/config. "
                                + "It can’t accept a new server’s key either — \(firstContact)"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    } else if draft.kind == .gcs {
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
                            summary: "The key file’s path is stored in your configuration, not the Keychain.",
                            detail: "restic reads the key file from disk itself. Keep the file readable only by you."
                        )
                    } else if let label = draft.secretFieldLabel {
                        if draft.kind == .rest {
                            // A server without logins leaves both blank.
                            TextField("User", text: $draft.restUser, prompt: Text("Optional"))
                            SecureField(label, text: $providerSecret, prompt: Text("Optional"))
                        } else if draft.kind == .s3 {
                            TextField("Access key ID", text: $draft.s3AccessKeyID, prompt: Text("Required"))
                            SecureField(label, text: $providerSecret, prompt: Text("Required"))
                        } else if draft.kind == .b2 {
                            TextField("Key ID", text: $draft.b2AccountID, prompt: Text("Required"))
                            SecureField(label, text: $providerSecret, prompt: Text("Required"))
                        } else {
                            SecureField(label, text: $providerSecret, prompt: Text("Required"))
                        }
                    }
                }
            }

            // A limit an older build saved on a local disk stays visible, so it
            // can be cleared: restic holds a local disk to it too.
            if draft.usesNetwork(shares: model.configuration.settings.networkShares) || draft.uploadLimitKiBps > 0 {
                Section("Bandwidth") {
                    uploadLimitField
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The repository's own password changed in place: restic adds a key
    /// for the new one and removes the old, then the Keychain follows
    /// (`AppModel.changeRepositoryPassword`).
    private var changePasswordGroup: some View {
        DisclosureGroup("Change Password", isExpanded: $isChangingPassword) {
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
            Text("There is no recovery if you lose the new password — store it in your password manager.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(
            "Change the password of “\(draftLabel)”?",
            isPresented: $isConfirmingPasswordChange,
            titleVisibility: .visible
        ) {
            Button("Change Password") { Task { await changePassword() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The old password stops opening it — everywhere. Another Mac or a script that backs up to it needs the new one.")
        }
    }

    /// restic needs the repository to itself: under a backup's or a check's
    /// lock it fails at once (exit 11).
    private var passwordChangeBlock: String? {
        if model.busyRepositoryIDs.contains(draft.id) {
            return BackupPlan.busyRepositoryReason
        }
        if let absence = model.resticAbsence { return absence.sentence }
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
            status = .ok("Password changed. The old password no longer opens “\(draftLabel)”.")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private var kindPicker: some View {
        Picker("Type", selection: $draft.kind) {
            Section("On this Mac") {
                Text(Repository.Kind.local.displayName).tag(Repository.Kind.local)
            }
            Section("On another computer") {
                Text(Repository.Kind.sftp.displayName).tag(Repository.Kind.sftp)
                Text(Repository.Kind.rest.displayName).tag(Repository.Kind.rest)
            }
            Section("In the cloud") {
                Text(Repository.Kind.s3.displayName).tag(Repository.Kind.s3)
                Text(Repository.Kind.b2.displayName).tag(Repository.Kind.b2)
            }
            Section("Through a gateway") {
                Text(Repository.Kind.rclone.displayName).tag(Repository.Kind.rclone)
            }
        }
    }

    /// Where the repository is, chosen only while it is new. A saved one is
    /// that place — its label, its index and its history are all of it —
    /// so its location reads as text, as a saved plan's path does, and
    /// another place is another repository (Add Repository, exit 10's
    /// fix). Fixed are the parts restic's repository string is made of and
    /// Azure's account, which holds the container; what reaches the place
    /// without being it — a key's ID, a project, a share's password —
    /// stays editable.
    @ViewBuilder
    private var locationFields: some View {
        if isNew {
            whereFields
        } else {
            // The section's title names it.
            Text(draft.displayLocation)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            if draft.kind == .azure {
                LabeledContent("Account name") { Text(draft.azureAccountName) }
            }
            if draft.kind == .gcs {
                TextField("Project ID", text: $draft.gcsProjectID, prompt: Text("Optional"))
            }
        }
        if draft.kind == .local, let folderShare {
            NetworkSharePasswordRows(url: folderShare.share.url, isSaved: folderShare.isSaved, password: $sharePassword)
        }
    }

    @ViewBuilder
    private var whereFields: some View {
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
            TextField("Bucket", text: $draft.s3Bucket, prompt: Text("Required"))
            TextField("Prefix", text: $draft.s3Prefix, prompt: Text("Optional"))
        case .b2:
            TextField("Bucket", text: $draft.b2Bucket, prompt: Text("Required"))
            TextField("Prefix", text: $draft.b2Prefix, prompt: Text("Optional"))
        case .azure:
            TextField("Container", text: $draft.azureContainer, prompt: Text("Required"))
            TextField("Prefix", text: $draft.azurePrefix, prompt: Text("Optional"))
            TextField("Account name", text: $draft.azureAccountName, prompt: Text("Required"))
        case .gcs:
            TextField("Bucket", text: $draft.gcsBucket, prompt: Text("Required"))
            TextField("Prefix", text: $draft.gcsPrefix, prompt: Text("Optional"))
            TextField("Project ID", text: $draft.gcsProjectID, prompt: Text("Optional"))
        case .rest:
            TextField("URL", text: $draft.restURL, prompt: Text("https://host:8000/"))
                // A URL pasted with its login sheds it into User and the
                // Keychain, so the configuration file never holds the
                // password.
                .onChange(of: draft.restURL) { _, url in
                    guard let split = Repository.splittingRESTCredentials(url) else { return }
                    draft.restURL = split.url
                    draft.restUser = split.user
                    if let password = split.password { providerSecret = password }
                }
        case .rclone:
            rcloneFields
        }
    }

    /// Only the remotes rclone already has: setting one up is rclone's job,
    /// so a remote that is not there yet sends the user to rclone config.
    /// Not a text field: a `:backend:` connection string can be saved as a
    /// named remote instead (the user's call).
    @ViewBuilder
    private var rcloneFields: some View {
        switch rcloneSetup {
        case nil:
            LabeledContent("Remote") { ProgressView().controlSize(.small) }
        case .notInstalled:
            Text(ResticError.rcloneMissing).foregroundStyle(.secondary)
        case let .unreadable(message):
            Text(message).foregroundStyle(.secondary)
        case let .remotes(remotes) where remotes.isEmpty:
            Text(RcloneSetup.noRemotes).foregroundStyle(.secondary)
        case let .remotes(remotes):
            Picker("Remote", selection: $draft.rcloneRemote) {
                if draft.rcloneRemote.isEmpty { Text("Choose").tag("") }
                ForEach(remotes, id: \.name) { remote in
                    Text(remote.menuTitle).tag(remote.name)
                }
            }
            TextField("Path", text: $draft.rclonePath, prompt: Text("backups/mac"))
            Text("To set up another remote, use rclone config in Terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The footer's reason and the buttons' state are one derivation: a
    /// greyed button always has its reason beside it.
    private var canSubmit: Bool { missingRequirement == nil }

    private var missingRequirement: String? {
        EditorRequirements.repository(
            draft,
            password: password,
            confirmPassword: confirmPassword,
            isNew: isNew,
            hasStoredPassword: hasStoredPassword,
            among: model.configuration.repositories
        )
    }

    /// The Encryption section's caption, nil when the field's prompt already
    /// says what a blank field means. For an existing repository the
    /// blank field means "unchanged" only while a password is stored; when
    /// none is — a configuration carried to another Mac, a Keychain item
    /// removed — the caption says so in the words every run and the
    /// listing already use (`ResticError.passwordMissing`), and the footer
    /// asks for the password before Save.
    private var encryptionHint: String? {
        if isNew {
            return "Everything is encrypted with it, and it can’t be recovered — keep it in your password manager."
        }
        if secretsReadFailed {
            return "Leave this blank to keep whatever password the Keychain holds, or enter the password to replace it."
        }
        if hasStoredPassword == false {
            return ResticError.passwordMissing(repositoryName: draftLabel).localizedDescription
                + " Enter it here to read it and back up to it."
        }
        return nil
    }

    private var passwordPrompt: String {
        if isNew { return "Required" }
        if secretsReadFailed { return "Not read from Keychain" }
        return "Required"
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
            storedSecrets = secrets
        } catch {
            // Prefill failed — say so. Blank fields would read as "no
            // password stored" and a save would silently keep whatever the
            // Keychain actually holds, hiding the failure either way.
            status = .failure("Could not read the password from your Keychain: \(error.localizedDescription)")
            secretsReadFailed = true
        }
    }

    /// The rclone binary restic would run. The lookup stats the PATH — off
    /// the main actor, the same rule resolveBinary's own probe follows.
    private static func locateRclone() async -> URL? {
        await Task.detached(operation: { ResticBinary.locateHelper(named: "rclone") }).value
    }

    private func loadRcloneSetup() async -> RcloneSetup {
        guard let rclone = await Self.locateRclone() else { return .notInstalled }
        return await RcloneRemoteLister(runner: model.runner).list(binary: rclone)
    }

    /// The typed password, else the stored one; neither throws
    /// `passwordMissing` — the run path's answer — so an empty password never
    /// reaches restic, whose own refusal advises `--insecure-no-password`.
    private func effectivePassword() throws -> String {
        try EditorRequirements.probePassword(
            typed: password,
            stored: password.isEmpty ? storedSecrets?.password : nil,
            repositoryName: draftLabel
        )
    }

    private var draftLabel: String {
        draft.label(among: model.configuration.repositories)
    }

    private var hasStoredPassword: Bool? {
        storedSecrets.map { !($0.password ?? "").isEmpty }
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
           await Self.locateRclone() == nil
        {
            status = .failure(ResticError.rcloneMissing)
            return false
        }

        do {
            let service = try model.service()
            let context = RepositoryContext(
                repository: draft,
                password: try effectivePassword(),
                providerSecret: providerSecret.isEmpty ? nil : providerSecret
            )

            if try await service.repositoryExists(context, timeout: Self.probeTimeout) {
                status = .ok("Connected to the existing repository.")
                return true
            }
            guard initializeIfMissing else {
                status = .failure(EditorRequirements.noRepositoryHere)
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

    /// Stored in KiB/s, restic's unit; said in MB/s. Empty is no limit (0),
    /// shown as the prompt. Clamped on commit, never mid-keystroke.
    private var uploadLimitField: some View {
        TextField(
            "Upload limit (MB/s)",
            value: Binding<Double?>(
                get: { draft.uploadLimitKiBps == 0 ? nil : Double(draft.uploadLimitKiBps) / 1024 },
                set: { draft.uploadLimitKiBps = min(1_000_000, max(0, Int((($0 ?? 0) * 1024).rounded()))) }
            ),
            format: .number.precision(.fractionLength(0 ... 1)).grouping(.never),
            prompt: Text("Unlimited")
        )
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
        let keepsStoredSecret = EditorRequirements.keepsStoredProviderSecret(
            secretFieldLabel: draft.secretFieldLabel, readFailed: secretsReadFailed, typedSecret: providerSecret
        )
        await model.upsert(
            repository: draft,
            password: password.isEmpty ? nil : password,
            providerSecret: keepsStoredSecret ? nil : providerSecret
        )
        // The repository is saved from here on: a share password that does
        // not save is said by the app, and the sheet closes as saved — kept
        // open, it would offer Add Repository and ask to discard a
        // repository the sidebar already shows.
        if !sharePassword.isEmpty, let share = folderShare?.share {
            do {
                try await model.saveNetworkShare(share, password: sharePassword)
            } catch {
                model.post(Banner(
                    title: "Could not save the password for “\(share.url)”",
                    message: "The repository “\(draft.label(among: model.configuration.repositories))” is saved. \(error.localizedDescription)",
                    isError: true
                ))
            }
            sharePassword = ""
        }
        await model.flushSave()
        // Not awaited: a large remote's listing can take minutes, and the
        // sheet would sit disabled through them.
        model.scheduleSnapshotRefresh(repositoryID: draft.id)
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
        case .rclone: "Any of rclone’s many backends, through a remote you configure once."
        }
    }
}
