import AppKit
import SwiftUI

/// The root split view: composes the sidebar and detail child views and
/// carries the app-level chrome — sheets and confirmations, notification
/// observers, toolbar, and the selection revalidation that keeps the landing
/// pane truthful as the model changes.
///
/// The four per-concern chains below (`presented`, `observed`, `chrome`,
/// `revalidate`) are each one modifier stack over the split view. They stay
/// apart because one expression carrying the whole chain crossed the
/// compiler's type-check time limit (deterministic on clean builds, and only
/// after unrelated one-line edits elsewhere — the chain sat right at the
/// limit). The sidebar and detail column live in `SidebarView` and
/// `RootDetailView`, each type-checking on its own.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @State private var editingPlan: BackupPlan?
    @State private var editingRepository: Repository?
    @State private var isShowingFind = false
    /// What the Restore pane's "Search All Backups…" hands Find Files. Only
    /// that button sets it; the sheet's dismissal clears it, so ⇧⌘F and
    /// every other way in still open an empty search.
    @State private var findPrefill: FindFilesView.Prefill?
    @State private var isShowingConcepts = false
    /// The one confirmation up, from whichever surface asked — the menu
    /// bar, a pane's toolbar, a sidebar menu. See `CommandPresentations`.
    @State private var pendingConfirmation: CommandConfirmation?
    /// Apply Retention Now…'s sheet, for the plan it previews.
    @State private var retentionTarget: RetentionTarget?
    /// Which Restore-section repositories are expanded in the sidebar — the
    /// backup records underneath are the restore pane's entry points.
    @State private var expandedRestoreRepos: Set<UUID> = []
    #if DEBUG
    @State private var didApplyCaptureOverride = false
    #endif
    /// Debug-capture state owned here, consumed by the detail column's
    /// DEBUG-only capture path — see `RootDetailView.pendingCaptureRestore`.
    @State private var pendingCaptureRestore = false

    var body: some View {
        let split = NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        return revalidate(over: chrome(over: observed(over: presented(over: split))))
    }

    private var sidebar: some View {
        SidebarView(
            expandedRestoreRepos: $expandedRestoreRepos,
            onEditPlan: { editingPlan = $0 },
            onNewPlan: { editingPlan = BackupPlan() },
            onEditRepository: { editingRepository = $0 },
            onNewRepository: { editingRepository = Repository() },
            onDeletePlan: { pendingConfirmation = .deletePlan($0.id) },
            onRemoveRepository: { pendingConfirmation = .removeRepository($0.id) }
        )
    }

    private var detail: some View {
        RootDetailView(
            expandedRestoreRepos: $expandedRestoreRepos,
            pendingCaptureRestore: $pendingCaptureRestore,
            onEditPlan: { editingPlan = $0 },
            onEditRepository: { editingRepository = $0 },
            onAddRepository: { editingRepository = Repository() },
            onAddPlan: { editingPlan = BackupPlan() },
            onRevalidateSelection: revalidateSelection,
            onSearchAllBackups: { repositoryID, query in
                findPrefill = FindFilesView.Prefill(repositoryID: repositoryID, pattern: query)
                isShowingFind = true
            }
        )
    }

    /// The sheets and confirmation dialogs that ride on the root split view.
    /// Split out of `body`: one expression carrying the whole chain crossed
    /// the compiler's type-check time limit (deterministic on clean builds,
    /// and only after unrelated one-line edits elsewhere — the chain sat
    /// right at the limit).
    private func presented<V: View>(over content: V) -> some View {
        // Read here, not inside the sheet's closure: read only there, the
        // prefill set together with `isShowingFind` never reached the sheet
        // — Find Files opened with an empty pattern (seen live).
        let prefill = findPrefill
        return content
        .sheet(item: $editingPlan) { plan in
            PlanEditorSheet(plan: plan)
                .environment(model)
        }
        .sheet(item: $editingRepository) { repository in
            RepositoryEditorSheet(repository: repository)
                .environment(model)
        }
        .sheet(isPresented: $isShowingFind, onDismiss: { findPrefill = nil }) {
            FindFilesView(prefill: prefill).environment(model)
        }
        .sheet(isPresented: $isShowingConcepts) {
            ConceptsView()
        }
        // The destructive confirmations and the retention sheet, in a
        // modifier of their own: this chain sits at the type-check limit.
        .modifier(CommandPresentations(
            pendingConfirmation: $pendingConfirmation,
            retentionTarget: $retentionTarget
        ))
    }

    /// The intents from the menu bar and the tray. The menu commands and the
    /// tray have no direct way to reach this view, so they ask the router;
    /// this is the consumption half, on the same appear-or-change rule that
    /// keeps an ask alive while the window is closed. Kept apart from
    /// `presented` for the same reason that function exists: the full chain
    /// in one expression does not type-check.
    private func observed<V: View>(over content: V) -> some View {
        content
        .onChange(of: router.pendingIntent) {
            consumeIntent()
        }
    }

    /// The toolbar's look and the banner announcements. No app-wide toolbar
    /// buttons: each pane carries only its own verbs, and Find Files and the
    /// console live in the Repository menu (⇧⌘F, restic Console…).
    private func chrome<V: View>(over content: V) -> some View {
        content
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onChange(of: model.banners) { announceBanner(from: $0, to: $1) }
    }

    /// Selection revalidation: the reactions that keep the landing pane and
    /// the sidebar's highlight truthful as the model changes.
    private func revalidate<V: View>(over content: V) -> some View {
        content
        .onAppear {
            // Parked for the AppKit tray, which cannot reach a view
            // environment — see AppRouter.openMainWindowAction.
            if router.openMainWindowAction == nil {
                router.openMainWindowAction = openWindow
            }
            consumeIntent()
            selectSomething()
            #if DEBUG
            applyCapturePaneOverride()
            #endif
        }
        .onChange(of: model.configuration.plans.count) {
            revalidateSelection()
            #if DEBUG
            applyCapturePaneOverride()
            #endif
        }
        .onChange(of: model.configuration.repositories.count) {
            revalidateSelection()
        }
        // The load finishing is what selects the landing pane: onAppear runs
        // before `bootstrap` has read anything, so without this a configured
        // app sat on the Welcome screen until the user clicked somewhere.
        .onChange(of: model.isBootstrapping) {
            guard !model.isBootstrapping else { return }
            selectSomething()
            #if DEBUG
            applyCapturePaneOverride()
            #endif
        }
    }

    /// The VoiceOver channel for transient messages: announced once, here at
    /// the root, when the message lands — never per rendering pane, so
    /// switching panes cannot re-speak a banner still on screen, and the
    /// queue's dismissals say nothing.
    ///
    /// Extracted from the root modifier chain: the two-parameter onChange
    /// closure was the expression that pushed the whole chain past the
    /// compiler's type-check time limit.
    private func announceBanner(from old: [Banner], to new: [Banner]) {
        guard new.count > old.count, let banner = new.first else { return }
        AccessibilityNotification.Announcement("\(banner.title). \(banner.message)").post()
    }

    /// ⌘B: run whichever plan the sidebar is on — when the Plan menu's
    /// Back Up Now would be enabled for it (complete, idle, restic found).
    private func runSelectedPlan() {
        let state = model.planCommands(for: router.selection)
        guard state.canBackUp, let id = state.planID else { return }
        model.runBackup(planID: id)
    }

    #if DEBUG
    /// Debug-only: lets a capture run choose which pane to render.
    ///
    /// Applied once the configuration has actually loaded — `onAppear` fires
    /// before `bootstrap()` finishes, when there is nothing to select yet.
    private func applyCapturePaneOverride() {
        guard !didApplyCaptureOverride else { return }
        guard !model.configuration.plans.isEmpty || !model.configuration.repositories.isEmpty
        else { return }
        didApplyCaptureOverride = true
        switch ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_PANE"] {
        case "plan": router.selection = model.configuration.plans.first.map { .plan($0.id) }
        case "repository": router.selection = model.configuration.repositories.first.map { .repository($0.id) }
        case "activity": router.selection = .activity
        case "find": isShowingFind = true
        case "concepts": isShowingConcepts = true
        case "console": router.selection = .console
        case "overview": router.selection = .overview
        // The restore pane needs a snapshot row to select, and those arrive
        // only after the launch refresh — see the snapshots onChange below.
        case "restore":
            pendingCaptureRestore = true
        case "repositoryHooks": editingRepository = model.configuration.repositories.first
        // Same sheet on its first tab: captures a specific kind's fields, e.g.
        // the rclone Remote row and its suggestion menu.
        case "repositoryEditor": editingRepository = model.configuration.repositories.first
        // Lets a capture run photograph the *new*-repository sheet, whose
        // destination-before-kind picker only exists before a repository exists.
        case "newRepository": editingRepository = Repository()
        // Same for the *new*-plan sheet: its first-run footer caption and
        // General tab are what a fresh creator sees, not an existing plan.
        case "newPlan": editingPlan = BackupPlan()
        case "planRetention": editingPlan = model.configuration.plans.first
        default: break
        }
    }
    #endif

    private func selectSomething() {
        // Before the configuration is read there is nothing to decide from;
        // the `isBootstrapping` change handler picks the landing pane.
        guard router.selection == nil, !model.isBootstrapping else { return }
        // The dashboard is the useful landing place once anything is configured.
        router.selection = model.configuration.repositories.isEmpty ? nil : .overview
    }

    /// Applies one consumed intent. An ask arriving while a sheet is up is
    /// dropped with a beep — macOS's "not now" — since two sheets cannot
    /// present at once, and because the main menu stays live under a sheet:
    /// a Pause Schedule under the plan editor would be undone by its save
    /// (`merging(draft:)` keeps the draft's `isEnabled`), a Remove from
    /// SwiftRestic… would leave the editor saving against a repository
    /// that is gone. The panes' own sheets (Compare, Browse Folders) are
    /// invisible from here, so AppKit is asked: SwiftUI presents every
    /// sheet as the window's attached sheet (seen in the AX tree as an
    /// AXSheet). Each ask is checked again against the model — it may
    /// have waited for a window while the plan changed.
    private func consumeIntent() {
        guard let intent = router.takePendingIntent() else { return }
        let sheetsUp = editingPlan != nil || editingRepository != nil || isShowingFind || isShowingConcepts
            || pendingConfirmation != nil || retentionTarget != nil
            || NSApp.windows.contains { $0.attachedSheet != nil }
        guard !sheetsUp else {
            NSSound.beep()
            return
        }
        switch intent {
        case .newPlan:
            editingPlan = BackupPlan()
        case .newRepository:
            editingRepository = Repository()
        case .showFind:
            isShowingFind = true
        case .showConcepts:
            isShowingConcepts = true
        case .showConsole:
            router.selection = .console
        case .runSelectedPlan:
            runSelectedPlan()
        case let .stopPlan(id):
            if model.planCommands(for: .plan(id)).canStop { model.cancelBackup(planID: id) }
        case let .pauseSchedule(id, length):
            let state = model.planCommands(for: .plan(id))
            if state.canToggleSchedule, state.isScheduleActive {
                model.pausePlanSchedule(id: id, for: length)
            }
        case let .resumeSchedule(id):
            if !model.planCommands(for: .plan(id)).isScheduleActive {
                model.resumePlanSchedule(id: id)
            }
        case let .editPlan(id):
            editingPlan = model.plan(id: id)
        case let .editRepository(id):
            editingRepository = model.repository(id: id)
        case let .applyRetention(id):
            if model.planCommands(for: .plan(id)).canApplyRetention {
                retentionTarget = RetentionTarget(planID: id)
            }
        case let .confirm(confirmation):
            if model.confirmationCopy(for: confirmation) != nil {
                pendingConfirmation = confirmation
            }
        }
    }

    /// After a deletion the selected plan or repository may no longer exist;
    /// landing on "Plan not found" is a dead end whose only exit is the
    /// sidebar, so retarget to the dashboard instead.
    private func revalidateSelection() {
        switch router.selection {
        case .plan(let id) where model.plan(id: id) == nil,
             .repository(let id) where model.repository(id: id) == nil:
            router.selection = model.configuration.repositories.isEmpty ? nil : .overview
        case .restoreSnapshot(let repositoryID, _)
            where model.repository(id: repositoryID) == nil:
            router.selection = model.configuration.repositories.isEmpty ? nil : .overview
        case let .restoreSnapshot(repositoryID, snapshotID)
            where model.snapshots(for: repositoryID).first(where: { $0.id == snapshotID }) == nil:
            // The record itself is gone; the repository's newest record (or
            // its page, when none are left) is the nearest honest landing.
            router.selection = model.snapshots(for: repositoryID).first
                .map { .restoreSnapshot(repositoryID, $0.id) }
                ?? .repository(repositoryID)
        case .console where model.configuration.repositories.isEmpty || !model.isResticAvailable:
            // Repository ▸ restic Console… is now disabled; a selection
            // parked on the pane would be one the menu no longer offers.
            router.selection = nil
        default:
            break
        }
    }
}
