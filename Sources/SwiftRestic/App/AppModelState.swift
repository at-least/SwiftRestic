import Foundation

/// Value types making up `AppModel`'s observable runtime state.

/// Live state of one plan that is currently running.
///
/// Progress is not here: it lives in `AppModel.planProgress`, its own
/// observable storage, so a once-a-second status tick invalidates only the
/// views that show the numbers — not every view that reads which phase a
/// plan is in.
struct PlanActivity: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case starting
        case backingUp
        case applyingRetention
        case runningHooks
        case notifying
        case cancelling

        var displayName: String {
            switch self {
            case .starting: "Starting…"
            case .backingUp: "Backing up"
            case .applyingRetention: "Applying retention"
            case .runningHooks: "Running hooks"
            case .notifying: "Sending notifications"
            case .cancelling: "Cancelling…"
            }
        }
    }

    var phase: Phase = .starting
    var startedAt: Date = .now
    /// False for Apply Retention Now…'s forget, which runs in the plan's
    /// slot but is no backup: however it ends — a quit's cancel included —
    /// it stamps no slot as run.
    var isBackup = true
    /// A Back Up Now the user asked for, not the scheduler's or a mount's
    /// catch-up: a skip answers it with a banner.
    var askedByUser = false
}

/// A plan waiting for its turn on a repository another plan's run holds
/// (`AppModel.runBackups`).
struct QueuedBackup: Sendable, Equatable {
    var planID: UUID
    /// Handed to the run when it starts, as `PlanActivity.askedByUser`.
    var askedByUser: Bool
}

/// Live state of one repository's check or prune.
struct MaintenanceActivity: Sendable, Equatable {
    var task: MaintenanceTask
    /// False for the scheduler's runs: a skip nobody asked for posts nothing.
    var askedByUser = true
    var startedAt: Date = .now
    /// The last line the command printed. `prune` narrates in plain text, so
    /// this distinguishes "working" from "hung"; `check --json` stays silent
    /// until it finishes, so there this stays `nil` and elapsed time is the
    /// only live signal.
    var lastOutput: String?
}

/// A transient message shown above the detail pane.
struct Banner: Identifiable, Equatable {
    /// What the banner is, and so its glyph and colour — the status
    /// palette's own (`StatusPalette`), so a colour means one thing app-wide:
    /// a failure's red octagon, a warning's orange triangle (a run that
    /// completed with warnings wears it in Activity and the sidebar), a
    /// success's green check, news in the secondary colour.
    enum Level: Equatable {
        case success
        /// News, neither good nor bad — a skipped run, an ask that waits.
        case notice
        /// Something did not work that leaves the backups unharmed.
        case warning
        case error
    }

    /// A button that opens a place outside the app — the notification
    /// permission's pane in System Settings.
    struct Link: Equatable {
        var title: String
        var url: URL
    }

    var id = UUID()
    var title: String
    var message: String
    var level: Level
    /// When set, the banner offers a Reveal-in-Finder button, which selects
    /// them all — a restore that ends with "here is the path" reads finished
    /// only half-way.
    var revealPaths: [String] = []
    /// A notice's glyph, in the secondary colour — a skipped run's own —
    /// instead of the generic one.
    var symbolName: String?
    var link: Link?

    init(
        title: String,
        message: String,
        level: Level,
        revealPaths: [String] = [],
        symbolName: String? = nil,
        link: Link? = nil
    ) {
        self.title = title
        self.message = message
        self.level = level
        self.revealPaths = revealPaths
        self.symbolName = symbolName
        self.link = link
    }

    /// The two-way form most posts use: an error, or a success — a notice
    /// when it names its own glyph.
    init(title: String, message: String, isError: Bool, revealPaths: [String] = [], symbolName: String? = nil) {
        self.init(
            title: title,
            message: message,
            level: isError ? .error : symbolName == nil ? .success : .notice,
            revealPaths: revealPaths,
            symbolName: symbolName
        )
    }

    var isError: Bool { level == .error }

    /// Errors and warnings stay until dismissed: something did not work,
    /// and it must not expire unread.
    var staysUntilDismissed: Bool { level == .error || level == .warning }
}

/// Which pane the detail column is showing — the sidebar's selection, or the
/// console, which has no row and arrives from Repository ▸ restic Console….
/// Lives beside the model because menu-bar commands must read it: a Plan
/// menu "Back Up Now" that stays enabled over a non-plan selection is a menu
/// that lies.
enum SidebarItem: Hashable {
    case plan(UUID)
    /// The repository's page, which is also its overview.
    case repository(UUID)
    /// The page of one plan-UUID group under a repository's Other backups —
    /// a plan's history in this repository that none of its plans owns: a
    /// plan deleted here or still running on another Mac, or a plan that now
    /// backs up to another repository. The plan ID is the group's own rule
    /// (`OtherBackupsGroup`), so the page survives regrouping and the
    /// selection revalidates to the repository's page once the group is gone.
    case orphanPlan(repositoryID: UUID, planID: UUID)
    /// The page of one untagged lineage under a repository's Other backups
    /// — the backups of one Mac's folders that no plan made. Its host and
    /// folders are its identity, so the page survives regrouping and the
    /// selection revalidates to the repository's page once it is gone.
    case lineage(repositoryID: UUID, key: SnapshotLineage.Key)
    case console
    /// Find Files: a page with no row, as the console has none — reached
    /// from Repository ▸ Find Files in Snapshots… (⇧⌘F) off a page with a
    /// Files tab, a repository page's search field, and Search All
    /// Backups…. Until 2026-10-18 a sheet, whose restores stacked a second
    /// sheet on it.
    case findFiles
    case activity
}

extension SidebarItem {
    /// Whether the page has the toolbar's Overview | Backups | Files: a
    /// plan's, and a group's under Other backups.
    var hasPageTabs: Bool {
        switch self {
        case .plan, .orphanPlan, .lineage: true
        case .repository, .console, .findFiles, .activity: false
        }
    }

    /// The page of a group under `repositoryID`'s Other backups, either kind.
    static func otherGroup(repositoryID: UUID, id: OtherBackupsGroup.ID) -> SidebarItem {
        switch id {
        case let .plan(planID): .orphanPlan(repositoryID: repositoryID, planID: planID)
        case let .lineage(key): .lineage(repositoryID: repositoryID, key: key)
        }
    }
}

/// One item of a Files tab's tree: a path in one chain's history — a
/// plan's tag, or an untagged lineage's key (`SnapshotIndex.chainKey`) — in
/// one repository, as a folder or a file. Identity is byte-exact
/// (`PathKey`), as every index read's is: two names that differ only in
/// Unicode normalization are two rows. The kind is part of it, so a path
/// that changed kind is another row.
struct FileNode: Hashable, Sendable {
    let repositoryID: UUID
    let chainKey: String
    let pathKey: PathKey
    let isDirectory: Bool

    init(repositoryID: UUID, chainKey: String, path: String, isDirectory: Bool) {
        self.repositoryID = repositoryID
        self.chainKey = chainKey
        pathKey = PathKey(path)
        self.isDirectory = isDirectory
    }

    /// The level a chain's tree hangs from: the folders its backups hold at
    /// their top, a plan's path (several where an earlier build's plan held
    /// a list). Not a path, so never a row or a selection.
    static func roots(repositoryID: UUID, chainKey: String) -> FileNode {
        FileNode(repositoryID: repositoryID, chainKey: chainKey, path: "", isDirectory: true)
    }

    var path: String { pathKey.path }
    var name: String { ResticPath.basename(of: path) }
    var isRoots: Bool { path.isEmpty }
}

/// The last settled outcome of a repository's snapshot listing.
///
/// Not the in-flight state — `loadingSnapshots` owns that. A refresh that
/// starts while a repository is in `failed` keeps the failure visible until
/// it settles, so a background refresh cycle cannot make the error row
/// flicker to a spinner and back every five minutes.
enum SnapshotListingOutcome: Equatable {
    /// Never loaded: the app is still bootstrapping, or the refresh has not
    /// been attempted for this repository.
    case idle
    case loaded
    /// The last refresh could not read the repository. The message is what
    /// the surfaces show instead of a snapshot count, and stale rows (when a
    /// previous listing succeeded) stay visible next to it.
    case failed(String)
}
