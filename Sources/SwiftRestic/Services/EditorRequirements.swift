import Foundation

/// The disabled-Save reasons the editor sheets show beside their buttons:
/// the same chain the disabled state checks, in field order, which a test
/// pins — the footer must never name a later gap while an earlier one exists.
enum EditorRequirements {
    /// The first requirement `BackupPlan.isConfigurationComplete` checks but
    /// does not name, in the order the plan sheet's header presents them —
    /// Folder or file, Repository — then the one a configuration checks: a
    /// repository holds one plan per path (`plans`, every configured plan,
    /// the draft's own saved entry among them), its history being restic's
    /// for that path. That one binds only a plan being added — new, or
    /// adopted: a saved plan's path is fixed, so in an edit it could only
    /// grey Save with nothing in the sheet to change.
    static func plan(_ draft: BackupPlan, isNew: Bool, among plans: [BackupPlan]) -> String? {
        if draft.path.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Choose a folder or file to back up."
        }
        if draft.repositoryID == nil {
            return "Choose a backup location to save it."
        }
        let path = comparable(draft.path)
        if isNew, plans.contains(where: { $0.id != draft.id && $0.repositoryID == draft.repositoryID && comparable($0.path) == path }) {
            return "This location already has a plan for this folder or file."
        }
        return nil
    }

    /// Trimmed before the tilde expands: a pasted " ~/Documents" does not
    /// start with `~`.
    private static func comparable(_ path: String) -> String {
        ResticPath.normalized((path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath)
    }

    /// Bounds Save's check: restic's retries keep it at an SFTP server or S3
    /// endpoint it cannot reach (a refusing server held restic 0.19.1 for
    /// over ten minutes), with the sheet's buttons grey all the while.
    static let probeTimeout: TimeInterval = 60

    static let probeTimedOut = "No answer from the location in \(Int(probeTimeout)) seconds. Check that it is reachable."

    /// The repository inside what it backs up: every backup would carry
    /// restic's own files.
    static func backupsInside(source: String, folder: String) -> String? {
        ResticPath.holds(source, folder) ? "Keep the backups outside the folder you’re backing up." : nil
    }

    /// The first-run sheet's greyed Back Up into a new folder, after it has
    /// asked what and where (`FirstBackupDestination.requirement`).
    static func firstBackup(
        source: String,
        folder: String,
        password: String,
        confirmPassword: String,
        holdsBackups: Bool,
        among repositories: [Repository]
    ) -> String? {
        if let inside = backupsInside(source: source, folder: folder) { return inside }
        var location = Repository()
        location.localPath = folder
        return repository(
            location, password: password, confirmPassword: confirmPassword,
            isNew: true, holdsBackups: holdsBackups, hasStoredPassword: nil, among: repositories
        )
    }

    /// Whether a local folder already holds backups — restic's `config`
    /// file, which every repository has at its top. Its password is then
    /// the one they were made with: asked once, with no confirmation and
    /// no warning about forgetting it. File-system IO: a network share or
    /// a sleeping disk can hold it for seconds, so callers read it off the
    /// main actor.
    static func holdsBackups(atLocalPath path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let config = URL(fileURLWithPath: ResticService.expandTilde(path)).appending(path: "config")
        return FileManager.default.fileExists(atPath: config.path)
    }

    /// An edit's check finding nothing at the location: its plans' backups
    /// would fail (restic exit 10) against it, and the editor cannot change a
    /// location: another location is another repository.
    static let noRepositoryHere = "No backups are at this location, so new backups would fail. If they moved, add them at their new location with Add Backup Location."

    /// Whether an edit's Save asks restic first: when it changes what
    /// reaches restic — the location, a credential, the environment — or
    /// the password, any of which a typo turns into every plan failing.
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
        if password != confirm { return "The new passwords don’t match." }
        if password != password.trimmingCharacters(in: .whitespacesAndNewlines) {
            return "Remove the spaces at the start or end of the password."
        }
        return nil
    }

    private static func comparableLocation(_ repository: Repository) -> String {
        ResticPath.normalized(repository.resticRepositoryString)
    }

    /// The repository a plan editor opens on: the plan's own, else the
    /// only one there is. With two or more the picker says Choose and the
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
    /// failed: an error must not be read as "nothing stored". `repositories`
    /// is every configured one, the draft's saved entry among them.
    /// `holdsBackups` (`holdsBackups(atLocalPath:)`): a new one's password
    /// is asked once, not set, so it has no confirmation.
    static func repository(
        _ draft: Repository,
        password: String,
        confirmPassword: String,
        isNew: Bool,
        holdsBackups: Bool,
        hasStoredPassword: Bool?,
        among repositories: [Repository]
    ) -> String? {
        switch draft.kind {
        case .local:
            if draft.localPath.isEmpty { return "Choose a folder to save it." }
        case .sftp:
            if draft.sftpHostName.isEmpty || draft.sftpPath.isEmpty { return "Enter the server and path to save it." }
            if !draft.sftpPortText.isEmpty, !(1 ... 65535).contains(Int(draft.sftpPortText) ?? 0) {
                return "Write a port after the server as user@host:port, from 1 to 65535."
            }
        case .s3:
            if draft.s3Bucket.isEmpty || draft.s3AccessKeyID.isEmpty { return "Enter the bucket and access key ID to save it." }
        }
        // Two entries for one place would be two identical rows, and two
        // schedulers' checks and prunes on one repository. A new one's rule
        // alone: a saved repository's location is fixed, so in an edit it
        // could only grey Save with nothing in the sheet to change.
        let location = comparableLocation(draft)
        if isNew, let other = repositories.first(where: { $0.id != draft.id && comparableLocation($0) == location }) {
            return "“\(other.label(among: repositories))” is already at this location."
        }
        if isNew, holdsBackups {
            if password.isEmpty {
                return "Enter the password for these backups to save it."
            }
        } else if isNew {
            if password.isEmpty {
                return "Set a password to save it."
            }
            if password != confirmPassword {
                return "The passwords don’t match."
            }
        } else if hasStoredPassword == false, password.isEmpty {
            return "Enter the password to save it."
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

    /// Whether an upsert keeps the stored provider secret: a kind with no
    /// secret field writes nothing, and a blank one after a failed Keychain
    /// read keeps what is stored, as the blank password does — the field
    /// could not be prefilled, and an empty value would delete the stored
    /// one.
    static func keepsStoredProviderSecret(secretFieldLabel: String?, readFailed: Bool, typedSecret: String) -> Bool {
        secretFieldLabel == nil || (readFailed && typedSecret.isEmpty)
    }
}
