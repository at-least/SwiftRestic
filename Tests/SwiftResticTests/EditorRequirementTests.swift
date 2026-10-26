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
        #expect(EditorRequirements.plan(plan, isNew: true, among: []) == "Choose a repository to save it.")

        plan.repositoryID = UUID()
        #expect(EditorRequirements.plan(plan, isNew: true, among: []) == nil, "a complete plan has nothing to name")

        // Whitespace is as absent as nothing.
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
        let taken = "This repository already has a plan for this folder or file."
        // Spelled the same, with a trailing slash, or padded: one path.
        for spelling in ["/Users/demo/Documents", "/Users/demo/Documents/", " /Users/demo/Documents"] {
            draft.path = spelling
            #expect(EditorRequirements.plan(draft, isNew: true, among: [saved]) == taken, "spelled \(spelling)")
        }
        // A tilde is the home folder.
        var inHome = saved
        inHome.path = NSHomeDirectory() + "/Documents"
        draft.path = "~/Documents"
        #expect(EditorRequirements.plan(draft, isNew: true, among: [inHome]) == taken)

        // A folder inside it is another path.
        draft.path = "/Users/demo/Documents/Taxes"
        #expect(EditorRequirements.plan(draft, isNew: true, among: [saved]) == nil)
        // The same folder to another repository is another plan.
        draft.path = "/Users/demo/Documents"
        draft.repositoryID = UUID()
        #expect(EditorRequirements.plan(draft, isNew: true, among: [saved]) == nil)
        // A saved plan's own entry is not another plan.
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
        // A plan that has one keeps it.
        #expect(EditorRequirements.initialRepositoryID(two.id, among: [one, two]) == two.id)
    }

    @Test("Change Password names what stops the change: nothing typed, two that differ, spaces restic would drop")
    func newPasswordRequirement() {
        #expect(EditorRequirements.newPassword("", confirm: "") == "Type the new password twice to change it.")
        #expect(EditorRequirements.newPassword("correct horse", confirm: "correct hose") == "The new passwords don’t match.")
        // restic 0.19.1 trims a password read from --new-password-file:
        // the key would be "pw" while the Keychain stored " pw ".
        #expect(EditorRequirements.newPassword(" pw ", confirm: " pw ")
            == "restic drops spaces at the ends of a new password — remove them.")
        #expect(EditorRequirements.newPassword("correct horse", confirm: "correct horse") == nil)
    }

    @Test("a browsed or dropped exclude is the item's own path, glob characters escaped; a typed one is a pattern")
    func excludeEntries() {
        #expect(PathListEntry.value(for: " /Users/me/a[1].txt ", expandsTildeInPath: false, escapesGlobs: true)
            == #"/Users/me/a\[1].txt"#)
        #expect(PathListEntry.value(for: "**/node_modules", expandsTildeInPath: false, escapesGlobs: false)
            == "**/node_modules")
        #expect(PathListEntry.value(for: "   ", expandsTildeInPath: false, escapesGlobs: true) == nil)
        // Sources: a real path, its tilde expanded.
        #expect(PathListEntry.value(for: " ~/Documents", expandsTildeInPath: true, escapesGlobs: false)
            == NSHomeDirectory() + "/Documents")
    }

    @Test("an exclude edited in place is written as typed; blank or another row's value holds the row's value from before; finishing on a duplicate drops the row")
    func excludeEdits() {
        let paths = ["**/*.iso", #"/Users/me/a\[1].txt"#, "~/Downloads"]
        // Each keystroke lands, so Save mid-edit saves what the field shows.
        #expect(PathListEntry.typing(" **/*.dmg ", at: 0, original: "**/*.iso", in: paths)
            == ["**/*.dmg", #"/Users/me/a\[1].txt"#, "~/Downloads"])
        // Erased down to nothing after a partial value: the original, not the fragment.
        let partial = ["*", #"/Users/me/a\[1].txt"#, "~/Downloads"]
        #expect(PathListEntry.typing("  ", at: 0, original: "**/*.iso", in: partial) == paths)
        #expect(PathListEntry.typing("~/Downloads", at: 0, original: "**/*.iso", in: partial) == paths)
        // Finished on another row's value: the edited row goes.
        #expect(PathListEntry.finishing("~/Downloads", at: 0, in: paths)
            == [#"/Users/me/a\[1].txt"#, "~/Downloads"])
        #expect(PathListEntry.finishing("**/*.iso", at: 0, in: paths) == paths)
        #expect(PathListEntry.finishing("", at: 0, in: paths) == paths)
    }

    @Test("the repository editor names the first unmet requirement per kind")
    func repositoryRequirementPerKind() {
        var draft = Repository()
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true, hasStoredPassword: nil, among: [])
            == "Choose a folder to save it.")
        draft.localPath = "/Volumes/Backup/restic"
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true, hasStoredPassword: nil, among: [])
            == "Set a repository password to save it.")

        // Each backend names its own required pair rather than the local one,
        // and every one is pinned so a field rename cannot desync its copy.
        draft.kind = .sftp
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true, hasStoredPassword: nil, among: [])
            == "Enter the host and path to save it.")
        draft.kind = .s3
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true, hasStoredPassword: nil, among: [])
            == "Enter the bucket and access key ID to save it.")
        draft.kind = .b2
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true, hasStoredPassword: nil, among: [])
            == "Enter the bucket and key ID to save it.")
        draft.kind = .azure
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true, hasStoredPassword: nil, among: [])
            == "Enter the container and account name to save it.")
        draft.kind = .gcs
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true, hasStoredPassword: nil, among: [])
            == "Enter the bucket and service account JSON to save it.")
        draft.kind = .rest
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true, hasStoredPassword: nil, among: [])
            == "Enter the server URL to save it.")
        draft.kind = .rclone
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true, hasStoredPassword: nil, among: [])
            == "Choose an rclone remote to save it.")
    }

    @Test("a location already added cannot be added again — the two would be one repository under two rows; twins an older configuration holds still save their edits")
    func repositoryLocationIsOnce() {
        var saved = Repository()
        saved.kind = .local
        saved.localPath = "/Volumes/T7/restic"
        var draft = Repository()
        draft.kind = .local
        let taken = "“T7” is already at this location."
        // Spelled the same, or with a trailing slash: one place.
        for spelling in ["/Volumes/T7/restic", "/Volumes/T7/restic/"] {
            draft.localPath = spelling
            #expect(EditorRequirements.repository(
                draft, password: "pw", confirmPassword: "pw", isNew: true, hasStoredPassword: nil, among: [saved]
            ) == taken, "spelled \(spelling)")
        }
        // A tilde is the home folder.
        var home = saved
        home.localPath = NSHomeDirectory() + "/restic"
        draft.localPath = "~/restic"
        #expect(EditorRequirements.repository(
            draft, password: "pw", confirmPassword: "pw", isNew: true, hasStoredPassword: nil, among: [home]
        ) == "“restic” is already at this location.")
        // A server's repository is its URL.
        var server = Repository()
        server.kind = .rest
        server.restURL = "rest:http://nas.local:8000/"
        var again = Repository()
        again.kind = .rest
        again.restURL = "rest:http://nas.local:8000"
        #expect(EditorRequirements.repository(
            again, password: "pw", confirmPassword: "pw", isNew: true, hasStoredPassword: nil, among: [server]
        ) == "“nas.local” is already at this location.")
        // Another folder on the drive is another repository, and a saved
        // repository being edited is not in its own way.
        draft.localPath = "/Volumes/T7/restic-imac"
        #expect(EditorRequirements.repository(
            draft, password: "pw", confirmPassword: "pw", isNew: true, hasStoredPassword: nil, among: [saved]
        ) == nil)
        #expect(EditorRequirements.repository(
            saved, password: "", confirmPassword: "", isNew: false, hasStoredPassword: true, among: [saved]
        ) == nil)
        // Twins: earlier builds named repositories, and one place
        // could be added twice under two names. A saved repository's
        // location is fixed, so its edits — a password this Mac lacks, a
        // bandwidth limit — must save.
        var twin = saved
        twin.id = UUID()
        #expect(EditorRequirements.repository(
            saved, password: "", confirmPassword: "", isNew: false, hasStoredPassword: true, among: [saved, twin]
        ) == nil)
        #expect(EditorRequirements.repository(
            twin, password: "pw", confirmPassword: "", isNew: false, hasStoredPassword: false, among: [saved, twin]
        ) == nil)
    }

    @Test("an SFTP port goes in Port: one typed into Host, or a field that is no port, keeps Save grey")
    func sftpPortRequirement() {
        var draft = Repository()
        draft.kind = .sftp
        draft.sftpPath = "/volume1/restic"
        // restic would dial 22 and read "2222:/volume1/restic" as the path.
        draft.sftpHost = "nas.local:2222"
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: false, hasStoredPassword: true, among: [])
            == "Put the port in Port, not in Host.")
        draft.sftpHost = "nas.local"
        for bad in ["0", "65536", "22a", " 22"] {
            draft.sftpPort = bad
            #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: false, hasStoredPassword: true, among: [])
                == "Port is a number from 1 to 65535.", "\(bad)")
        }
        for good in ["", "22", "2222", "65535"] {
            draft.sftpPort = good
            #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: false, hasStoredPassword: true, among: []) == nil, "\(good)")
        }
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
        // Saved at once: nothing restic sees changed.
        #expect(!reaches { _ in })
        #expect(!reaches { $0.maintenance.checkEnabled.toggle() })
        #expect(!reaches { $0.hooks = [BackupHook()] })
        // Checked first.
        #expect(reaches { $0.sftpPath = "/volume1/restik" })
        #expect(reaches { $0.sftpPort = "2222" })
        #expect(reaches { $0.kind = .local })
        #expect(reaches { $0.extraEnvironment = ["RESTIC_COMPRESSION": "max"] })
        #expect(reaches({ _ in }, password: "pv"))
        #expect(reaches({ $0.kind = .rest; $0.restURL = "https://host:8000/" }, secret: "s3cret"))
        var rest = initial
        rest.kind = .rest
        rest.restURL = "https://host:8000/"
        initial = rest
        #expect(reaches { $0.restUser = "alice" })
        #expect(reaches({ _ in }, secret: "s3cret"))
    }

    @Test("the password rules only bind a new repository")
    func passwordRules() {
        var draft = Repository()
        draft.localPath = "/Volumes/Backup/restic"

        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true, hasStoredPassword: nil, among: [])
            == "Set a repository password to save it.")
        #expect(EditorRequirements.repository(draft, password: "secret", confirmPassword: "no", isNew: true, hasStoredPassword: nil, among: [])
            == "The passwords don’t match.")
        #expect(EditorRequirements.repository(draft, password: "secret", confirmPassword: "secret", isNew: true, hasStoredPassword: nil, among: [])
            == nil)
        // An existing repository keeps its Keychain password; blank fields are
        // how "unchanged" is spelled, not a gap.
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: false, hasStoredPassword: true, among: [])
            == nil)
    }

    @Test("an existing repository with no password on this Mac needs one typed before it can be saved")
    func missingStoredPassword() {
        var draft = Repository()
        draft.localPath = "/Volumes/Backup/restic"

        // Known absent: the blank field is the gap the listing already names.
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: false, hasStoredPassword: false, among: [])
            == "Enter the repository password to save it.")
        #expect(EditorRequirements.repository(draft, password: "secret", confirmPassword: "", isNew: false, hasStoredPassword: false, among: [])
            == nil)
        // Stored, or not yet known (the Keychain still answering, or its
        // read failed): a blank field means unchanged.
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: false, hasStoredPassword: true, among: [])
            == nil)
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: false, hasStoredPassword: nil, among: [])
            == nil)
        // The location's gaps come first, in field order.
        draft.localPath = ""
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: false, hasStoredPassword: false, among: [])
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

    @Test("Test Connection's answer for a path with no repository says what Save will do in this mode")
    func missingRepositoryWords() {
        // A new repository is created on Save.
        #expect(EditorRequirements.noRepositoryYet(isNew: true)
            == "No repository at that location yet. Saving will create one.")
        // An edit's Save creates nothing: its plans would fail against it.
        #expect(EditorRequirements.noRepositoryYet(isNew: false)
            == "No repository is at this location, so its backups would fail. If the repository moved, add it at its new location with Add Repository.")
    }
}
