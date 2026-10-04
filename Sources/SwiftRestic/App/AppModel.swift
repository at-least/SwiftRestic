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
        didSet {
            // Array `!=` short-circuits on shared storage, so an edit that
            // leaves the history alone costs no element comparison.
            if oldValue.runs != configuration.runs {
                backupRunsBySnapshot = RunRecord.backupRunsBySnapshot(configuration.runs)
            }
            // A plan added, removed, renamed or moved to another repository
            // moves backups between shelves, or renames one.
            if oldValue.plans != configuration.plans {
                for id in snapshots.keys { reshelve(id) }
            }
            scheduleSave()
        }
    }
    /// The backup run that wrote each snapshot, derived once per history
    /// write rather than by every row that shows a snapshot (the sidebar's
    /// backups, Activity's run drawer): 0.3 ms to build over 2,000 records
    /// (swiftc probe, 2026-09-26). A snapshot whose run was trimmed from the
    /// history, or never recorded here, is simply absent — unknown, never
    /// complete.
    private(set) var backupRunsBySnapshot: [String: RunRecord] = [:]

    /// The backup run that wrote a snapshot, while the history still holds
    /// it — the join behind the incomplete marks.
    func backupRun(forSnapshot id: String) -> RunRecord? {
        backupRunsBySnapshot[id]
    }

    // MARK: Runtime state

    var resticVersion: String = ""
    var binaryProblem: String?
    var activity: [UUID: PlanActivity] = [:]
    /// Live backup progress per plan, in its own observable storage: a
    /// restic status tick (~1/sec) lands here and invalidates only the views
    /// that read progress — the running strip and nothing else. `activity`
    /// keeps the phase strip, the sidebar's rows and the Protection line's
    /// rows, which must not re-render per tick; the pair is installed and
    /// retired together by `installPlanActivity` and the run's unwind.
    var planProgress: [UUID: OperationProgress] = [:]
    /// Repository upkeep currently in flight, keyed by repository.
    var maintenance: [UUID: MaintenanceActivity] = [:]
    var snapshots: [UUID: [Snapshot]] = [:] {
        didSet {
            // Array `!=` short-circuits on shared storage, so only the
            // repository whose listing was written regroups.
            for id in Set(oldValue.keys).union(snapshots.keys) where oldValue[id] != snapshots[id] {
                reshelve(id)
            }
        }
    }
    /// `snapshots` sorted to where the sidebar shows them, derived once per
    /// listing or plan write. The sidebar's body re-runs on every selection
    /// and configuration change for every repository, folded ones included,
    /// and grouping by lineage there cost 12–18 ms per sidebar update at two
    /// repositories of ~8.7k snapshots against ~3 ms without it (measured in
    /// a SwiftUI harness mirroring the sidebar, 2026-09-26 — not in the
    /// running app).
    private(set) var backupShelves: [UUID: BackupShelves] = [:]
    var repositoryStats: [UUID: RepositoryStats] = [:]
    var loadingSnapshots: Set<UUID> = []
    /// Refreshes that arrived while one was already in flight. Each is run
    /// once the in-flight refresh lands — dropped, the snapshot a just-
    /// finished backup wrote would stay invisible until some unrelated
    /// refresh happened along.
    @ObservationIgnored var pendingSnapshotRefreshes: Set<UUID> = []
    /// The last settled listing outcome per repository. Kept apart from the
    /// rows themselves: a failed refresh must read as "unknown", never as the
    /// empty list it used to be folded into.
    var snapshotListingOutcomes: [UUID: SnapshotListingOutcome] = [:]
    /// When the listing last succeeded. A freshness stamp the surfaces show
    /// so a number can always be traced to the moment it was read.
    var snapshotsLoadedAt: [UUID: Date] = [:]
    /// Repositories whose first completed listing the add-with-history
    /// landing has already been considered for — model state, not window
    /// state, so a closed and reopened main window cannot re-arm the
    /// reveal. Dropped with the repository's other runtime state.
    @ObservationIgnored var adoptionLandingsConsidered: Set<UUID> = []
    /// The last listing generation handed out, one counter for every
    /// repository — see `nextListingGeneration`. Only the index reads these
    /// numbers, and it compares them only within one repository.
    @ObservationIgnored var listingGeneration: UInt64 = 0
    /// The generation `snapshots` was read under, per repository, so a
    /// rebuild of the index re-sends the held listing under its own number.
    @ObservationIgnored var snapshotsGeneration: [UUID: UInt64] = [:]
    /// The newest generation the index has taken, per repository — set as
    /// its reconcile returns, whatever it decided. Until it is the
    /// generation `snapshots` was read under, the index answers for an
    /// older listing (`indexIsComplete`). Observed: the Files views read
    /// again the moment it moves, rather than at their next recheck.
    var indexTakenGeneration: [UUID: UInt64] = [:]
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
    /// Whether the login item waits for approval in System Settings — the
    /// daemon's answer only, written beside `startsAtLogin` from the same
    /// read and never optimistically.
    var loginItemNeedsApproval = false
    /// Whether this copy could be registered as a login item, read once at
    /// launch so the plan editor's start-at-login offer does not resolve
    /// symlinks on every render. It feeds only what the surfaces offer:
    /// registering keeps its own live check (`performSetStartsAtLogin`).
    @ObservationIgnored let loginItemInstallable: Bool
    /// Whether SwiftRestic — and so its restic — may read what Full Disk
    /// Access guards. Probed, not asked: see `refreshFullDiskAccess()`.
    var fullDiskAccess: FullDiskAccessStatus = .unknown
    /// The probe behind `fullDiskAccess`. Injectable because the real one
    /// answers for whatever process macOS holds responsible — under
    /// xcodebuild that is Xcode, not the terminal, and on the Mac this was
    /// written on Xcode was denied while the terminal was granted — so a
    /// test that asserted on it would pass or fail by machine.
    @ObservationIgnored var fullDiskAccessProbe: @Sendable () -> FullDiskAccessStatus = { FullDiskAccess.probe() }
    /// Whether the Mac ran on battery at the last scheduler tick — sampled
    /// every tick whether or not the battery setting is on, so the hold's
    /// words are right the moment the setting is switched on, and written
    /// only when it changes, so the tray's observation does not fire every
    /// minute.
    var isOnBattery = false
    /// Plans whose running backup Pause and Stop ended. Such a run is
    /// recorded as stopped by the pause and leaves its slot unstamped, so
    /// it runs again when the pause ends. Each run's unwind removes its
    /// plan, so a later plain Stop of the same plan stamps as usual.
    @ObservationIgnored var pauseStoppedPlanIDs: Set<UUID> = []
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
    /// Which restore run the progress strip belongs to. Rotated when a run
    /// unwinds so a progress hop still in flight from that run drops instead
    /// of resurrecting the cleared strip. See `restoreProgressReporter()`.
    @ObservationIgnored var restoreRunToken = UUID()
    /// Which backup run each plan's progress strip belongs to — the same
    /// run-identity rule as `restoreRunToken`, for the plan strips: a hop
    /// still in flight when run N unwinds must drop instead of writing into
    /// run N+1's strip. Rotated by `installPlanActivity`. (Maintenance keeps
    /// its own map — `maintenanceRunTokens` — the key spaces merely look
    /// alike.)
    @ObservationIgnored var backupRunTokens: [UUID: UUID] = [:]
    /// The maintenance mirror of `backupRunTokens`, keyed by repository.
    @ObservationIgnored var maintenanceRunTokens: [UUID: UUID] = [:]

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
    /// What `fileHistory` has read of a file in a backup — its node, with
    /// the size and modification time a Files pane's version row shows —
    /// for the session; the index keeps it across launches. A backup ID is
    /// restic's hash of the snapshot, so an answer never goes stale while
    /// its backup lives, and a forgotten backup is never asked about again.
    @ObservationIgnored var fileHistoryAnswers: [FileHistoryKey: SnapshotNode] = [:]
    /// The find a folder's read-ahead (`warmFileHistory`) runs, by each file
    /// it asks about, while it runs: a click on one of them waits for it.
    @ObservationIgnored var fileHistoryReadAheads: [FileHistoryFile: Task<Void, any Error>] = [:]
    /// Where view-state stamps (the seen-problem marks) persist. Injectable
    /// so tests never touch the real defaults, the same way secrets never
    /// touch the login Keychain.
    let viewDefaults: UserDefaults
    let runner = ResticRunner()
    /// The per-repository snapshot indexes and their upkeep. A cache with a
    /// rebuild path: its failures are its own, never the refresh's or the
    /// backup's. See `IndexCoordinator`. In the configuration's folder, under
    /// `index/`, as the run logs are under `Logs/`: for the app the folder it
    /// always used (`ConfigStore.defaultDirectory()`,
    /// `SWIFTRESTIC_CONFIG_DIR` included), and a test's own folder when the
    /// test points the store elsewhere.
    let indexCoordinator: IndexCoordinator
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
    /// Serializes the login-item changes: two quick toggles must apply in
    /// click order, or the daemon ends on whichever XPC finished last
    /// instead of the user's last click.
    @ObservationIgnored let loginItemChanges = TaskChain()
    /// Bumped by every toggle; a daemon read may only write `startsAtLogin`
    /// while its own generation is still the newest, or it would snap the
    /// switch back past a newer click's optimistic value.
    @ObservationIgnored var loginItemGeneration = 0
    /// Repositories whose last refresh already announced a stats failure.
    /// The banner is a transition signal, not a nag: a repository whose stats
    /// keep failing says it once, and says it again only after a success in
    /// between proved the failure was gone.
    @ObservationIgnored var statsFailureNoted: Set<UUID> = []
    /// A local-notification delivery problem (denied permission, a rejected
    /// add) already announced. Same transition-signal rule as the stats
    /// banner: once per failing stretch, so a denial does not nag on every
    /// failed run.
    @ObservationIgnored var notificationsProblemNoted = false
    /// The configuration writes, one at a time in call order — see
    /// `flushSave`.
    @ObservationIgnored private let saves = TaskChain()
    /// Set when bootstrap could not read the configuration from any
    /// generation. Every save from here on is refused: the live file that is
    /// on disk is corrupt in unknown ways, and the rotation behind each save
    /// would shuffle it over the good generations — two saves and every
    /// backup copy is gone. The user's way out is fixing the file externally
    /// and restarting; the banner tells them so.
    @ObservationIgnored var isConfigurationUnreadable = false
    /// Set while `shutdown` is unwinding. A run cancelled this way was not
    /// stopped by the user, and the run record should say so: "Cancelled" sends
    /// someone hunting for a cancel click that never happened.
    var isShuttingDown = false
    /// Silences the debounced save for one assignment — bootstrap writing back
    /// what it just loaded. `isLoaded` is already true during the load, so the
    /// `configuration` didSet would otherwise schedule a save 400 ms after
    /// launch: a rewrite the user never asked for, and one that makes tolerant
    /// decoding's substituted defaults permanent before the banner explaining
    /// them has even been read.
    @ObservationIgnored var suppressConfigurationSave = false

    /// The hostname this Mac's backups carry, which the names under Other
    /// backups leave out (`OtherBackupsGroup.labels`). Tests name their own.
    let localHostname: String

    init(
        store: ConfigStore = ConfigStore(),
        secrets: SecretStore = .keychain,
        defaults: UserDefaults = .standard,
        localHostname: String = ResticService.localHostname
    ) {
        self.store = store
        self.secrets = secrets
        self.localHostname = localHostname
        self.indexCoordinator = IndexCoordinator(directory: store.directory)
        self.viewDefaults = defaults
        self.problemsSeenAt = ProblemDotsStore.load(from: defaults)
        #if DEBUG
        // Live checks run from a build folder, where only the move-to-
        // Applications advice can show. This makes the advice treat the copy
        // as installed so the Start at Login button renders; a click still
        // meets the live location check and registers nothing. Gated on the
        // throwaway-config override, like the password and power seams.
        let environment = ProcessInfo.processInfo.environment
        if environment["SWIFTRESTIC_CONFIG_DIR"] != nil,
           environment["SWIFTRESTIC_LOGIN_ITEM_INSTALLABLE"] == "1"
        {
            self.loginItemInstallable = true
        } else {
            self.loginItemInstallable = LoginItem.isInInstallableLocation
        }
        #else
        self.loginItemInstallable = LoginItem.isInInstallableLocation
        #endif
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

    /// Re-derives one repository's `backupShelves` from its listing, its own
    /// plans and every configured plan (which tells a moved plan's group
    /// under Other backups from an adoptable one); a repository without a
    /// listing has none.
    private func reshelve(_ repositoryID: UUID) {
        backupShelves[repositoryID] = snapshots[repositoryID].map {
            BackupShelves(listing: $0, plans: plans(in: repositoryID), allPlans: configuration.plans)
        }
    }

    // MARK: - Persistence

    /// Coalesces rapid edits (typing in a text field) into one write.
    private func scheduleSave() {
        guard !suppressConfigurationSave else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.flushSave()
        }
    }

    func flushSave() async {
        guard isLoaded else { return }
        guard !isConfigurationUnreadable else { return }
        // Another write is in progress: this one runs after it and writes
        // the newer state. Skipping instead would drop the latest edit for
        // good — nothing else would save it, including the single flush at
        // shutdown. Each write reads the configuration when its turn comes,
        // so the newest state is what lands last.
        await saves.run { [weak self] in
            guard let self else { return }
            let snapshot = self.configuration
            do {
                try await self.store.save(snapshot)
            } catch {
                self.post(Banner(
                    title: "Could not save your configuration",
                    message: error.localizedDescription,
                    isError: true
                ))
            }
        }
    }
}
