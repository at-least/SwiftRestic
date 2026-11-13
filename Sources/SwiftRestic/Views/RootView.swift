import AppKit
import SwiftUI

/// The four per-concern chains below (`presented`, `observed`, `chrome`,
/// `revalidate`) are each one modifier stack over the split view. They stay
/// apart because one expression carrying the whole chain crosses the
/// compiler's type-check time limit. The sidebar and detail column live
/// in `SidebarView` and `RootDetailView`, each type-checking on its own.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @State private var editingPlan: BackupPlan?
    @State private var editingRepository: Repository?
    /// Enter Password…, a missing or refused password's fix.
    @State private var enteringPassword: Repository?
    /// Enter Share Password…, a refused network share's fix.
    @State private var enteringSharePassword: NetworkShare?
    /// Back Up a Folder…'s folder, chosen: the first-run sheet's.
    @State private var firstBackupSource: FirstBackupSource?
    /// The first-run sheet was left for the repository editor's server and
    /// cloud kinds: set from the sheet's handoff until the editor closes,
    /// its Back Up then creating the plan as the sheet's would.
    @State private var firstBackupHandoff: FirstBackupHandoff?
    /// The missing location the repository editor is adding a replacement
    /// for, until the editor closes.
    @State private var replacedRepositoryID: UUID?
    /// The one confirmation up, from whichever surface asked
    /// (`CommandPresentations`).
    @State private var pendingConfirmation: CommandConfirmation?
    /// The disk's turn every page's Backups tab reads this Mac by.
    @State private var diskWatch = DiskWatch()
    /// The adopt sheet, raised from a group's context menu or page — one
    /// presentation for both, so selecting the new plan afterwards lives
    /// here too.
    @State private var adoptingPlan: BackupPlan?
    #if DEBUG
    @State private var didApplyCaptureOverride = false
    /// Which Other-backups group pane a capture run asked for, waiting for
    /// the listing that creates group rows — the restore pane's own wait
    /// (`pendingCaptureRestore`).
    @State private var pendingCaptureGroupPane: CaptureGroupPane?

    /// The adoptable group is the flow's landing, so it has its own value.
    private enum CaptureGroupPane {
        case adoptable
        case moved
        case lineage
    }
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
            onEditPlan: { editingPlan = $0 },
            onNewPlan: startBackUpAFolder(in:),
            onEditRepository: { editingRepository = $0 },
            onNewRepository: addRepository,
            onDeletePlan: { pendingConfirmation = .deletePlan($0.id) },
            onRemoveRepository: { pendingConfirmation = .deleteRepository($0.id) },
            onAdoptGroup: adoptGroup
        )
    }

    private var detail: some View {
        RootDetailView(
            pendingCaptureRestore: $pendingCaptureRestore,
            onAddPlan: startBackUpAFolder(in:),
            onAdoptGroup: adoptGroup,
            onRevalidateSelection: revalidateSelection
        )
        .environment(diskWatch)
        // The toolbar's material is hidden (`chrome`), so nothing else stops
        // a scrolled list from drawing under the title.
        .clipped()
    }

    private func presented<V: View>(over content: V) -> some View {
        content
        .sheet(item: $editingPlan) { plan in
            PlanEditorSheet(plan: plan)
                .environment(model)
        }
        // Not sheet(isPresented:) beside a separate source: its content kept
        // the source from before the panel, and the sheet opened on an empty
        // folder (seen in the UI tests).
        .sheet(item: $firstBackupSource, onDismiss: continueWithServerOrCloud) { firstBackup in
            FirstBackupSheet(
                source: firstBackup.path,
                destination: firstBackup.destination,
                onCreated: { router.selection = .plan($0) },
                onServerOrCloud: { firstBackupHandoff = $0 }
            )
            .environment(model)
        }
        .sheet(item: $editingRepository, onDismiss: {
            firstBackupHandoff = nil
            replacedRepositoryID = nil
        }) { repository in
            // A new repository lands on its own page, where "Back Up a
            // Folder" is the first thing it offers; one added for the
            // first-run sheet lands on the plan made in it.
            RepositoryEditorSheet(
                repository: repository,
                firstBackupSource: firstBackupHandoff?.source,
                password: firstBackupHandoff?.password ?? "",
                confirmPassword: firstBackupHandoff?.confirmPassword ?? "",
                replacing: replacedRepositoryID,
                onCreated: { id in
                    if let handoff = firstBackupHandoff {
                        router.selection = .plan(model.createFirstPlan(source: handoff.source, repositoryID: id))
                    } else {
                        router.selection = .repository(id)
                    }
                }
            )
            .environment(model)
        }
        .sheet(item: $enteringPassword) { repository in
            PasswordPromptSheet(repository: repository)
                .environment(model)
        }
        .sheet(item: $enteringSharePassword) { share in
            SharePasswordPromptSheet(share: share)
                .environment(model)
        }
        // Adopt lands on the new plan's Backups tab: the history, now the
        // plan's.
        .sheet(item: $adoptingPlan) { plan in
            AdoptPlanSheet(
                draft: plan,
                onAdopted: { planID in
                    router.setTab(.backups, of: .plan(planID))
                    router.selection = .plan(planID)
                }
            )
            .environment(model)
        }
        // A modifier of its own: this chain sits at the type-check limit.
        .modifier(CommandPresentations(
            pendingConfirmation: $pendingConfirmation
        ))
    }

    /// The intents the menu bar and the tray park on the router, which cannot
    /// reach this view. Consumed on appear (`revalidate`) and on change, so
    /// an ask stays alive while the window is closed.
    private func observed<V: View>(over content: V) -> some View {
        content
        .onChange(of: router.pendingIntent) {
            consumeIntent()
        }
    }

    /// No toolbar button is app-wide: each pane carries its own verbs.
    private func chrome<V: View>(over content: V) -> some View {
        content
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onChange(of: model.banners) { announceBanner(from: $0, to: $1) }
    }

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
        // The one trigger that sees a plan move to another repository: no
        // count changes and the listing holds the same records, but
        // `reshelve` rewrites the shelves — the structure the sidebar and
        // the pages both read. The same write sees a group adopted away
        // and one a refresh drops.
        .onChange(of: model.backupShelves) {
            revalidateSelection()
            #if DEBUG
            consumeCaptureGroupPane()
            #endif
        }
        // The load finishing is what selects the landing pane: onAppear runs
        // before `bootstrap` has read anything, so without this a configured
        // app would sit on Welcome.
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
    /// queue's dismissals say nothing. A method, not an inline two-parameter
    /// `onChange` closure: that expression pushes the chain past the
    /// compiler's type-check time limit.
    private func announceBanner(from old: [Banner], to new: [Banner]) {
        // By identity, not count: past the queue's limit a new banner
        // evicts an old one, and the count stays.
        guard let banner = new.first, !old.contains(where: { $0.id == banner.id }) else { return }
        // The visible banner drops an empty message; the announcement must
        // not read one as a trailing ". ".
        let text = banner.message.isEmpty ? banner.title : "\(banner.title). \(banner.message)"
        AccessibilityNotification.Announcement(text).post()
    }

    /// Back Up a Folder…, from whichever control: the folder panel, its
    /// pop-up on `repositoryID` when the ask came from a location, then the
    /// first-run sheet unless the panel's answer was the last one. A
    /// cancelled panel opens nothing.
    private func startBackUpAFolder(in repositoryID: UUID?) {
        // With no location yet its Back Up asks restic; the page behind says
        // how to get it.
        guard model.isResticAvailable || !model.configuration.repositories.isEmpty else {
            NSSound.beep()
            return
        }
        // Out of any menu's tracking first: the asks come from menus too,
        // and a panel run inside one gets no keys (`FirstBackupSheet`'s
        // Other…).
        let source = $firstBackupSource
        let repositories = model.configuration.repositories
        let locations = repositories.map { BackUpAFolderPanel.Location(id: $0.id, label: model.label(of: $0)) }
        let initial = FirstBackupDestination.initial(onScreen: repositoryID, among: repositories)
        let model = model
        let router = router
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                guard let answer = BackUpAFolderPanel.run(locations: locations, initial: initial) else { return }
                if let planID = model.backUpWithoutSheet(source: answer.source, destination: answer.destination) {
                    router.selection = .plan(planID)
                } else {
                    source.wrappedValue = FirstBackupSource(path: answer.source, destination: answer.destination)
                }
            }
        }
    }

    private func continueWithServerOrCloud() {
        guard let handoff = firstBackupHandoff else { return }
        var repository = Repository()
        repository.kind = handoff.kind
        editingRepository = repository
    }

    private func addRepository() {
        guard model.isResticAvailable else {
            NSSound.beep()
            return
        }
        editingRepository = Repository()
    }

    /// Opens the adopt sheet for a group — the one presentation both the
    /// sidebar's menu and the group's page raise through. A group that no
    /// longer reads as adoptable answers nil and nothing opens; the page it
    /// was on is revalidating away in the same breath.
    private func adoptGroup(repositoryID: UUID, planID: UUID) {
        Task { adoptingPlan = await model.adoptDraft(repositoryID: repositoryID, planID: planID) }
    }

    private func runSelectedPlan() {
        let state = model.planCommands(for: router.selection)
        guard state.canBackUp else { return }
        if let id = state.planID {
            model.runBackup(planID: id)
        } else {
            model.runBackups(planIDs: state.repositoryPlanIDs)
        }
    }

    #if DEBUG
    /// Applied once the configuration has actually loaded — `onAppear` fires
    /// before `bootstrap()` finishes, when there is nothing to select yet.
    private func applyCapturePaneOverride() {
        guard !didApplyCaptureOverride else { return }
        // An empty configuration's sheet, so ahead of the guard below.
        if ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_PANE"] == "firstBackup", !model.isBootstrapping {
            didApplyCaptureOverride = true
            firstBackupSource = FirstBackupSource(
                path: ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_ITEM"] ?? NSHomeDirectory(),
                destination: FirstBackupDestination.initial(onScreen: nil, among: model.configuration.repositories)
            )
            return
        }
        guard !model.configuration.plans.isEmpty || !model.configuration.repositories.isEmpty
        else { return }
        didApplyCaptureOverride = true
        switch ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_PANE"] {
        case "plan": router.selection = model.configuration.plans.first.map { .plan($0.id) }
        case "repository": router.selection = model.configuration.repositories.first.map { .repository($0.id) }
        case "activity": router.selection = .activity
        case "find":
            // SWIFTRESTIC_CAPTURE_FIND: a search in place on arrival.
            router.openFind(query: ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_FIND"])
        // The first plan's page on its Backups tab — with
        // SWIFTRESTIC_CAPTURE_ITEM, an absolute path in its newest backup,
        // that backup open at the item, a file's versions under the tree.
        case "files":
            guard let plan = model.configuration.plans.first, let repositoryID = plan.repositoryID
            else { preconditionFailure("files needs a plan with a repository") }
            router.selection = .plan(plan.id)
            router.setTab(.backups, of: .plan(plan.id))
            if let item = ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_ITEM"] {
                guard let newest = model.latestSnapshot(in: repositoryID, planID: plan.id)
                else { preconditionFailure("SWIFTRESTIC_CAPTURE_ITEM needs the plan's backups listed") }
                router.showBackup(newest.id, on: .plan(plan.id), repositoryID: repositoryID, focusPath: ResticPath.normalized(item))
            }
        case "concepts": openWindow(id: SwiftResticApp.helpWindowID)
        case "console": openWindow(id: SwiftResticApp.consoleWindowID)
        // The restore pane needs a snapshot row to select, and those arrive
        // only after the launch refresh — the selection happens in
        // `RootDetailView`'s snapshots onChange.
        case "restore":
            pendingCaptureRestore = true
        // The group pages need group rows, which the listing builds: the
        // ask parks and the backupShelves onChange consumes it.
        case "orphanGroup":
            pendingCaptureGroupPane = .adoptable
        case "movedGroup":
            pendingCaptureGroupPane = .moved
        case "lineage":
            pendingCaptureGroupPane = .lineage
        // Same sheet on its first tab: captures a specific kind's fields.
        case "repositoryEditor": editingRepository = model.configuration.repositories.first
        // Lets a capture run photograph the *new*-repository sheet, whose
        // destination-before-kind picker only exists before a repository exists.
        case "newRepository": editingRepository = Repository()
        case "planRetention": editingPlan = model.configuration.plans.first
        case "planEditor": editingPlan = model.configuration.plans.first
        default: break
        }
        applyCaptureTab()
    }

    /// `SWIFTRESTIC_CAPTURE_TAB=backups`: the page the run selected, on
    /// that tab. A page with no tabs ignores it.
    private func applyCaptureTab() {
        let tab: PageTab? = switch ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_TAB"] {
        case "backups": .backups
        default: nil
        }
        guard let tab, let page = router.selection, page.pageTabs.contains(tab) else { return }
        router.setTab(tab, of: page)
    }

    /// The parked group-pane ask, once the shelves hold a group of its
    /// kind: selects its page. Keeps waiting while no matching group exists
    /// — a later listing may still build one.
    private func consumeCaptureGroupPane() {
        guard let pane = pendingCaptureGroupPane,
              let target = captureGroupTarget(pane)
        else { return }
        pendingCaptureGroupPane = nil
        router.selection = .otherGroup(repositoryID: target.repositoryID, id: target.id)
        applyCaptureTab()
        guard case let .plan(planID) = target.id else { return }
        // The adopt sheet over the page it adopts.
        let sheet = ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_SHEET"]
        if pane == .adoptable, sheet == "adopt" {
            adoptGroup(repositoryID: target.repositoryID, planID: planID)
        }
    }

    /// The first group of the pane's kind, repositories in configuration
    /// order, groups in the sidebar's own newest-first order.
    private func captureGroupTarget(_ pane: CaptureGroupPane) -> (repositoryID: UUID, id: OtherBackupsGroup.ID)? {
        for repository in model.configuration.repositories {
            let shelves = model.shelves(for: repository.id)
            for group in shelves.others {
                let matches = switch (pane, group) {
                case (.lineage, .lineage): true
                case (.adoptable, .plan): shelves.adoptablePath(of: group, localHost: model.localHostname) != nil
                case (.moved, .plan): shelves.formerPlan(of: group) != nil
                default: false
                }
                if matches { return (repository.id, group.id) }
            }
        }
        return nil
    }
    #endif

    private func selectSomething() {
        // Before the configuration is read there is nothing to decide from;
        // the `isBootstrapping` change handler picks the landing pane.
        guard router.selection == nil, !model.isBootstrapping else { return }
        router.selection = SidebarTree.landingSelection(
            repositories: model.configuration.repositories, plans: model.configuration.plans
        )
    }

    /// Applies one consumed intent. An ask arriving while a sheet is up is
    /// dropped with a beep (macOS's "not now"): two sheets cannot present at
    /// once, and the main menu stays live under a sheet, so a Remove Location
    /// would leave the editor saving against a repository that is gone. The
    /// panes' own sheets are invisible from here, so AppKit is asked: SwiftUI
    /// presents every sheet as the window's attached sheet. Each ask is
    /// checked again against the model: it may have waited for a window
    /// while the plan changed.
    private func consumeIntent() {
        guard let intent = router.takePendingIntent() else { return }
        let sheetsUp = editingPlan != nil || editingRepository != nil || enteringPassword != nil
            || enteringSharePassword != nil || firstBackupSource != nil
            || pendingConfirmation != nil || adoptingPlan != nil
            || NSApp.windows.contains { $0.attachedSheet != nil }
        guard !sheetsUp else {
            NSSound.beep()
            return
        }
        switch intent {
        case .newPlan:
            // Into the location on screen — the one the Location menu
            // acts on.
            startBackUpAFolder(in: model.commandRepositoryID(for: router.selection))
        case .newRepository:
            addRepository()
        case let .addRepository(replacing: id):
            guard model.isResticAvailable, let missing = model.repository(id: id), missing.kind != .local else {
                NSSound.beep()
                return
            }
            replacedRepositoryID = id
            editingRepository = missing.replacement()
        case .showFind:
            router.openFind()
        case .runSelectedPlan:
            runSelectedPlan()
        case let .stopPlan(id):
            if model.planCommands(for: .plan(id)).canStop { model.cancelBackup(planID: id) }
        case let .editPlan(id):
            editingPlan = model.plan(id: id)
        case let .editRepository(id):
            editingRepository = model.repository(id: id)
        case let .enterPassword(id):
            enteringPassword = model.repository(id: id)
        case let .enterSharePassword(.repository(id)):
            if let share = model.savedShare(forRepository: id) {
                enteringSharePassword = share
            } else {
                editingRepository = model.repository(id: id)
            }
        case let .enterSharePassword(.plan(id)):
            if let share = model.savedShare(forPlan: id) {
                enteringSharePassword = share
            } else {
                editingPlan = model.plan(id: id)
            }
        case let .confirm(confirmation):
            if model.confirmationCopy(for: confirmation) != nil {
                pendingConfirmation = confirmation
            }
        case let .verifyBackups(id):
            guard model.repositoryCommands(for: .repository(id)).canMaintain else { return }
            model.runMaintenance(repositoryID: id, task: .check)
            router.showMaintenance(of: id)
        case let .freeUpSpace(id):
            guard model.repositoryCommands(for: .repository(id)).canMaintain else { return }
            model.runMaintenance(repositoryID: id, task: .prune)
            router.showMaintenance(of: id)
        }
    }

    /// The rules live on `AppRouter.revalidated`, where tests reach them;
    /// this applies the answer, and only when it moved, so an unchanged
    /// selection is no observable write.
    private func revalidateSelection() {
        let corrected = AppRouter.revalidated(
            selection: router.selection,
            repositories: model.configuration.repositories,
            plans: model.configuration.plans,
            shelves: { model.shelves(for: $0) },
            isResticAvailable: model.isResticAvailable
        )
        if corrected != router.selection { router.selection = corrected }
    }
}

/// The folder Back Up a Folder…'s panel chose, presenting the first-run sheet.
private struct FirstBackupSource: Identifiable {
    let id = UUID()
    let path: String
    /// What the sheet opens on: the panel's location, nil to ask.
    let destination: FirstBackupDestination?
}
