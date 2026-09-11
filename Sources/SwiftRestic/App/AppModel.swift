import Foundation
import Observation

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

    /// Transient, never persisted: whether Activity shows every run or only
    /// problems. Overview's problem rows and failures tile turn it on when they
    /// send the user over.
    var activityShowsProblemsOnly = false

    /// The run a detail surface asked Activity to land selected — the plan
    /// page's "Last backup" tile, Arq's "View Latest Backup Record…" pattern:
    /// the timestamp is the handle to its own record. Transient, never
    /// persisted; Activity consumes and clears it.
    var activityFocusRunID: RunRecord.ID?

    /// Set when something asks for the new-repository sheet before the window
    /// that presents it exists — the tray's `unconfigured` face, or the File
    /// command with the window closed. RootView consumes and clears it on
    /// `onAppear` (window opening fresh) or `onChange` (window already on
    /// screen), so the intent survives no matter which order window creation
    /// and the request land in. Transient, never persisted.
    var pendingNewRepository = false

    /// The pane the sidebar is showing, bound from RootView so the Backup
    /// menu can disable against it.
    var sidebarSelection: SidebarItem?

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
    /// Where view-state stamps (the seen-problem marks) persist. Injectable
    /// so tests never touch the real defaults, the same way secrets never
    /// touch the login Keychain.
    let viewDefaults: UserDefaults
    let runner = ResticRunner()
    /// State of the restic console pane (see `ConsoleModel`).
    let console = ConsoleModel()
    var binary: ResticBinary?
    var planTasks: [UUID: Task<Void, Never>] = [:]
    var maintenanceTasks: [UUID: Task<Void, Never>] = [:]
    /// Start pings in flight. Tracked so quitting mid-backup cannot drop the one
    /// that arms a monitor's timer.
    var pendingPings: [Task<Void, Never>] = []
    var restoreTask: Task<Void, Never>?
    var schedulerTask: Task<Void, Never>?
    var saveTask: Task<Void, Never>?
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
