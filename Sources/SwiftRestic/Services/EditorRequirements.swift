import Foundation

/// The disabled-Save reasons the editor sheets show beside their buttons.
///
/// Pure and view-free so the test target compiles them: the caption is the
/// same chain the disabled state checks, spelled in field order, and a test
/// pins the ordering — a reordering that makes the footer name a later gap
/// while an earlier one exists is a regression.
enum EditorRequirements {
    /// The first requirement `BackupPlan.isConfigurationComplete` checks but
    /// does not name, in the order the plan sheet presents them: the
    /// header's Name and Repository, then the Files tab's folders.
    static func plan(_ draft: BackupPlan) -> String? {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Name the plan to save it."
        }
        if draft.repositoryID == nil {
            return "Choose a repository to save it."
        }
        if draft.sources.isEmpty {
            return "Add at least one folder to back up."
        }
        return nil
    }

    /// Test Connection's answer when no repository is at the location: a
    /// new repository's Save creates one there, an edit's Save creates
    /// nothing — its plans' backups would fail (restic exit 10) against the
    /// empty path.
    static func noRepositoryYet(isNew: Bool) -> String {
        isNew
            ? "No repository at that location yet. Saving will create one."
            : "No repository is at that path — backups to it would fail until one is created. Point it at the folder that holds the repository."
    }

    /// Whether an edit's Save asks restic first: when it changes what
    /// reaches restic — the location, a credential, the environment — or
    /// the password, any of which a typo turns into every plan failing. A
    /// rename, a maintenance setting or a hook saves at once.
    static func editReachesRestic(
        draft: Repository,
        initial: Repository,
        password: String,
        initialPassword: String,
        providerSecret: String,
        initialProviderSecret: String
    ) -> Bool {
        if password != initialPassword { return true }
        func environment(_ repository: Repository, _ secret: String) -> [String: String] {
            RepositoryContext(repository: repository, password: "", providerSecret: secret).environment
        }
        return environment(draft, providerSecret) != environment(initial, initialProviderSecret)
    }

    /// Why Change Password cannot run yet, or nil. restic trims a password
    /// it reads from `--new-password-file` (checked on 0.19.1) while the app
    /// hands it the stored one untrimmed, so a new password with spaces at
    /// its ends would leave the key and the Keychain disagreeing.
    static func newPassword(_ password: String, confirm: String) -> String? {
        if password.isEmpty { return "Type the new password twice to change it." }
        if password != confirm { return "The two new passwords differ." }
        if password != password.trimmingCharacters(in: .whitespacesAndNewlines) {
            return "restic drops spaces at the ends of a new password — remove them."
        }
        return nil
    }

    /// The repository a plan editor opens on: the plan's own, else the
    /// only one there is. With two or more the picker says Choose… and the
    /// footer asks — a silent first pick lands the plan wherever the first
    /// row points.
    static func initialRepositoryID(_ current: UUID?, among repositories: [Repository]) -> UUID? {
        current ?? (repositories.count == 1 ? repositories[0].id : nil)
    }

    /// The first requirement `Repository.isConfigurationComplete` plus the
    /// password rules. They bind a new repository, and an existing one only
    /// when this Mac holds no password for it — then a blank field is not
    /// "unchanged" but the gap every run already names. `hasStoredPassword`
    /// is nil until the Keychain has answered, and stays nil when the read
    /// failed: an error must not be read as "nothing stored".
    static func repository(
        _ draft: Repository,
        password: String,
        confirmPassword: String,
        isNew: Bool,
        hasStoredPassword: Bool?
    ) -> String? {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Name the repository to save it."
        }
        switch draft.kind {
        case .local:
            if draft.localPath.isEmpty { return "Choose a folder to save it." }
        case .sftp:
            if draft.sftpHost.isEmpty || draft.sftpPath.isEmpty { return "Enter the host and path to save it." }
            // restic cuts the host at its first colon, so a port typed there
            // would become the start of the path and ssh would dial 22.
            if draft.sftpHost.contains(":") { return "Put the port in Port, not in Host." }
            if !draft.sftpPort.isEmpty, !(1 ... 65535).contains(Int(draft.sftpPort) ?? 0) {
                return "Port is a number from 1 to 65535."
            }
        case .s3:
            if draft.s3Bucket.isEmpty || draft.s3AccessKeyID.isEmpty { return "Enter the bucket and access key ID to save it." }
        case .b2:
            if draft.b2Bucket.isEmpty || draft.b2AccountID.isEmpty { return "Enter the bucket and account ID to save it." }
        case .azure:
            if draft.azureContainer.isEmpty || draft.azureAccountName.isEmpty { return "Enter the container and account name to save it." }
        case .gcs:
            if draft.gcsBucket.isEmpty || draft.gcsCredentialsPath.isEmpty { return "Enter the bucket and service account file to save it." }
        case .rest:
            if draft.restURL.isEmpty { return "Enter the server URL to save it." }
        case .rclone:
            if draft.rcloneRemote.isEmpty { return "Enter the rclone remote to save it." }
        }
        if isNew {
            if password.isEmpty {
                return "Set a repository password to save it."
            }
            if password != confirmPassword {
                return "The passwords do not match yet."
            }
        } else if hasStoredPassword == false, password.isEmpty {
            return "Enter the repository password to save it."
        }
        return nil
    }

    /// The password Test Connection and an edit's Save hand restic: the
    /// typed one, else the stored one. Neither is `passwordMissing` — the
    /// run path's own answer — never an empty string, which restic refuses
    /// in its own words, with advice (`--insecure-no-password`) that is
    /// wrong for this app.
    static func probePassword(typed: String, stored: String?, repositoryName: String) throws -> String {
        if !typed.isEmpty { return typed }
        if let stored, !stored.isEmpty { return stored }
        throw ResticError.passwordMissing(repositoryName: repositoryName)
    }
}
