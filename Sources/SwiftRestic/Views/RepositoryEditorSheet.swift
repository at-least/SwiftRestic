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
    /// The saved password is known not to open the repository
    /// (`AppModel.passwordRefused`), read once as the sheet opens: the
    /// password field shows, empty, in place of "Saved in Keychain".
    @State private var entersPassword = false
    @State private var rcloneSetup: RcloneSetup?
    /// Bumped when the app becomes active, so remotes set up in Terminal
    /// meanwhile appear without leaving the sheet.
    @State private var rcloneReadCount = 0
    /// The local folder's network share while it is mounted
    /// (`VolumePresence.mountedShare`), read off the main actor.
    @State private var mountedShare: MountedShare?
    /// The share's password as typed: empty leaves a saved one as it is.
    @State private var sharePassword = ""
    /// The chosen folder already holds backups
    /// (`EditorRequirements.holdsBackups`), read off the main actor.
    @State private var holdsBackups = false

    private let isNew: Bool
    /// The folder the first-run sheet is backing up, when it handed off to
    /// this editor for a server or cloud storage: the Type picker leaves
    /// out this Mac, and the sheet is that folder's backup.
    private let firstBackupSource: String?
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

    /// `firstBackupSource`, `password` and `confirmPassword`: what the
    /// first-run sheet held when it handed off to this editor. A new
    /// location then opens on the first kind that is not on this Mac.
    init(
        repository: Repository,
        firstBackupSource: String? = nil,
        password: String = "",
        confirmPassword: String = "",
        onCreated: @escaping (UUID) -> Void = { _ in }
    ) {
        // A new repository opens as `Repository()`: a local folder not yet
        // chosen. A saved one always has its location (Save requires it).
        isNew = repository.kind == .local && repository.localPath.isEmpty
        precondition(isNew || firstBackupSource == nil, "a first backup opens a new location only")
        self.firstBackupSource = firstBackupSource
        var repository = repository
        if firstBackupSource != nil { repository.kind = .sftp }
        _draft = State(initialValue: repository)
        _password = State(initialValue: password)
        _confirmPassword = State(initialValue: confirmPassword)
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

        var symbolColor: Color {
            switch self {
            case .ok: .secondary
            case .failure: Theme.danger
            }
        }

        var textStyle: HierarchicalShapeStyle {
            switch self {
            case .ok: .secondary
            case .failure: .primary
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isNew {
                Text(firstBackupSource.map { "Back Up “\(($0 as NSString).lastPathComponent)”" } ?? "Add Backup Location")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top], 20)
            }
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: status.symbolName)
                        .foregroundStyle(status.symbolColor)
                        .accessibilityHidden(true)
                    Text(status.text)
                        .foregroundStyle(status.textStyle)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                        .accessibilityIdentifier(AccessibilityID.RepositoryEditor.requirement)
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
                Button(isNew ? (firstBackupSource != nil ? "Back Up" : "Add Backup Location") : "Save") { Task { await save() } }
                    .accessibilityIdentifier(AccessibilityID.RepositoryEditor.save)
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
            entersPassword = !isNew && model.passwordRefused(repositoryID: draft.id)
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
                holdsBackups = false
                return
            }
            let path = draft.resolvedLocalPath
            let (share, holds) = await Task.detached {
                (VolumePresence.mountedShare(holding: path), EditorRequirements.holdsBackups(atLocalPath: path))
            }.value
            guard !Task.isCancelled else { return }
            mountedShare = share
            holdsBackups = holds
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

    private var settingsForm: some View {
        Form {
            Section {
                // The kinds grouped by where the backup lives: the
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

            Section("Where") { locationFields }

            Section("Encryption") {
                // The Keychain's password stays out of sight until it stops
                // opening the repository: this field is not how a password
                // is changed.
                if hasStoredPassword == true, !entersPassword {
                    LabeledContent("Password", value: "Saved in Keychain")
                } else if !isNew, storedSecrets == nil, !secretsReadFailed {
                    LabeledContent("Password") { ProgressView().controlSize(.small) }
                } else {
                    // A grouped form draws its fields without a border, so an
                    // empty one needs its prompt to be seen at all.
                    SecureField(opensExistingBackups ? "Password for these backups" : "Password", text: $password, prompt: Text(passwordPrompt))
                        .accessibilityIdentifier(AccessibilityID.RepositoryEditor.password)
                }
                if isNew, !opensExistingBackups {
                    SecureField("Confirm password", text: $confirmPassword, prompt: Text("Required"))
                        .accessibilityIdentifier(AccessibilityID.RepositoryEditor.confirmPassword)
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

            if draft.secretFieldLabel != nil || draft.kind == .sftp {
                Section("Credentials") {
                    if draft.kind == .sftp {
                        Text("Use an SSH key without a passphrase, set in ~/.ssh/config.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    } else if let label = draft.secretFieldLabel {
                        if draft.kind == .rest {
                            // A server without logins leaves both blank.
                            TextField("User", text: $draft.restUser, prompt: Text("Optional"))
                            SecureField(label, text: $providerSecret, prompt: Text("Optional"))
                        } else if draft.kind == .s3 {
                            TextField("Access key ID", text: $draft.s3AccessKeyID, prompt: Text("Required"))
                            SecureField(label, text: $providerSecret, prompt: Text("Required"))
                        }
                    }
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
        if model.isResticDamaged { return ResticError.damagedInstall.localizedDescription }
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
            if firstBackupSource == nil {
                Section("On this Mac") {
                    Text(Repository.Kind.local.displayName).tag(Repository.Kind.local)
                }
            }
            Section("On another computer") {
                Text(Repository.Kind.sftp.displayName).tag(Repository.Kind.sftp)
                Text(Repository.Kind.rest.displayName).tag(Repository.Kind.rest)
            }
            Section("In the cloud") {
                Text(Repository.Kind.s3.displayName).tag(Repository.Kind.s3)
            }
            Section("Through a gateway") {
                Text(Repository.Kind.rclone.displayName).tag(Repository.Kind.rclone)
            }
        }
    }

    /// Where the repository is, chosen only while it is new. A saved one is
    /// that place, so its location reads as text, as a saved plan's path
    /// does: a typed path could repoint it at another repository. A folder
    /// that moved has Locate, which checks restic's ID. Fixed are the parts
    /// restic's repository string is made of; what reaches the place
    /// without being it — a key's ID, a share's password — stays editable.
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
        }
        if draft.kind == .local, let folderShare {
            NetworkSharePasswordRows(url: folderShare.share.url, isSaved: folderShare.isSaved, password: $sharePassword)
        }
    }

    @ViewBuilder
    private var whereFields: some View {
        switch draft.kind {
        case .local:
            // Chosen, not typed: ⇧⌘G in the panel still takes a typed path.
            LabeledContent("Folder") {
                HStack {
                    if !draft.localPath.isEmpty {
                        Text(draft.displayLocation)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(draft.displayLocation)
                    }
                    Button(draft.localPath.isEmpty ? "Choose…" : "Change…") {
                        if let url = FilePicker.chooseDirectory(message: "Choose the folder for your backups") {
                            draft.localPath = url.path
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.RepositoryEditor.chooseFolder)
                }
            }
        case .sftp:
            TextField("Server", text: $draft.sftpHost, prompt: Text("backup@nas.local or backup@nas.local:2222"))
            TextField("Path", text: $draft.sftpPath, prompt: Text("/volume1/SwiftRestic Backups"))
        case .s3:
            TextField("Endpoint", text: $draft.s3Endpoint, prompt: Text("s3.amazonaws.com"))
            TextField("Bucket", text: $draft.s3Bucket, prompt: Text("my-bucket or my-bucket/mac"))
            Text("For Backblaze B2, use the bucket’s endpoint, such as s3.us-west-004.backblazeb2.com, and an application key.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        case .damaged:
            Text(ResticError.rcloneMissing).foregroundStyle(.secondary)
        case let .unreadable(message):
            Text(message).foregroundStyle(.secondary)
        case let .remotes(remotes) where remotes.isEmpty:
            VStack(alignment: .leading, spacing: 6) {
                Text(RcloneSetup.noRemotes)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reveal rclone") {
                    NSWorkspace.shared.activateFileViewerSelecting([RcloneBinary.bundled.url])
                }
                .controlSize(.small)
            }
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
        if entersPassword, password.isEmpty { return "Enter the password to save it." }
        return EditorRequirements.repository(
            draft,
            password: password,
            confirmPassword: confirmPassword,
            isNew: isNew,
            holdsBackups: opensExistingBackups,
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
        if opensExistingBackups { return nil }
        if isNew {
            return PasswordWords.recoveryWarning
        }
        if entersPassword, hasStoredPassword == true {
            return "The saved password doesn’t open “\(draftLabel)”. Enter the one that does."
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

    /// A new location at a folder that already holds backups: their
    /// password is asked once, not set.
    private var opensExistingBackups: Bool {
        isNew && draft.kind == .local && holdsBackups
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
            // A refused password is not put back in the field it is to be
            // replaced in.
            if password.isEmpty, !entersPassword {
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
            status = .failure("Couldn’t read the password from your Keychain: \(error.localizedDescription)")
            secretsReadFailed = true
        }
    }

    private func loadRcloneSetup() async -> RcloneSetup {
        guard let rclone = RcloneBinary.runnable else { return .damaged }
        return await RcloneRemoteLister(runner: model.runner).list(binary: rclone.url)
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
           RcloneBinary.runnable == nil
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

            if try await service.repositoryExists(context, timeout: EditorRequirements.probeTimeout) {
                status = .ok("Connected to the existing backups.")
                return true
            }
            guard initializeIfMissing else {
                status = .failure(EditorRequirements.noRepositoryHere)
                return false
            }
            _ = try await service.initializeRepository(context)
            status = .ok("Created a new backup location.")
            return true
        } catch ResticError.timedOut {
            status = .failure("No answer from the location in \(Int(EditorRequirements.probeTimeout)) seconds. Check that it is reachable.")
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
                    title: "Couldn’t save the password for “\(share.url)”",
                    message: "“\(draft.label(among: model.configuration.repositories))” is saved. \(error.localizedDescription)",
                    level: .error
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
        case .s3: "Amazon S3, Backblaze B2, Wasabi, MinIO, Cloudflare R2 and other S3-compatible services."
        case .rclone: "Any of rclone’s many backends, through a remote you configure once."
        }
    }
}
