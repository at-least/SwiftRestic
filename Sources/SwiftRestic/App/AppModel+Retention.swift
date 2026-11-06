import Foundation

extension AppModel {
    /// What `plan`'s retention would remove right now: a plain await with no
    /// slot and nothing marked busy (`--no-lock` reads beside a backup),
    /// cancelled with the caller's task. Takes a value, so an unsaved draft
    /// travels too.
    func previewRetention(plan: BackupPlan) async throws -> RetentionPreview {
        guard let repository = repository(id: plan.repositoryID)
        else { throw ResticError.repositoryMissing }
        do {
            let (service, context) = try await resticContext(for: repository)
            return try await service.forgetPreview(context, plan: plan)
        } catch {
            noteAuthFailure(error, repositoryID: repository.id)
            throw error
        }
    }
}
