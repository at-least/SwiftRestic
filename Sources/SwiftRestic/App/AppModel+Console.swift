import Foundation

extension AppModel {
    // MARK: - Console

    /// Runs an arbitrary restic command against a repository and returns what it
    /// printed.
    ///
    /// No `--json` is added: the console exists to show restic's own output, and
    /// the human-readable form is what the user came for.
    func runConsoleCommand(repositoryID: UUID, arguments: [String]) async -> String {
        guard let repository = repository(id: repositoryID) else {
            return "No such repository."
        }
        do {
            let service = try service()
            let context = try await context(for: repository)
            let result = try await service.runRaw(context, arguments: arguments)
            return result.isEmpty ? "(no output)" : result
        } catch {
            return error.localizedDescription
        }
    }
}
