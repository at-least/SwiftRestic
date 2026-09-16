import Foundation
import Observation
import SwiftUI

/// The single source of truth the SwiftUI views observe.
///
/// Everything that touches persisted state happens here on the main actor;
/// restic itself runs on the `ResticRunner` actor and reports back by hopping
/// home.
///
/// The implementation is split across sibling files by domain
/// (`AppModel+Backup.swift`, `AppModel+Maintenance.swift`, …); the stored
/// state and the debounced save below are what every domain reads and writes.
@MainActor
@Observable
final class AppModel {
    // MARK: Persisted state

    var configuration = AppConfiguration() {
        didSet { scheduleSave() }
    }

    // MARK: Runtime state

    var resticVersion: String = ""
    var binaryProblem: String?
    var activity: [UUID: PlanActivity] = [:]
    /// Repository upkeep currently in flight, keyed by repository.
    var maintenance: [UUID: MaintenanceActivity] = [:]
    var snapshots: [UUID: [Snapshot]] = [:]
    var repositoryStats: [UUID: RepositoryStats] = [:]
    var loadingSnapshots: Set<UUID> = []
    /// The last settled listing outcome per repository. Kept apart from the
    /// rows themselves: a failed refresh must read as "unknown", never as the
    /// empty list it used to be folded into.
    var snapshotListingOutcomes: [UUID: SnapshotListingOutcome] = [:]
    /// When the listing last succeeded. A freshness stamp the surfaces show
    /// so a number can always be traced to the moment it was read.
    var snapshotsLoadedAt: [UUID: Date] = [:]
    /// Repositories with no password in the Keychain yet. Upkeep is not scheduled
    /// for these: there is nothing to run, and stamping a "last checked" time for
    /// a check that never happened would be a lie on the repository screen.
    var repositoriesMissingPassword: Set<UUID> = []
    var isLoaded = false
    /// True while `bootstrap` is still reading the configuration and locating
    /// restic. The views show a loading state instead of the empty states:
    /// on a slow disk the default (empty) configuration otherwise reads as a
    /// fresh install — or as breakage — for the first seconds.
    var isBootstrapping = false
    /// Mirrors `LoginItem.status`, which is not observable on its own.
    var startsAtLogin = false
    /// Transient messages shown at the top of the detail panes, newest first.
    /// A queue rather than a single slot: an unread error must not be erased
    /// by the next message — a failing-repository refresh, a finished restore
    /// and a notification failure can land minutes apart.
    var banners: [Banner] = []

    /// Per plan, when its newest problem was last marked seen — the stamp
    /// behind the sidebar's Mail dot. View state, not configuration: it lives
    /// in UserDefaults (see `ProblemDotsStore`), never in config.json, because
    /// whether a failure has been looked at is this device's reading progress,
    /// not a setting. See `AppModel+ProblemDots.swift`.
    var problemsSeenAt: [UUID: Date]

    /// Progress of a picker-started restore, of which there is at most one
    /// (drag restores track no progress — their feedback is the drop itself).
    var restoreActivity: OperationProgress?
    var restoreDescription: String = ""
    /// The repository the running restore reads from. Deleting it cancels the
    /// restore; kept beside the task because the task alone cannot be asked
    /// what it is working on.
    var restoreRepositoryID: UUID?

    let store: ConfigStore
    let secrets: SecretStore
    /// Resolved restic contexts per repository (repo string + credentials +
    /// settings), so a restic call does not re-read the Keychain every time —
    /// a refresh alone used to pay the read twice. Entries are rebuilt when
    /// the repository value or rate limits change (`AppModel.context(for:)`'s
    /// key), and dropped on secret edits (`upsert`), repository removal, and
    /// auth-class failures (`noteAuthFailure`). Holds secrets no longer than
    /// the app already holds them in each child's environment.
    @ObservationIgnored var resolvedContexts:
        [UUID: (key: ResolvedContextKey, context: RepositoryContext)] = [:]
    /// Where view-state stamps (the seen-problem marks) persist. Injectable
    /// so tests never touch the real defaults, the same way secrets never
    /// touch the login Keychain.
    let viewDefaults: UserDefaults
    let runner = ResticRunner()
    /// The per-repository snapshot indexes and their upkeep. A cache with a
    /// rebuild path: its failures are its own, never the refresh's or the
    /// backup's. See `IndexCoordinator`.
    let indexCoordinator = IndexCoordinator()
    /// State of the restic console pane (see `ConsoleModel`); its two
    /// injected closures are set below, at the end of `init`.
    let console = ConsoleModel()
    var binary: ResticBinary?
    /// In-flight runs and the sends quitting must drain — the structural
    /// replacement for the per-kind task dictionaries `shutdown` used to
    /// enumerate by hand. See `TaskRegistry`.
    @ObservationIgnored let tasks = TaskRegistry()
    var schedulerTask: Task<Void, Never>?
    var saveTask: Task<Void, Never>?
    /// Repositories whose last refresh already announced a stats failure.
    /// The banner is a transition signal, not a nag: a repository whose stats
    /// keep failing says it once, and says it again only after a success in
    /// between proved the failure was gone.
    @ObservationIgnored var statsFailureNoted: Set<UUID> = []
    private var isSaving = false
    /// Set while `shutdown` is unwinding. A run cancelled this way was not
    /// stopped by the user, and the run record should say so: "Cancelled" sends
    /// someone hunting for a cancel click that never happened.
    var isShuttingDown = false

    init(
        store: ConfigStore = ConfigStore(),
        secrets: SecretStore = .keychain,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.secrets = secrets
        self.viewDefaults = defaults
        self.problemsSeenAt = ProblemDotsStore.load(from: defaults)
        // The console's whole view of its owner: run a command, persist the
        // history. Two closures instead of the back-reference every method
        // used to take. The fallback matches ResticError.cancelled's words —
        // a gone owner is the quit unwinding, and the pane should say what
        // happened the way the rest of the app does.
        console.runCommand = { [weak self] repositoryID, arguments in
            await self?.runConsoleCommand(repositoryID: repositoryID, arguments: arguments)
                ?? "The operation was cancelled."
        }
        console.persistHistory = { [weak self] history in
            self?.configuration.settings.consoleHistory = history
        }
    }

    // MARK: - Persistence

    /// Coalesces rapid edits (typing in a text field) into one write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.flushSave()
        }
    }

    func flushSave() async {
        guard isLoaded else { return }
        // Another write is in progress: wait for it and then write the newer
        // state. Skipping instead would drop the latest edit for good — nothing
        // else would save it, including the single flush at shutdown.
        while isSaving { await Task.yield() }
        isSaving = true
        defer { isSaving = false }
        let snapshot = configuration
        do {
            try await store.save(snapshot)
        } catch {
            post(Banner(
                title: "Could not save your configuration",
                message: error.localizedDescription,
                isError: true
            ))
        }
    }
}
