import Foundation

extension AppModel {
    // MARK: - Console

    /// The console pane's appear moment: the default repository and the
    /// persisted history come from the configuration the model owns.
    func consoleDidAppear() {
        console.appear(
            repositoryID: configuration.repositories.first?.id,
            persistedHistory: configuration.settings.consoleHistory
        )
    }

    /// Runs an arbitrary restic command against a repository and returns
    /// what it printed.
    ///
    /// No `--json` is added: the console exists to show restic's own output,
    /// and the human-readable form is what the user came for.
    func runConsoleCommand(repositoryID: UUID, arguments: [String]) async -> String {
        guard let repository = repository(id: repositoryID) else {
            return "No such repository."
        }
        do {
            let (service, context) = try await resticContext(for: repository)
            let result = try await service.runRaw(context, arguments: arguments)
            return result.isEmpty ? "(no output)" : result
        } catch {
            noteAuthFailure(error, repositoryID: repositoryID)
            return error.localizedDescription
        }
    }
}
