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
            // A plan change moves backups between shelves, or relabels one
            // (two plans whose folders share a name are labelled by path).
            if oldValue.plans != configuration.plans {
                for id in snapshots.keys { reshelve(id) }
            }
            if oldValue.plans != configuration.plans || oldValue.repositories != configuration.repositories {
                followPlans(from: oldValue)
            }
            scheduleSave()
        }
    }
    /// Derived once per history write, not per row. A snapshot whose run
    /// left the history, or was never recorded here, is absent: unknown,
    /// never complete.
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

    var resticState: ResticState = .checking
    var activity: [UUID: PlanActivity] = [:]
    /// Apart from `activity` so a restic status tick (~1/sec) invalidates
    /// only the running strip, not the sidebar and Status rows that read
    /// `activity`. Installed and retired with it (`installPlanActivity`,
    /// `unwindPlanRun`).
    var planProgress: [UUID: OperationProgress] = [:]
    var maintenance: [UUID: MaintenanceActivity] = [:]
    /// Keyed by the repository another plan's run holds; first in line first.
    var backupQueue: [UUID: [QueuedBackup]] = [:]
    var snapshots: [UUID: [Snapshot]] = [:] {
        didSet {
            for id in Set(oldValue.keys).union(snapshots.keys) where oldValue[id] != snapshots[id] {
                reshelve(id)
            }
        }
    }
    /// Derived once per listing or plan write: the sidebar's body re-runs on
    /// every selection change, and grouping thousands of snapshots there is
    /// too slow.
    private(set) var backupShelves: [UUID: BackupShelves] = [:]
    var repositoryStats: [UUID: RepositoryStats] = [:]
    var loadingSnapshots: Set<UUID> = []
    /// Refreshes asked for while one was in flight, run once it lands.
    /// Dropping them would hide a just-finished backup's snapshot until some
    /// unrelated refresh.
    @ObservationIgnored var pendingSnapshotRefreshes: Set<UUID> = []
    /// Kept apart from the rows themselves: a failed refresh must read as
    /// "unknown", never as an empty list.
    var snapshotListingOutcomes: [UUID: SnapshotListingOutcome] = [:]
    var snapshotsLoadedAt: [UUID: Date] = [:]
    /// One counter for every repository; the index compares generations
    /// only within one repository.
    @ObservationIgnored var listingGeneration: UInt64 = 0
    /// So an index rebuild re-sends the held listing under its own number.
    @ObservationIgnored var snapshotsGeneration: [UUID: UInt64] = [:]
    /// Set as the index's reconcile returns, whatever it decided. Until it
    /// equals `snapshotsGeneration`, the index answers for an older listing
    /// (`indexIsComplete`). Observed, so the file views read again the
    /// moment it moves rather than at their next recheck.
    var indexTakenGeneration: [UUID: UInt64] = [:]
    /// No upkeep is scheduled for these: a "last checked" stamp for a check
    /// that never ran would be false on the repository page.
    var repositoriesMissingPassword: Set<UUID> = []
    /// Check or prune found the drive away (`markDriveAway`): the task stays
    /// due, unstamped, and runs on the first tick the drive is back.
    var maintenanceAwaitingDrive: Set<UUID> = []
    /// Check or prune found the server out of reach (`markServerAway`): the
    /// task stays due, unstamped, until the network changes
    /// (`networkPathChanged`) or a listing reads the repository again.
    var maintenanceAwaitingServer: Set<UUID> = []
    /// Their due work waits for the first listing: it is what says a
    /// password is missing, a drive is away or a share needs reconnecting.
    @ObservationIgnored var repositoriesAwaitingLaunchListing: Set<UUID> = []
    @ObservationIgnored var launchListingGrace: Duration = .seconds(10)
    /// No save runs before this: it would write the defaults over the file.
    var isLoaded = false
    /// Views show a loading state meanwhile: on a slow disk the empty
    /// default configuration otherwise reads as a fresh install, or as
    /// breakage, for the first seconds.
    var isBootstrapping = false
    /// The login item as the daemon last answered: `LoginItem.state` is not
    /// observable on its own.
    var loginItemState: LoginItemState = .off
    var startsAtLogin: Bool { loginItemState == .enabled }
    var loginItemNeedsApproval: Bool { loginItemState == .needsApproval }
    /// An init parameter and never configuration, so nothing on disk can
    /// point the app at another restic. Only tests pass one.
    @ObservationIgnored let resticExecutable: URL
    /// Probed (`refreshFullDiskAccess()`); macOS offers no query.
    var fullDiskAccess: FullDiskAccessStatus = .unknown
    /// Injectable: the real probe answers for whatever process macOS holds
    /// responsible (under xcodebuild, Xcode), so a test on it would pass or
    /// fail by machine.
    @ObservationIgnored var fullDiskAccessProbe: @Sendable () -> FullDiskAccessStatus = { FullDiskAccess.probe() }
    /// Injectable: a test host has no notification center, and permission
    /// cannot be turned off from a test.
    @ObservationIgnored var notificationPoster: @MainActor (UNNotificationRequest) async throws -> Void = AppModel.addToNotificationCenter
    /// Injectable: `SMAppService` answers for whatever process macOS holds
    /// responsible, and a test must not register anything with it.
    @ObservationIgnored var loginItemStateReader: @Sendable () -> LoginItemState = { LoginItem.state }
    @ObservationIgnored var loginItemApplier: @Sendable (Bool) throws -> Void = { try LoginItem.setEnabled($0) }
    /// Injectable: in a test Bundle.main is the xctest runner inside Xcode,
    /// which the live check counts as installed when Xcode is in
    /// /Applications.
    @ObservationIgnored var installableLocationProbe: @Sendable () -> Bool = { LoginItem.isInInstallableLocation }
    /// Expensive or constrained, as macOS reports it. Write only on change:
    /// the tray observes it.
    var isOnMeteredNetwork = false
    @ObservationIgnored var networkMonitor: NWPathMonitor?
    /// So only a change calls `networkPathChanged`.
    @ObservationIgnored var networkSignature: String?
    @ObservationIgnored var mountObserver: (any NSObjectProtocol)?
    /// A standing problem is kept past it.
    @ObservationIgnored var activityHistoryLimit = 300
    /// Newest first. A queue, not a single slot: an unread error must not be
    /// erased by the next message.
    var banners: [Banner] = []

    /// When Activity was last open with a problem it had not shown.
    var activitySeenAt: Date?

    /// At most one restore runs. Drag restores track no progress: their
    /// feedback is the drop itself.
    var restoreActivity: OperationProgress?
    var restoreDescription: String = ""
    /// Deleting this repository cancels the restore; a Task cannot be asked
    /// what it is working on.
    var restoreRepositoryID: UUID?
    /// The late-hop guard for every progress strip (`hopWriter`). Rotates
    /// when a strip is installed and retires when it unwinds. Restore alone
    /// rotates at its unwind: its reporter is built before its strip.
    @ObservationIgnored var runTokens: [TaskRegistry.Slot: UUID] = [:]

    let store: ConfigStore
    let secrets: SecretStore
    let shareMounter: ShareMounter
    let serverProbe: ServerProbe
    let volumeProbe: VolumeProbe
    /// By volume name: a second run needing the share awaits the first's
    /// reconnect rather than mounting it twice.
    @ObservationIgnored var shareReconnects: [String: Task<ShareReconnect, Never>] = [:]
    /// So a restic call does not re-read the Keychain. Rebuilt when the
    /// repository value changes, dropped on secret edits, repository removal
    /// and auth failures (`noteAuthFailure`).
    @ObservationIgnored var resolvedContexts:
        [UUID: (repository: Repository, context: RepositoryContext)] = [:]
    /// Bumped by every `forgetContext`: a secret read that began before a
    /// password save may answer the old password, and must not cache it.
    @ObservationIgnored var contextGenerations: [UUID: Int] = [:]
    /// For the session; the index keeps it across launches. A backup ID is
    /// restic's hash of the snapshot, so an answer never goes stale.
    @ObservationIgnored var fileHistoryAnswers: [FileHistoryKey: SnapshotNode] = [:]
    /// Each file a running read-ahead (`warmFileHistory`) asks about, so
    /// another read-ahead leaves it alone.
    @ObservationIgnored var fileHistoryReadAheads: [FileHistoryFile: Task<Void, any Error>] = [:]
    /// The seen-problem marks. Injectable so tests never touch the real
    /// defaults.
    let viewDefaults: UserDefaults
    let runner = ResticRunner()
    /// A cache with a rebuild path: its failures are its own, never the
    /// refresh's or the backup's. Lives under the configuration folder, so a
    /// test's store gets its own.
    let indexCoordinator: IndexCoordinator
    /// Drag restores and previews copy files here; the only folder the
    /// launch sweep empties.
    let stagingDirectory: URL
    let console = ConsoleModel()
    @ObservationIgnored let tasks = TaskRegistry()
    var schedulerTask: Task<Void, Never>?
    var saveTask: Task<Void, Never>?
    /// So `loginItemState` lands in the order the daemon answered.
    @ObservationIgnored let loginItemChanges = TaskChain()
    /// The stats-failure banner shows once per failing stretch, not on every
    /// refresh.
    @ObservationIgnored var statsFailureNoted: Set<UUID> = []
    /// Once per failing stretch, as `statsFailureNoted`.
    @ObservationIgnored var notificationsProblemNoted = false
    @ObservationIgnored var sleepActivity: (any NSObjectProtocol)?
    @ObservationIgnored private let saves = TaskChain()
    /// No generation of the configuration could be read. Every save is
    /// refused: each save's rotation would push the corrupt live file over
    /// the good generations, and two saves would lose every backup copy.
    @ObservationIgnored var isConfigurationUnreadable = false
    /// So a run `shutdown` cancels is recorded as interrupted by quitting,
    /// not "Cancelled".
    var isShuttingDown = false
    /// For bootstrap's write-back of what it loaded: a save then would make
    /// tolerant decoding's substituted defaults permanent before the user
    /// read the banner explaining them.
    @ObservationIgnored var suppressConfigurationSave = false

    /// Labels under Other backups leave this host out
    /// (`OtherBackupsGroup.labels`).
    let localHostname: String

    /// How tests steer the stub restic; config.json does not carry it.
    let repositoryEnvironment: [UUID: [String: String]]

    init(
        store: ConfigStore = ConfigStore(),
        secrets: SecretStore = .standard,
        shareMounter: ShareMounter = .netFS,
        serverProbe: ServerProbe = .network,
        volumeProbe: VolumeProbe = .fileSystem,
        defaults: UserDefaults = .standard,
        localHostname: String = ResticService.localHostname,
        resticExecutable: URL = ResticBinary.bundled.url,
        repositoryEnvironment: [UUID: [String: String]] = [:]
    ) {
        self.resticExecutable = resticExecutable
        self.repositoryEnvironment = repositoryEnvironment
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
        // A gone owner is the quit unwinding.
        console.runCommand = { [weak self] repositoryID, arguments in
            await self?.runConsoleCommand(repositoryID: repositoryID, arguments: arguments)
                ?? ResticError.cancelled.localizedDescription
        }
    }

    /// Every configured plan goes in: it tells a moved plan's group under
    /// Other backups from an adoptable one.
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
        // Queued behind a write in progress, not skipped: skipping would
        // drop the latest edit for good, shutdown's flush included. Each
        // write reads the configuration when its turn comes.
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
    func rotateRunToken(for slot: TaskRegistry.Slot) {
        runTokens[slot] = UUID()
    }

    func retireRunToken(for slot: TaskRegistry.Slot) {
        runTokens[slot] = nil
    }

    /// The write drops unless the slot still runs the run that built it.
    /// The token, not the strip's existence, is the guard: a hop from run N
    /// must drop even after run N+1 installed its own strip.
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
