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
    @State private var isShowingConcepts = false
    // Destructive actions armed from the sidebar context menus. The detail
    // pages confirm their own; these menus must not be a faster way around.
    @State private var planPendingDeletion: BackupPlan?
    @State private var repositoryPendingRemoval: Repository?
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
            onDeletePlan: { planPendingDeletion = $0 },
            onRemoveRepository: { repositoryPendingRemoval = $0 }
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
            onRevalidateSelection: revalidateSelection
        )
    }

    /// The sheets and confirmation dialogs that ride on the root split view.
    /// Split out of `body`: one expression carrying the whole chain crossed
    /// the compiler's type-check time limit (deterministic on clean builds,
    /// and only after unrelated one-line edits elsewhere — the chain sat
    /// right at the limit).
    private func presented<V: View>(over content: V) -> some View {
        content
        .sheet(item: $editingPlan) { plan in
            PlanEditorSheet(plan: plan)
                .environment(model)
        }
        .sheet(item: $editingRepository) { repository in
            RepositoryEditorSheet(repository: repository)
                .environment(model)
        }
        .sheet(isPresented: $isShowingFind) {
            FindFilesView().environment(model)
        }
        .sheet(isPresented: $isShowingConcepts) {
            ConceptsView()
        }
        .confirmationDialog(
            planPendingDeletion.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: planDeletionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Plan", role: .destructive) {
                if let plan = planPendingDeletion { model.deletePlan(id: plan.id) }
                planPendingDeletion = nil
            }
        } message: {
            Text("The plan and its schedule are removed. Snapshots already written to the repository are not deleted.")
        }
        .confirmationDialog(
            "Remove this repository from SwiftRestic?",
            isPresented: repositoryRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let repository = repositoryPendingRemoval { model.deleteRepository(id: repository.id) }
                repositoryPendingRemoval = nil
            }
        } message: {
            // Wording comes from the model so the disclosed consequences can
            // never drift from what removal actually does.
            if let repository = repositoryPendingRemoval {
                Text(model.removalConsequences(for: repository.id))
            }
        }
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

    /// The toolbar and the banner announcements.
    private func chrome<V: View>(over content: V) -> some View {
        content
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar { toolbarButtons }
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

    /// ⌘B: run whichever plan the sidebar is on. A no-op when the selection
    /// is not a runnable plan — the menu item's name says as much — and
    /// while a sheet is up, where a run would start unseen.
    private func runSelectedPlan() {
        guard editingPlan == nil, editingRepository == nil, !isShowingFind
        else { return }
        if case let .plan(id) = router.selection,
           let plan = model.plan(id: id),
           plan.isConfigurationComplete,
           !model.isRunning(planID: id)
        {
            model.runBackup(planID: id)
        }
    }

    private var toolbarButtons: some ToolbarContent {
        ToolbarItemGroup {
            Button("Find Files", systemImage: "magnifyingglass") { isShowingFind = true }
                .disabled(model.configuration.repositories.isEmpty || !model.isResticAvailable)
                .help("Search snapshots for files, across every snapshot (⇧⌘F)")
            Button("restic Console", systemImage: "apple.terminal") {
                router.selection = .console
            }
            .disabled(model.configuration.repositories.isEmpty || !model.isResticAvailable)
            .help("Run restic commands directly against a repository")
        }
    }

    private var planDeletionConfirmation: Binding<Bool> {
        Binding(
            get: { planPendingDeletion != nil },
            set: { if !$0 { planPendingDeletion = nil } }
        )
    }

    private var repositoryRemovalConfirmation: Binding<Bool> {
        Binding(
            get: { repositoryPendingRemoval != nil },
            set: { if !$0 { repositoryPendingRemoval = nil } }
        )
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
    /// dropped — two sheets cannot present at once — the same no-op the old
    /// notification guards produced.
    private func consumeIntent() {
        guard let intent = router.takePendingIntent() else { return }
        let sheetsUp = editingPlan != nil || editingRepository != nil || isShowingFind || isShowingConcepts
        switch intent {
        case .newPlan:
            guard !sheetsUp else { return }
            editingPlan = BackupPlan()
        case .newRepository:
            guard !sheetsUp else { return }
            editingRepository = Repository()
        case .showFind:
            guard !sheetsUp else { return }
            isShowingFind = true
        case .showConcepts:
            guard !sheetsUp else { return }
            isShowingConcepts = true
        case .runSelectedPlan:
            runSelectedPlan()
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
            // The row is now disabled; a selection parked on it would be a
            // pane the sidebar no longer offers.
            router.selection = nil
        default:
            break
        }
    }
}
