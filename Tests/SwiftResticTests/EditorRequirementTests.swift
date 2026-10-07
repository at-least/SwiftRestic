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
        #expect(EditorRequirements.plan(plan) == "Name the plan to save it.")

        plan.name = "Documents"
        #expect(EditorRequirements.plan(plan) == "Choose a repository to save it.")

        plan.repositoryID = UUID()
        #expect(EditorRequirements.plan(plan) == "Add at least one folder to back up.")

        plan.sources = ["/Users/demo/Documents"]
        #expect(EditorRequirements.plan(plan) == nil, "a complete plan has nothing to name")

        // A whitespace name is as absent as an empty one.
        plan.name = "   "
        #expect(EditorRequirements.plan(plan) == "Name the plan to save it.")
    }

    @Test("a new plan's repository is chosen for it only when there is one to choose")
    func initialRepository() {
        let one = Repository()
        let two = Repository()
        #expect(EditorRequirements.initialRepositoryID(nil, among: [one]) == one.id)
        // Two or more: the picker says Choose…, and the footer asks.
        #expect(EditorRequirements.initialRepositoryID(nil, among: [one, two]) == nil)
        #expect(EditorRequirements.initialRepositoryID(nil, among: []) == nil)
        // A plan that has one keeps it.
        #expect(EditorRequirements.initialRepositoryID(two.id, among: [one, two]) == two.id)
    }

    @Test("Change Password names what stops the change: nothing typed, two that differ, spaces restic would drop")
    func newPasswordRequirement() {
        #expect(EditorRequirements.newPassword("", confirm: "") == "Type the new password twice to change it.")
        #expect(EditorRequirements.newPassword("correct horse", confirm: "correct hose") == "The two new passwords differ.")
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

    @Test("the repository editor names the first unmet requirement per kind")
    func repositoryRequirementPerKind() {
        var draft = Repository()
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true)
            == "Name the repository to save it.")

        draft.name = "Vault"
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true)
            == "Choose a folder to save it.")
        draft.localPath = "/Volumes/Backup/restic"
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true)
            == "Set a repository password to save it.")

        // Each backend names its own required pair rather than the local one,
        // and every one is pinned so a field rename cannot desync its copy.
        draft.kind = .sftp
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true)
            == "Enter the host and path to save it.")
        draft.kind = .s3
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true)
            == "Enter the bucket and access key ID to save it.")
        draft.kind = .b2
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true)
            == "Enter the bucket and account ID to save it.")
        draft.kind = .azure
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true)
            == "Enter the container and account name to save it.")
        draft.kind = .gcs
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true)
            == "Enter the bucket and service account file to save it.")
        draft.kind = .rest
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true)
            == "Enter the server URL to save it.")
        draft.kind = .rclone
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true)
            == "Enter the rclone remote to save it.")
    }

    @Test("an SFTP port goes in Port: one typed into Host, or a field that is no port, keeps Save grey")
    func sftpPortRequirement() {
        var draft = Repository()
        draft.name = "NAS"
        draft.kind = .sftp
        draft.sftpPath = "/volume1/restic"
        // restic would dial 22 and read "2222:/volume1/restic" as the path.
        draft.sftpHost = "nas.local:2222"
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: false)
            == "Put the port in Port, not in Host.")
        draft.sftpHost = "nas.local"
        for bad in ["0", "65536", "22a", " 22"] {
            draft.sftpPort = bad
            #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: false)
                == "Port is a number from 1 to 65535.", "\(bad)")
        }
        for good in ["", "22", "2222", "65535"] {
            draft.sftpPort = good
            #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: false) == nil, "\(good)")
        }
    }

    @Test("the password rules only bind a new repository")
    func passwordRules() {
        var draft = Repository()
        draft.name = "Vault"
        draft.localPath = "/Volumes/Backup/restic"

        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: true)
            == "Set a repository password to save it.")
        #expect(EditorRequirements.repository(draft, password: "secret", confirmPassword: "no", isNew: true)
            == "The passwords do not match yet.")
        #expect(EditorRequirements.repository(draft, password: "secret", confirmPassword: "secret", isNew: true)
            == nil)
        // An existing repository keeps its Keychain password; blank fields are
        // how "unchanged" is spelled, not a gap.
        #expect(EditorRequirements.repository(draft, password: "", confirmPassword: "", isNew: false)
            == nil)
    }

    @Test("Test Connection's answer for a path with no repository says what Save will do in this mode")
    func missingRepositoryWords() {
        // A new repository is created on Save.
        #expect(EditorRequirements.noRepositoryYet(isNew: true)
            == "No repository at that location yet. Saving will create one.")
        // An edit's Save creates nothing: its plans would fail against it.
        #expect(EditorRequirements.noRepositoryYet(isNew: false)
            == "No repository is at that path — backups to it would fail until one is created. Point it at the folder that holds the repository.")
    }
}
