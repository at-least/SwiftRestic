import Foundation

/// Progress is not here: it lives in `AppModel.planProgress`, its own
/// observable storage, so a once-a-second status tick invalidates only the
/// views that show the numbers — not every view that reads which phase a
/// plan is in.
struct PlanActivity: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case starting
        case backingUp
        case applyingRetention
        case notifying
        case cancelling

        /// restic's copy has ended: its numbers no longer move.
        var isPastCopying: Bool {
            switch self {
            case .applyingRetention, .notifying: true
            case .starting, .backingUp, .cancelling: false
            }
        }

        var displayName: String {
            switch self {
            case .starting: "Starting…"
            case .backingUp: "Backing up…"
            case .applyingRetention: "Removing old backups…"
            case .notifying: "Sending notifications…"
            case .cancelling: "Stopping…"
            }
        }
    }

    /// Kept on the run, not read from the plan: Remove Plan takes the plan
    /// at once, while its cancelled restic child still holds the lock.
    let repositoryID: UUID
    let planName: String
    var phase: Phase = .starting
    var startedAt: Date = .now
    /// A backup's forget, which takes the exclusive lock. Set by every
    /// engine phase write and ended by `endRetentionStep`, not by Stop's
    /// `.cancelling`: the child still holds the lock while it dies.
    var isInRetentionStep = false
    /// A Back Up Now the user asked for, not the scheduler's or a mount's
    /// catch-up: a skip answers it with a banner.
    var askedByUser = false
}

struct QueuedBackup: Sendable, Equatable {
    var planID: UUID
    var askedByUser: Bool
}

struct MaintenanceActivity: Sendable, Equatable {
    var task: MaintenanceTask
    /// False for the scheduler's runs: a skip nobody asked for posts nothing.
    var askedByUser = true
    var startedAt: Date = .now
}

struct Banner: Identifiable, Equatable {
    /// Only an error and a warning carry a glyph, the status palette's own
    /// (`StatusPalette`), so a colour means one thing app-wide.
    enum Level: Equatable {
        /// News: a success, a skipped run, an ask that waits.
        case notice
        /// Something did not work that leaves the backups unharmed.
        case warning
        case error
    }

    struct Link: Equatable {
        var title: String
        var url: URL
    }

    var id = UUID()
    var title: String
    var message: String
    var level: Level
    /// When set, the banner offers a Show-in-Finder button, which selects
    /// them all — a restore that ends with "here is the path" reads finished
    /// only half-way.
    var revealPaths: [String] = []
    var link: Link?

    init(
        title: String,
        message: String,
        level: Level,
        revealPaths: [String] = [],
        link: Link? = nil
    ) {
        self.title = title
        self.message = message
        self.level = level
        self.revealPaths = revealPaths
        self.link = link
    }

    var isError: Bool { level == .error }

    /// Errors and warnings stay until dismissed: something did not work,
    /// and it must not expire unread.
    var staysUntilDismissed: Bool { level == .error || level == .warning }
}

/// Lives beside the model because menu-bar commands must read it: a Plan
/// menu "Back Up Now" that stays enabled over a non-plan selection is a menu
/// that lies.
enum SidebarItem: Hashable {
    case plan(UUID)
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
    /// Search All Backups: a page with no row — the toolbar's search field
    /// is its way in, and a row would be a second one — reached by Edit ▸ Find
    /// (⌘F) off a page other than a plan's, a repository's page's search field,
    /// and a plan's search's All Backups. Not a sheet: its restores would
    /// stack a second sheet on it.
    case findFiles
    case activity
}

extension SidebarItem {
    /// The views the page's toolbar switches between: a plan's Overview |
    /// Backups, and none for every other page. A group under Other backups
    /// is one view, its backups.
    var pageTabs: [PageTab] {
        switch self {
        case .plan: PageTab.allCases
        case .orphanPlan, .lineage, .repository, .findFiles, .activity: []
        }
    }

    static func otherGroup(repositoryID: UUID, id: OtherBackupsGroup.ID) -> SidebarItem {
        switch id {
        case let .plan(planID): .orphanPlan(repositoryID: repositoryID, planID: planID)
        case let .lineage(key): .lineage(repositoryID: repositoryID, key: key)
        }
    }
}

/// One item of a chain's history on a Backups tab: a path in it — a
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

/// Not the in-flight state — `loadingSnapshots` owns that. A refresh that
/// starts while a repository is in `failed` keeps the failure visible until
/// it settles, so a background refresh cannot make the error row flicker
/// to a spinner and back.
enum SnapshotListingOutcome: Equatable {
    /// Never loaded: the app is still bootstrapping, or the refresh has not
    /// been attempted for this repository.
    case idle
    case loaded
    /// The last refresh could not read the repository. The message is what
    /// the surfaces show instead of a snapshot count, and stale rows (when a
    /// previous listing succeeded) stay visible next to it. `fix` is the one
    /// action that helps; without one, trying again is all there is.
    case failed(String, fix: RunFix? = nil)
    /// restic exit 12: the saved password does not open the location. Enter
    /// Password… asks for it (`PasswordPromptSheet`).
    case passwordRefused(repositoryName: String)
    /// A disk location whose volume is not mounted: a normal state, not a
    /// failed read, said without the warning glyph and without "Can’t read
    /// backups". Locate is for a disk renamed: it never mounts under the
    /// saved name.
    case notConnected(volume: String)

    /// The words of a read that failed, a refused password's among them.
    var failureMessage: String? {
        switch self {
        case let .failed(message, _): message
        case let .passwordRefused(name): Self.passwordRefusedText(repositoryName: name)
        case .idle, .loaded, .notConnected: nil
        }
    }

    /// The one action that helps a failed read; nil where trying again is
    /// all there is.
    func failureFix(repositoryID: UUID) -> RunFix? {
        switch self {
        case let .failed(_, fix): fix
        case .passwordRefused: .enterPassword(repositoryID)
        case .idle, .loaded, .notConnected: nil
        }
    }

    static func passwordRefusedText(repositoryName: String) -> String {
        ResticError.wrongPassword(location: repositoryName)
    }

    static func connectText(volume: String) -> String {
        "Connect “\(volume)” to see its backups."
    }
}
