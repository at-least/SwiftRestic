import Foundation
import Testing

/// The disabled-Save reason lines: the exact chain each editor's disabled
/// state checks, in the order the sheets present their fields. The wording
/// and the ordering are pinned here — a reordering that makes the footer
/// name a later gap while an earlier one exists is a regression.
@Suite("Editor requirement chains")
struct EditorRequirementTests {
    @Test("the plan editor names the first unmet requirement in tab order")
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
}
