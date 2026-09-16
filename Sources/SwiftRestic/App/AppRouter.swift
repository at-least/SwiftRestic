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
    /// no sheet is already up — the same no-op the old notification guards
    /// produced, minus the race on whether a window existed to receive it.
    enum Intent: Equatable {
        case newPlan
        case newRepository
        case showFind
        case showConcepts
        case runSelectedPlan
    }

    /// The pane the sidebar is showing.
    var selection: SidebarItem? 

    /// The pending intent, if any. One slot, not a queue: a second request
    /// before the first was consumed replaces it — two sheets cannot present
    /// at once, so queueing would only delay a stale ask.
    private(set) var pendingIntent: Intent?

    /// The run a detail surface asked Activity to land selected — the plan
    /// page's "Last backup" tile, Arq's "View Latest Backup Record…" pattern:
    /// the timestamp is the handle to its own record. Transient, never
    /// persisted; Activity consumes and clears it.
    var activityFocusRunID: RunRecord.ID?

    /// Transient, never persisted: whether Activity shows every run or only
    /// problems. Overview's problem rows and failures tile turn it on when
    /// they send the user over.
    var activityShowsProblemsOnly = false

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
}
