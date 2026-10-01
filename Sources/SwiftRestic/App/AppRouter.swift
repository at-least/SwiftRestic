import Observation
import SwiftUI

/// The app's view state and window-level intents: which pane is selected,
/// which sheet a menu command asked for, where Activity should land, and the
/// main-window action the AppKit tray needs.
///
/// Split out of `AppModel` deliberately: none of this is domain state — it
/// is the navigation surface the views and the menu bar share — and keeping
/// it on the model meant every pane-switch wrote through the same object the
/// domains mutate. It also replaces the stringly `NotificationCenter` seam:
/// menu commands and the tray request typed intents here, and the root view
/// consumes them on the same appear-or-change rule the old
/// `pendingNewRepository` flag used, so an intent asked while the window is
/// closed survives until the window exists.
@MainActor
@Observable
final class AppRouter {
    /// What the user asked for, from a menu command or the tray. Consumed by
    /// the root view: cleared the moment it is seen, then applied only when
    /// no sheet is already up — refused with a beep otherwise, where the old
    /// notification guards dropped it silently — minus the race on whether
    /// a window existed to receive it.
    enum Intent: Equatable {
        case newPlan
        case newRepository
        case showFind
        case showConcepts
        /// Repository ▸ restic Console…: a pane switch, not a sheet, but it
        /// waits out an open sheet like every other menu ask.
        case showConsole
        case runSelectedPlan
        // The Plan and Repository menus. They carry their target rather
        // than read the selection when consumed: the ask may wait for a
        // window, and the selection may move meanwhile.
        case stopPlan(UUID)
        case pauseSchedule(UUID, PauseLength)
        case resumeSchedule(UUID)
        case editPlan(UUID)
        case editRepository(UUID)
        case applyRetention(UUID)
        case confirm(CommandConfirmation)
    }

    /// The pane the sidebar is showing.
    var selection: SidebarItem? 

    /// The pending intent, if any. One slot, not a queue: a second request
    /// before the first was consumed replaces it — two sheets cannot present
    /// at once, so queueing would only delay a stale ask.
    private(set) var pendingIntent: Intent?

    /// The run a detail surface asked Activity to land selected — the plan
    /// page's "Last backup" value, Arq's "View Latest Backup Record…" pattern:
    /// the timestamp is the handle to its own record. Transient, never
    /// persisted; Activity consumes and clears it.
    var activityFocusRunID: RunRecord.ID?

    /// Transient, never persisted: whether Activity shows every run or only
    /// problems — Activity's own picker. A landing that may arrive on a clean
    /// run (the plan page's Last backup) turns it off.
    var activityShowsProblemsOnly = false

    /// A folder the Restore pane should open and select when it next loads
    /// this exact record — Browse Folders' "Show in Restore", which closes
    /// the folder browser the user was reading and must not lose their place.
    struct RestoreFocus: Equatable {
        var repositoryID: UUID
        var snapshotID: String
        var path: String
    }

    /// Transient, never persisted. Keyed on the record so a stale request can
    /// never steer an unrelated load; the pane spends it on its next load.
    private(set) var restoreFocus: RestoreFocus?

    /// The main window's `openWindow` action, parked by the root view the
    /// first time the window appears — the AppKit tray has no view
    /// environment to call it from, and it outlives the window it was
    /// captured in. See TrayStatusItem.openMainWindow.
    @ObservationIgnored var openMainWindowAction: OpenWindowAction?

    /// Records an intent for the root view to consume. Naming it `request`
    /// keeps call sites reading as what they are — asks, not commands.
    func request(_ intent: Intent) {
        pendingIntent = intent
    }

    /// The root view's consumption half: returns and clears whatever was
    /// asked for.
    func takePendingIntent() -> Intent? {
        defer { pendingIntent = nil }
        return pendingIntent
    }

    /// The one route into a backup's contents from outside the sidebar —
    /// the Snapshots tables' Browse, Restore Files…, Show in Restore: select
    /// the record under Restore, where the Change column, search, drag and
    /// whole-backup restore all live, whichever button was pressed. A plain
    /// route clears an older focus request rather than inheriting it.
    func showRestore(repositoryID: UUID, snapshotID: String, focusPath: String? = nil) {
        restoreFocus = focusPath.map {
            RestoreFocus(repositoryID: repositoryID, snapshotID: snapshotID, path: $0)
        }
        selection = .restoreSnapshot(repositoryID, snapshotID)
    }

    /// The Restore pane's consumption half: the focus path, only when it was
    /// asked for this record. Spent either way — a load of another record
    /// means the request is stale.
    func takeRestoreFocus(repositoryID: UUID, snapshotID: String) -> String? {
        defer { restoreFocus = nil }
        guard let restoreFocus,
              restoreFocus.repositoryID == repositoryID,
              restoreFocus.snapshotID == snapshotID
        else { return nil }
        return restoreFocus.path
    }
}

/// The destructive (or slow) actions that ask first, wherever they are
/// asked from — the menu bar, a pane's toolbar, a sidebar menu. One dialog
/// presents them all (`CommandPresentations`), with the model's words
/// (`AppModel.confirmationCopy(for:)`), so no two surfaces can word one
/// action two ways.
enum CommandConfirmation: Hashable, Identifiable {
    case deletePlan(UUID)
    case removeRepository(UUID)
    case check(UUID)
    case prune(UUID)
    case unlock(UUID)
    case rebuildIndex(UUID)

    var id: Self { self }
}
