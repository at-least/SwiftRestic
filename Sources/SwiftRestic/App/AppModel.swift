import Foundation
import UserNotifications
import Network
import Observation
import SwiftUI

/// Everything that touches persisted state happens here on the main actor;
/// restic itself runs on the `ResticRunner` actor and reports back by hopping
/// home.
@MainActor
@Observable
final class AppModel {
    var configuration = AppConfiguration() {
        didSet {
            // Array `!=` short-circuits on shared storage, so an edit that
            // leaves the history alone costs no element comparison.
            if oldValue.runs != configuration.runs {
                backupRunsBySnapshot = RunRecord.backupRunsBySnapshot(configuration.runs)
            }
            // A plan added, adopted or removed moves backups between shelves,
            // or relabels one: two plans whose folders share a name are
            // labelled by path.
            if oldValue.plans != configuration.plans {
                for id in snapshots.keys { reshelve(id) }
            }
            if oldValue.plans != configuration.plans || oldValue.repositories != configuration.repositories {
                followPlans(from: oldValue)
            }
            scheduleSave()
        }
    }
    /// Derived once per history write rather than by every row that shows a
    /// snapshot. A snapshot whose run was trimmed from the history, or never
    /// recorded here, is simply absent — unknown, never complete.
    private(set) var backupRunsBySnapshot: [String: RunRecord] = [:]

    func backupRun(forSnapshot id: String) -> RunRecord? {
        backupRunsBySnapshot[id]
    }

    func unreadItems(inBackup id: String) -> UnreadItems {
        var items = UnreadItems()
        for (lineKey, path) in backupRun(forSnapshot: id)?.unreadableItemPaths ?? [:] {
            let line = lineKey.path
            items.lines[PathKey(ResticPath.normalized(path))] = line
        }
        return items
    }

    /// `checkRestic` writes it whole.
    var resticState: ResticState = .checking
    var activity: [UUID: PlanActivity] = [:]
    /// Live backup progress per plan, in its own observable storage: a
    /// restic status tick (~1/sec) lands here and invalidates only the views
    /// that read progress — the running strip and nothing else. `activity`
    /// keeps the phase strip, the sidebar's rows and the Status line's
    /// rows, which must not re-render per tick; the pair is installed and
    /// retired together by `installPlanActivity` and the run's unwind.
    var planProgress: [UUID: OperationProgress] = [:]
    var maintenance: [UUID: MaintenanceActivity] = [:]
    /// Plans waiting for their turn, keyed by the repository another
    /// plan's run holds, first in line first (`runBackups`).
    var backupQueue: [UUID: [QueuedBackup]] = [:]
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
    /// listing or plan write: the sidebar's body re-runs on every selection
    /// change, and grouping thousands of snapshots there is too slow.
    private(set) var backupShelves: [UUID: BackupShelves] = [:]
    var repositoryStats: [UUID: RepositoryStats] = [:]
    var loadingSnapshots: Set<UUID> = []
    /// Refreshes that arrived while one was already in flight. Each is run
    /// once the in-flight refresh lands — dropped, the snapshot a just-
    /// finished backup wrote would stay invisible until some unrelated
    /// refresh happened along.
    @ObservationIgnored var pendingSnapshotRefreshes: Set<UUID> = []
    /// Kept apart from the rows themselves: a failed refresh must read as
    /// "unknown", never as an empty list.
    var snapshotListingOutcomes: [UUID: SnapshotListingOutcome] = [:]
    /// A freshness stamp the surfaces show so a number can always be traced
    /// to the moment it was read.
    var snapshotsLoadedAt: [UUID: Date] = [:]
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
    /// older listing (`indexIsComplete`). Observed by the Files views, which
    /// read again the moment it moves, rather than at their next recheck.
    var indexTakenGeneration: [UUID: UInt64] = [:]
    /// Repositories with no password in the Keychain yet. Upkeep is not scheduled
    /// for these: there is nothing to run, and stamping a "last checked" time for
    /// a check that never happened would be a lie on the repository screen.
    var repositoriesMissingPassword: Set<UUID> = []
    /// Repositories whose check or prune found their drive away
    /// (`markDriveAway`): unstamped, the task stays due, and the scheduler
    /// leaves it alone while the drive is still away — then it runs on the
    /// next tick.
    var maintenanceAwaitingDrive: Set<UUID> = []
    /// Network repositories whose check or prune found their server out of
    /// reach (`markServerAway`): unstamped, the task stays due, and the
    /// scheduler leaves it alone until the network changes
    /// (`networkPathChanged`) or a listing reads the repository again.
    var maintenanceAwaitingServer: Set<UUID> = []
    /// Locations whose first listing since launch has not ended. Their due
    /// work waits, because the listing is what says a password is missing, a
    /// drive is away or a share needs reconnecting; other locations don't wait.
    @ObservationIgnored var repositoriesAwaitingLaunchListing: Set<UUID> = []
    /// How long the first tick gives every location's listing, so a launch
    /// with all of them readable starts its due work in that one tick.
    @ObservationIgnored var launchListingGrace: Duration = .seconds(10)
    /// Whether `configuration` holds what bootstrap loaded. Until then no
    /// save runs: an edit made during the load would write the defaults
    /// over the file.
    var isLoaded = false
    /// True while `bootstrap` is still reading the configuration and locating
    /// restic. The views show a loading state instead of the empty states:
    /// on a slow disk the default (empty) configuration otherwise reads as a
    /// fresh install — or as breakage — for the first seconds.
    var isBootstrapping = false
    /// The login item as the daemon last answered: `LoginItem.state` is not
    /// observable on its own.
    var loginItemState: LoginItemState = .off
    var startsAtLogin: Bool { loginItemState == .enabled }
    var loginItemNeedsApproval: Bool { loginItemState == .needsApproval }
    /// An init parameter and never configuration, so nothing on disk can
    /// point the app at another restic. Only tests pass one.
    @ObservationIgnored let resticExecutable: URL
    /// Whether SwiftRestic — and so its restic — may read what Full Disk
    /// Access guards. Probed, not asked: see `refreshFullDiskAccess()`.
    var fullDiskAccess: FullDiskAccessStatus = .unknown
    /// The probe behind `fullDiskAccess`. Injectable because the real one
    /// answers for whatever process macOS holds responsible — under
    /// xcodebuild that is Xcode, not the terminal — so a test asserting on
    /// it would pass or fail by machine.
    @ObservationIgnored var fullDiskAccessProbe: @Sendable () -> FullDiskAccessStatus = { FullDiskAccess.probe() }
    /// Injectable: a test host has no notification center, and permission
    /// cannot be turned off from a test.
    @ObservationIgnored var notificationPoster: @MainActor (UNNotificationRequest) async throws -> Void = AppModel.addToNotificationCenter
    /// The login-item daemon read behind `reconcileLoginItem` and
    /// `refreshLoginItemStatus`. Injectable for the same reason the probe
    /// is: `SMAppService` answers for whatever process macOS holds
    /// responsible, and a test must not register anything with it.
    @ObservationIgnored var loginItemStateReader: @Sendable () -> LoginItemState = { LoginItem.state }
    @ObservationIgnored var loginItemApplier: @Sendable (Bool) throws -> Void = { try LoginItem.setEnabled($0) }
    /// The location gate in `reconcileLoginItem`. Injectable because
    /// Bundle.main in a test is the xctest runner inside Xcode, which the live
    /// check counts as installed when Xcode sits in /Applications.
    @ObservationIgnored var installableLocationProbe: @Sendable () -> Bool = { LoginItem.isInInstallableLocation }
    /// Whether the network is one macOS reports as expensive or
    /// constrained (`startNetworkMonitor`), written only when it changes so
    /// the tray's observation does not fire needlessly.
    var isOnMeteredNetwork = false
    @ObservationIgnored var networkMonitor: NWPathMonitor?
    /// The last network path seen — whether it is up, through which
    /// interfaces — so only a change calls `networkPathChanged`.
    @ObservationIgnored var networkSignature: String?
    @ObservationIgnored var mountObserver: (any NSObjectProtocol)?
    /// How many runs Activity keeps; a standing problem is kept past it.
    @ObservationIgnored var activityHistoryLimit = 300
    /// Transient messages shown at the top of the detail panes, newest first.
    /// A queue rather than a single slot: an unread error must not be erased
    /// by the next message — a failing-repository refresh, a finished restore
    /// and a notification failure can land minutes apart.
    var banners: [Banner] = []

    /// When Activity was last open with a problem it had not shown.
    var activitySeenAt: Date?

    /// Progress of a picker-started restore, of which there is at most one
    /// (drag restores track no progress — their feedback is the drop itself).
    var restoreActivity: OperationProgress?
    var restoreDescription: String = ""
    /// The repository the running restore reads from. Deleting it cancels the
    /// restore; kept beside the task because the task alone cannot be asked
    /// what it is working on.
    var restoreRepositoryID: UUID?
    /// Which run each slot's progress strip belongs to — the one late-hop
    /// guard for the plan strips, the maintenance lines and the restore
    /// strip. A runner's reader thread builds its writer
    /// (`hopWriter(for:write:)`) and captures the token; the token rotates
    /// when a strip is installed and retires when it unwinds, so a hop still
    /// in flight when run N unwinds drops instead of writing into run N+1's
    /// strip, which nothing else would ever clear. Restore alone rotates at
    /// its unwind: its reporter is built before the strip is installed.
    @ObservationIgnored var runTokens: [TaskRegistry.Slot: UUID] = [:]

    let store: ConfigStore
    let secrets: SecretStore
    let shareMounter: ShareMounter
    let serverProbe: ServerProbe
    let volumeProbe: VolumeProbe
    /// Each share's reconnect in flight, by volume name: a second run that
    /// needs it at the same tick awaits the first's answer rather than
    /// mounting it twice.
    @ObservationIgnored var shareReconnects: [String: Task<ShareReconnect, Never>] = [:]
    /// Resolved restic contexts per repository (repo string + credentials),
    /// so a restic call does not re-read the Keychain. Entries
    /// are rebuilt when the repository value changes (`AppModel.context(for:)`
    /// keeps the value it was built from), and dropped on secret edits
    /// (`upsert`), repository removal, and auth-class failures
    /// (`noteAuthFailure`). Holds secrets no longer than the app already
    /// holds them in each child's environment.
    @ObservationIgnored var resolvedContexts:
        [UUID: (repository: Repository, context: RepositoryContext)] = [:]
    /// Bumped by every `forgetContext`: a secret read that began before a
    /// password save may answer the old password, and must not cache it.
    @ObservationIgnored var contextGenerations: [UUID: Int] = [:]
    /// What `fileHistory` has read of a file in a backup — its node, with
    /// the size and modification time a Files pane's version row shows —
    /// for the session; the index keeps it across launches. A backup ID is
    /// restic's hash of the snapshot, so an answer never goes stale while
    /// its backup lives, and a forgotten backup is never asked about again.
    @ObservationIgnored var fileHistoryAnswers: [FileHistoryKey: SnapshotNode] = [:]
    /// The find a folder's read-ahead (`warmFileHistory`) runs, by each file
    /// it asks about, while it runs: another read-ahead then leaves those
    /// files to it.
    @ObservationIgnored var fileHistoryReadAheads: [FileHistoryFile: Task<Void, any Error>] = [:]
    /// Where view-state stamps (the seen-problem marks) persist. Injectable
    /// so tests never touch the real defaults, the same way secrets never
    /// touch the login Keychain.
    let viewDefaults: UserDefaults
    let runner = ResticRunner()
    /// The per-repository snapshot indexes and their upkeep. A cache with a
    /// rebuild path: its failures are its own, never the refresh's or the
    /// backup's. See `IndexCoordinator`. Lives in the configuration's folder
    /// under `index/` (`ConfigStore.defaultDirectory()`,
    /// `SWIFTRESTIC_CONFIG_DIR` included); a test pointing the store
    /// elsewhere gets its own folder.
    let indexCoordinator: IndexCoordinator
    /// Where drag restores and previews copy files out, and the only folder
    /// the launch sweep empties (`stagingDirectory(for:)`).
    let stagingDirectory: URL
    /// Its two injected closures are set at the end of `init`.
    let console = ConsoleModel()
    @ObservationIgnored let tasks = TaskRegistry()
    var schedulerTask: Task<Void, Never>?
    var saveTask: Task<Void, Never>?
    /// Serializes every login-item read and change, so `loginItemState`
    /// always lands in the order the daemon answered.
    @ObservationIgnored let loginItemChanges = TaskChain()
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
    @ObservationIgnored var sleepActivity: (any NSObjectProtocol)?
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
    /// Set while `shutdown` is unwinding, so a run it cancels is recorded as
    /// interrupted by quitting rather than "Cancelled".
    var isShuttingDown = false
    /// Silences the debounced save for one assignment — bootstrap writing back
    /// what it just loaded. The `configuration` didSet would otherwise
    /// schedule a save right after launch: a rewrite the user never asked
    /// for, and one that makes tolerant decoding's substituted defaults
    /// permanent before the banner explaining them has even been read.
    @ObservationIgnored var suppressConfigurationSave = false

    /// The hostname this Mac's backups carry, which the names under Other
    /// backups leave out (`OtherBackupsGroup.labels`). Tests name their own.
    let localHostname: String

    init(
        store: ConfigStore = ConfigStore(),
        secrets: SecretStore = .standard,
        shareMounter: ShareMounter = .netFS,
        serverProbe: ServerProbe = .network,
        volumeProbe: VolumeProbe = .fileSystem,
        defaults: UserDefaults = .standard,
        localHostname: String = ResticService.localHostname,
        resticExecutable: URL = ResticBinary.bundled.url
    ) {
        self.resticExecutable = resticExecutable
        self.store = store
        self.secrets = secrets
        self.shareMounter = shareMounter
        self.serverProbe = serverProbe
        self.volumeProbe = volumeProbe
        self.localHostname = localHostname
        self.indexCoordinator = IndexCoordinator(directory: store.directory)
        self.stagingDirectory = Self.stagingDirectory(for: store.directory)
        self.viewDefaults = defaults
        self.activitySeenAt = ActivitySeenStore.loadActivitySeenAt(from: defaults)
        // A gone owner is the quit unwinding: the pane says so in
        // the words the rest of the app uses for a cancel.
        console.runCommand = { [weak self] repositoryID, arguments in
            await self?.runConsoleCommand(repositoryID: repositoryID, arguments: arguments)
                ?? ResticError.cancelled.localizedDescription
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

    private static let saveDebounce: Duration = .milliseconds(400)

    /// Coalesces rapid edits (typing in a text field) into one write.
    private func scheduleSave() {
        guard !suppressConfigurationSave else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
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
                    title: "Couldn’t save your configuration",
                    message: error.localizedDescription,
                    level: .error
                ))
            }
        }
    }
}

extension AppModel {
    /// Gives a slot's new strip its own run identity, so writers built for
    /// the previous run (`hopWriter`) drop from here on.
    func rotateRunToken(for slot: TaskRegistry.Slot) {
        runTokens[slot] = UUID()
    }

    /// Retires the slot's identity with its strip. A late hop's captured
    /// token then matches nothing.
    func retireRunToken(for slot: TaskRegistry.Slot) {
        runTokens[slot] = nil
    }

    /// The one late-hop guard for progress writes: a runner's reader thread
    /// gets this closure, the write hops to the main actor, and it drops
    /// unless the slot still runs the run that built it. The token, not the
    /// strip's existence, is the guard: after run N unwinds, a hop from
    /// run N must drop even though run N+1 has already installed its own
    /// strip.
    func hopWriter<Value: Sendable>(
        for slot: TaskRegistry.Slot,
        write: @escaping @MainActor (AppModel, Value) -> Void
    ) -> @Sendable (Value) -> Void {
        let token = runTokens[slot]
        return { [weak self] value in
            Task { @MainActor in
                guard let self, self.runTokens[slot] == token else { return }
                write(self, value)
            }
        }
    }
}
