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

    /// Points the console at a repository before routing to it — the pane's
    /// appear fills only an empty picker, so a route left to it would open
    /// on whichever repository the console last had, or the first.
    func pointConsole(at repositoryID: UUID) {
        console.repositoryID = repositoryID
    }

    /// Runs an arbitrary restic command against a repository and returns
    /// what it printed.
    ///
    /// No `--json` is added: the console exists to show restic's own output,
    /// and the human-readable form is what the user came for.
    ///
    /// A command that may change the backups (`mayChangeSnapshots`: a
    /// forget, a rewrite, a tag, a copy…) re-reads the repository's listing
    /// afterwards, however it ended — a forget can fail part-way — as a
    /// check or prune does, so the sidebar, the Files tabs and the counts
    /// do not list what restic no longer holds until the next refresh.
    func runConsoleCommand(repositoryID: UUID, arguments: [String]) async -> String {
        guard let repository = repository(id: repositoryID) else {
            return "No such repository."
        }
        defer {
            if CommandLineTokenizer.mayChangeSnapshots(arguments) { scheduleSnapshotRefresh(repositoryID: repositoryID) }
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
