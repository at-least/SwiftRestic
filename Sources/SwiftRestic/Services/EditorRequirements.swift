import Foundation

/// The disabled-Save reasons the editor sheets show beside their buttons.
///
/// Pure and view-free so both test targets compile them: the caption is the
/// same chain the disabled state checks, spelled in field order, and a test
/// pins the ordering — a reordering that makes the footer name a later gap
/// while an earlier one exists is a regression.
enum EditorRequirements {
    /// The first requirement `BackupPlan.isConfigurationComplete` checks but
    /// does not name, in the order the plan sheet's tabs present them.
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

    /// The first requirement `Repository.isConfigurationComplete` plus the
    /// password rules bind only a new repository — an existing one spells
    /// "unchanged" with blank fields, not a gap.
    static func repository(
        _ draft: Repository,
        password: String,
        confirmPassword: String,
        isNew: Bool
    ) -> String? {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Name the repository to save it."
        }
        switch draft.kind {
        case .local:
            if draft.localPath.isEmpty { return "Choose a folder to save it." }
        case .sftp:
            if draft.sftpHost.isEmpty || draft.sftpPath.isEmpty { return "Enter the host and path to save it." }
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
        }
        return nil
    }
}
