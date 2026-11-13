import Foundation
import Testing

/// The disabled-Save reason lines: the exact chain each editor's disabled
/// state checks, in the order the sheets present their fields. The wording
/// and the ordering are pinned here — a reordering that makes the footer
/// name a later gap while an earlier one exists is a regression.
@Suite("Editor requirement chains")
struct EditorRequirementTests {
    @Test("the plan editor names the first unmet requirement in the order the sheet shows its fields")
    func planRequirementOrdering() {
        var plan = BackupPlan()
        #expect(EditorRequirements.plan(plan, isNew: true, among: []) == "Choose a folder or file to back up.")

        plan.path = "/Users/demo/Documents"
        #expect(EditorRequirements.plan(plan, isNew: true, among: []) == "Choose a backup location to save it.")

        plan.repositoryID = UUID()
        #expect(EditorRequirements.plan(plan, isNew: true, among: []) == nil, "a complete plan has nothing to name")

        plan.path = "  "
        #expect(EditorRequirements.plan(plan, isNew: true, among: []) == "Choose a folder or file to back up.")
    }

    @Test("a path another plan already backs up to the repository cannot be added again; another repository, an edit, or twins an older configuration holds can be saved")
    func planPathIsOncePerRepository() {
        let home = UUID()
        var saved = BackupPlan()
        saved.repositoryID = home
        saved.path = "/Users/demo/Documents"

        var draft = BackupPlan()
        draft.repositoryID = home
        let taken = "This location already has a plan for this folder or file."
        for spelling in ["/Users/demo/Documents", "/Users/demo/Documents/", " /Users/demo/Documents"] {
            draft.path = spelling
            #expect(EditorRequirements.plan(draft, isNew: true, among: [saved]) == taken, "spelled \(spelling)")
        }
        var inHome = saved
        inHome.path = NSHomeDirectory() + "/Documents"
        draft.path = "~/Documents"
        #expect(EditorRequirements.plan(draft, isNew: true, among: [inHome]) == taken)

        draft.path = "/Users/demo/Documents/Taxes"
        #expect(EditorRequirements.plan(draft, isNew: true, among: [saved]) == nil)
        draft.path = "/Users/demo/Documents"
        draft.repositoryID = UUID()
        #expect(EditorRequirements.plan(draft, isNew: true, among: [saved]) == nil)
        #expect(EditorRequirements.plan(saved, isNew: false, among: [saved]) == nil)
        // Twins: earlier builds let two plans back up one folder
        // to one repository, and a plan's path is fixed once saved, so
        // editing either — its schedule, its excludes — must save.
        var twin = saved
        twin.id = UUID()
        #expect(EditorRequirements.plan(saved, isNew: false, among: [saved, twin]) == nil)
        #expect(EditorRequirements.plan(twin, isNew: false, among: [saved, twin]) == nil)
    }

    @Test("a new plan's repository is chosen for it only when there is one to choose")
    func initialRepository() {
        let one = Repository()
        let two = Repository()
        #expect(EditorRequirements.initialRepositoryID(nil, among: [one]) == one.id)
        // Two or more: the picker says Choose, and the footer asks.
        #expect(EditorRequirements.initialRepositoryID(nil, among: [one, two]) == nil)
        #expect(EditorRequirements.initialRepositoryID(nil, among: []) == nil)
        #expect(EditorRequirements.initialRepositoryID(two.id, among: [one, two]) == two.id)
    }

    @Test("Change Password names what stops the change: nothing typed, two that differ, spaces restic would drop")
    func newPasswordRequirement() {
        #expect(EditorRequirements.newPassword("", confirm: "") == "Type the new password twice to change it.")
        #expect(EditorRequirements.newPassword("correct horse", confirm: "correct hose") == "The new passwords don’t match.")
        // restic 0.19.1 trims a password read from --new-password-file:
        // the key would be "pw" while the Keychain stored " pw ".
        #expect(EditorRequirements.newPassword(" pw ", confirm: " pw ")
            == "Remove the spaces at the start or end of the password.")
        #expect(EditorRequirements.newPassword("correct horse", confirm: "correct horse") == nil)
    }

    @Test("a browsed or dropped exclude is the item's own path, glob characters escaped")
    func excludeEntries() {
        #expect(ResticService.globEscaped("/Users/me/a[1].txt") == #"/Users/me/a\[1].txt"#)
    }

    @Test("the repository editor names the first unmet requirement per kind")
    func repositoryRequirementPerKind() {
        var draft = Repository()
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true, holdsBackups: false, hasStoredPassword: nil, among: [])
            == "Choose a folder to save it.")
        draft.localPath = "/Volumes/Backup/restic"
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true, holdsBackups: false, hasStoredPassword: nil, among: [])
            == "Set a password to save it.")

        // Each backend names its own required pair rather than the local one,
        // and every one is pinned so a field rename cannot desync its copy.
        draft.kind = .sftp
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true, holdsBackups: false, hasStoredPassword: nil, among: [])
            == "Enter the server and path to save it.")
        draft.kind = .s3
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true, holdsBackups: false, hasStoredPassword: nil, among: [])
            == "Enter the bucket and access key ID to save it.")
    }

    @Test("a location already added cannot be added again — the two would be one repository under two rows; twins an older configuration holds still save their edits")
    func repositoryLocationIsOnce() {
        var saved = Repository()
        saved.kind = .local
        saved.localPath = "/Volumes/T7/restic"
        var draft = Repository()
        draft.kind = .local
        let taken = "“T7” is already at this location."
        for spelling in ["/Volumes/T7/restic", "/Volumes/T7/restic/"] {
            draft.localPath = spelling
            #expect(EditorRequirements.repository(
                draft, password: "pw", confirmPassword: "pw", isNew: true, holdsBackups: false, hasStoredPassword: nil, among: [saved]
            ) == taken, "spelled \(spelling)")
        }
        var home = saved
        home.localPath = NSHomeDirectory() + "/restic"
        draft.localPath = "~/restic"
        #expect(EditorRequirements.repository(
            draft, password: "pw", confirmPassword: "pw", isNew: true, holdsBackups: false, hasStoredPassword: nil, among: [home]
        ) == "“restic” is already at this location.")
        draft.localPath = "/Volumes/T7/restic-imac"
        #expect(EditorRequirements.repository(
            draft, password: "pw", confirmPassword: "pw", isNew: true, holdsBackups: false, hasStoredPassword: nil, among: [saved]
        ) == nil)
        #expect(EditorRequirements.repository(
            saved, password: "", confirmPassword: "", isNew: false, holdsBackups: false, hasStoredPassword: true, among: [saved]
        ) == nil)
        // Twins: earlier builds named repositories, and one place
        // could be added twice under two names. A saved repository's
        // location is fixed, so its edits — a password this Mac lacks —
        // must save.
        var twin = saved
        twin.id = UUID()
        #expect(EditorRequirements.repository(
            saved, password: "", confirmPassword: "", isNew: false, holdsBackups: false, hasStoredPassword: true, among: [saved, twin]
        ) == nil)
        #expect(EditorRequirements.repository(
            twin, password: "pw", confirmPassword: "", isNew: false, holdsBackups: false, hasStoredPassword: false, among: [saved, twin]
        ) == nil)
    }

    @Test("an SFTP port goes after the host: one that is no port keeps Save grey")
    func sftpPortRequirement() {
        var draft = Repository()
        draft.kind = .sftp
        draft.sftpPath = "/volume1/restic"
        func requirement() -> String? {
            EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: false, holdsBackups: false, hasStoredPassword: true, among: [])
        }
        for bad in ["0", "65536", "22a", " 22", ""] {
            draft.sftpHost = "nas.local:\(bad)"
            if bad.isEmpty {
                #expect(requirement() == nil, "a bare trailing colon is no port")
            } else {
                #expect(requirement() == "Write a port after the server as user@host:port, from 1 to 65535.", "\(bad)")
            }
        }
        for good in ["nas.local", "nas.local:22", "nas.local:2222", "nas.local:65535"] {
            draft.sftpHost = good
            #expect(requirement() == nil, "\(good)")
        }
        draft.sftpHost = ":2222"
        #expect(requirement() == "Enter the server and path to save it.")
        #expect(!draft.isConfigurationComplete, "a port alone names no server")
    }

    @Test("a new location at a folder that already holds backups asks for their password once, with no confirmation")
    func existingBackupsPassword() throws {
        var draft = Repository()
        draft.localPath = "/Volumes/Backup/SwiftRestic Backups"
        func requirement(_ password: String, _ confirm: String, holds: Bool) -> String? {
            EditorRequirements.repository(draft, password: password, confirmPassword: confirm, isNew: true, holdsBackups: holds, hasStoredPassword: nil, among: [])
        }
        #expect(requirement("", "", holds: true) == "Enter the password for these backups to save it.")
        #expect(requirement("pw", "", holds: true) == nil)
        #expect(requirement("pw", "", holds: false) == "The passwords don’t match.")
        #expect(EditorRequirements.firstBackup(
            source: "/Users/me/Documents", folder: draft.localPath, password: "pw", confirmPassword: "",
            holdsBackups: true, among: []
        ) == nil)

        // restic's `config` file at the folder's top is what says it holds backups.
        let folder = FileManager.default.temporaryDirectory.appending(path: "holds-backups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!EditorRequirements.holdsBackups(atLocalPath: folder.path))
        try Data().write(to: folder.appending(path: "config"))
        #expect(EditorRequirements.holdsBackups(atLocalPath: folder.path))
        #expect(!EditorRequirements.holdsBackups(atLocalPath: ""))
    }

    @Test("an edit's Save asks restic first only when the edit changes what reaches restic")
    func editReachesRestic() {
        var initial = Repository()
        initial.kind = .sftp
        initial.sftpHost = "nas.local"
        initial.sftpPath = "/volume1/restic"
        func reaches(_ edit: (inout Repository) -> Void, password: String = "pw", secret: String = "") -> Bool {
            var draft = initial
            edit(&draft)
            return EditorRequirements.editReachesRestic(
                draft: draft, initial: initial,
                password: password, initialPassword: "pw",
                providerSecret: secret, initialProviderSecret: ""
            )
        }
        #expect(!reaches { _ in })
        #expect(reaches { $0.sftpPath = "/volume1/restik" })
        #expect(reaches { $0.sftpHost = "nas.local:2222" })
        #expect(reaches { $0.kind = .local })
        #expect(reaches { $0.extraEnvironment = ["RESTIC_COMPRESSION": "max"] })
        #expect(reaches({ _ in }, password: "pv"))
        #expect(reaches({ $0.kind = .s3; $0.s3Bucket = "bucket"; $0.s3AccessKeyID = "AKIA" }, secret: "s3cret"))
        var bucket = initial
        bucket.kind = .s3
        bucket.s3Bucket = "bucket"
        bucket.s3AccessKeyID = "AKIA"
        initial = bucket
        #expect(reaches { $0.s3AccessKeyID = "AKIB" })
        #expect(reaches({ _ in }, secret: "s3cret"))
    }

    @Test("the password rules only bind a new repository")
    func passwordRules() {
        var draft = Repository()
        draft.localPath = "/Volumes/Backup/restic"

        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true, holdsBackups: false, hasStoredPassword: nil, among: [])
            == "Set a password to save it.")
        #expect(EditorRequirements.repository(draft, password: "secret", confirmPassword: "no", isNew: true, holdsBackups: false, hasStoredPassword: nil, among: [])
            == "The passwords don’t match.")
        #expect(EditorRequirements.repository(draft, password: "secret", confirmPassword: "secret", isNew: true, holdsBackups: false, hasStoredPassword: nil, among: [])
            == nil)
        // An existing repository keeps its Keychain password; blank fields are
        // how "unchanged" is spelled, not a gap.
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: false, holdsBackups: false, hasStoredPassword: true, among: [])
            == nil)
    }

    @Test("an existing repository with no password on this Mac needs one typed before it can be saved")
    func missingStoredPassword() {
        var draft = Repository()
        draft.localPath = "/Volumes/Backup/restic"

        // Known absent: the blank field is the gap the listing already names.
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: false, holdsBackups: false, hasStoredPassword: false, among: [])
            == "Enter the password to save it.")
        #expect(EditorRequirements.repository(draft, password: "secret", confirmPassword: "", isNew: false, holdsBackups: false, hasStoredPassword: false, among: [])
            == nil)
        // Stored, or not yet known (the Keychain still answering, or its
        // read failed): a blank field means unchanged.
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: false, holdsBackups: false, hasStoredPassword: true, among: [])
            == nil)
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: false, holdsBackups: false, hasStoredPassword: nil, among: [])
            == nil)
        draft.localPath = ""
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: false, holdsBackups: false, hasStoredPassword: false, among: [])
            == "Choose a folder to save it.")
    }

    @Test("the probe's password is the typed one, else the stored one, and never an empty string")
    func probePassword() throws {
        #expect(try EditorRequirements.probePassword(typed: "typed", stored: "stored", repositoryName: "Vault") == "typed")
        #expect(try EditorRequirements.probePassword(typed: "", stored: "stored", repositoryName: "Vault") == "stored")
        for stored in [nil, ""] {
            #expect(throws: ResticError.passwordMissing(repositoryName: "Vault")) {
                try EditorRequirements.probePassword(typed: "", stored: stored, repositoryName: "Vault")
            }
        }
    }

    @Test("a blank provider secret after a failed Keychain read keeps what is stored; no secret field writes nothing")
    func keepsStoredProviderSecret() {
        #expect(EditorRequirements.keepsStoredProviderSecret(secretFieldLabel: nil, readFailed: false, typedSecret: "") == true)
        #expect(EditorRequirements.keepsStoredProviderSecret(secretFieldLabel: nil, readFailed: true, typedSecret: "key") == true)
        // The read failed, so the field could not be prefilled: blank keeps
        // what is stored, a typed value replaces it.
        #expect(EditorRequirements.keepsStoredProviderSecret(secretFieldLabel: "Secret access key", readFailed: true, typedSecret: "") == true)
        #expect(EditorRequirements.keepsStoredProviderSecret(secretFieldLabel: "Secret access key", readFailed: true, typedSecret: "key") == false)
        // A read that worked: the user's deliberate clear deletes the stored secret.
        #expect(EditorRequirements.keepsStoredProviderSecret(secretFieldLabel: "Secret access key", readFailed: false, typedSecret: "") == false)
    }

}
