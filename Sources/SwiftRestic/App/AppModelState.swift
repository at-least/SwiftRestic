import Foundation

/// Value types making up `AppModel`'s observable runtime state.

/// Live state of one plan that is currently running.
///
/// Progress is deliberately not here: it lives in `AppModel.planProgress`,
/// its own observable storage, so a once-a-second status tick invalidates
/// only the views that show the numbers — not every view that reads which
/// phase a plan is in.
struct PlanActivity: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case starting
        case backingUp
        case applyingRetention
        case runningHooks
        case notifying
        case checking
        case cancelling

        var displayName: String {
            switch self {
            case .starting: "Starting…"
            case .backingUp: "Backing up"
            case .applyingRetention: "Applying retention"
            case .runningHooks: "Running hooks"
            case .notifying: "Sending notifications"
            case .checking: "Checking repository"
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
}

/// Live state of one repository's check or prune.
struct MaintenanceActivity: Sendable, Equatable {
    var task: MaintenanceTask
    var startedAt: Date = .now
    /// The last line the command printed. `prune` narrates in plain text, so
    /// this distinguishes "working" from "hung"; `check --json` stays silent
    /// until it finishes, so there this stays `nil` and elapsed time is the
    /// only live signal.
    var lastOutput: String?
}

/// A transient message shown at the top of the detail pane.
struct Banner: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var message: String
    var isError: Bool
    /// When set, the banner offers a Reveal-in-Finder button — a restore that
    /// ends with "here is the path" reads finished only half-way.
    var revealPath: String?
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
    /// A backup record picked under a repository's Restore node — the pane
    /// browses that record's file tree directly, Arq-style.
    case restoreSnapshot(UUID, String)
    case console
    case activity
}

/// The last settled outcome of a repository's snapshot listing.
///
/// Deliberately not the in-flight state — `loadingSnapshots` owns that. A
/// refresh that starts while a repository is in `failed` keeps the failure
/// visible until it settles, so a background refresh cycle cannot make the
/// error row flicker to a spinner and back every five minutes.
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
