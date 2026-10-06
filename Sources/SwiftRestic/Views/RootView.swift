import AppKit
import SwiftUI

/// The root split view: composes the sidebar and detail child views and
/// carries the app-level chrome — sheets and confirmations, notification
/// observers, the toolbar's look, and the selection revalidation that
/// keeps the landing pane truthful as the model changes.
///
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
    /// Which plans and Other backups are open in the sidebar — the backup
    /// records underneath are the restore pane's entry points.
    @State private var sidebarFolds = SidebarFolds()
    /// The Files views' levels, read once and shared by every page's Files
    /// tab: a level read for one is read for the next.
    @State private var filesTree = FilesTree()
    /// The adopt sheet, raised from a group's context menu or page — one
    /// presentation for both, so selecting the new plan and revealing its
    /// fold afterwards live here too.
    @State private var adoptingPlan: BackupPlan?
    #if DEBUG
    @State private var didApplyCaptureOverride = false
    /// Which Other-backups group pane a capture run asked for, waiting for
    /// the listing that creates group rows — the restore pane's own wait
    /// (`pendingCaptureRestore`).
    @State private var pendingCaptureGroupPane: CaptureGroupPane?

    /// Debug-only: the group panes a capture run can photograph. The
    /// adoptable group is the flow's landing, so it has its own value.
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
            folds: $sidebarFolds,
            onEditPlan: { editingPlan = $0 },
            onNewPlan: { editingPlan = newPlan(in: $0) },
            onEditRepository: { editingRepository = $0 },
            onNewRepository: { editingRepository = Repository() },
            onDeletePlan: { pendingConfirmation = .deletePlan($0.id) },
            onRemoveRepository: { pendingConfirmation = .removeRepository($0.id) },
            onAdoptGroup: adoptGroup
        )
    }

    private var detail: some View {
        RootDetailView(
            folds: $sidebarFolds,
            pendingCaptureRestore: $pendingCaptureRestore,
            onEditPlan: { editingPlan = $0 },
            onEditRepository: { editingRepository = $0 },
            onAddRepository: { editingRepository = Repository() },
            onAddPlan: { editingPlan = newPlan(in: $0) },
            onAdoptGroup: adoptGroup,
            onRevalidateSelection: revalidateSelection,
            onSearchAllBackups: { repositoryID, query in
                findPrefill = FindFilesView.Prefill(repositoryID: repositoryID, pattern: query)
                isShowingFind = true
            }
        )
        .environment(filesTree)
    }

    /// The sheets and confirmation dialogs that ride on the root split view.
    /// Its own chain for the type-check limit, like the others — see the
    /// type doc.
    private func presented<V: View>(over content: V) -> some View {
        // Read here, not inside the sheet's closure: read only there, the
        // prefill set together with `isShowingFind` never reaches the sheet,
        // and Find Files opens with an empty pattern. The opening repository
        // is derived the same way, beside the prefill, and handed over as a
        // parameter.
        let prefill = findPrefill
        let findFilesRepositoryID = model.findFilesRepositoryID(
            prefillRepositoryID: prefill?.repositoryID,
            selection: router.selection
        )
        return content
        .sheet(item: $editingPlan) { plan in
            PlanEditorSheet(plan: plan)
                .environment(model)
        }
        .sheet(item: $editingRepository) { repository in
            // A new repository lands on its own page, where "New Backup
            // Plan…" is the first thing it offers — the next step after
            // adding one.
            RepositoryEditorSheet(repository: repository, onCreated: { id in
                router.selection = .repository(id)
            })
            .environment(model)
        }
        .sheet(isPresented: $isShowingFind, onDismiss: { findPrefill = nil }) {
            FindFilesView(prefill: prefill, initialRepositoryID: findFilesRepositoryID)
                .environment(model)
                .environment(router)
        }
        .sheet(isPresented: $isShowingConcepts) {
            ConceptsView()
        }
        // The adopt sheet, from a group's context menu or its page. Adopt's
        // landing is the new plan's own page with its records revealed under
        // it — the click's whole result in one place.
        .sheet(item: $adoptingPlan) { plan in
            PlanEditorSheet(
                plan: plan,
                mode: .adopt,
                onAdopted: { planID in
                    router.selection = .plan(planID)
                    sidebarFolds.plans.insert(planID)
                }
            )
            .environment(model)
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
    /// keeps an ask alive while the window is closed. Its own chain for the
    /// type-check limit.
    private func observed<V: View>(over content: V) -> some View {
        content
        .onChange(of: router.pendingIntent) {
            consumeIntent()
        }
    }

    /// The toolbar's look and the banner announcements. Each pane carries
    /// its own verbs, and no button is app-wide: a plan's or a group's page
    /// searches in its Files tab's own field, the Restore pane's and the
    /// Files tab's searches carry on in Find Files through their Search All
    /// Backups…, and the Repository menu's Find Files in Snapshots… (⇧⌘F)
    /// reaches the field or the sheet from anywhere. The console stays in
    /// the Repository menu too (restic Console…).
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
        // A listing completing is the add-with-history landing's one
        // moment: the groups it builds are what that reveal opens.
        .onChange(of: model.snapshots) {
            considerAdoptionLandings()
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
        guard new.count > old.count, let banner = new.first else { return }
        AccessibilityNotification.Announcement("\(banner.title). \(banner.message)").post()
    }

    /// A fresh plan for the editor, its repository preset when the ask came
    /// from one: the editor fills in the first repository only when none is
    /// set (`PlanEditorSheet`'s appear), so the preset survives.
    private func newPlan(in repositoryID: UUID?) -> BackupPlan {
        var plan = BackupPlan()
        plan.repositoryID = repositoryID
        return plan
    }

    /// Opens the adopt sheet for a group — the one presentation both the
    /// sidebar's menu and the group's page raise through. A group that no
    /// longer reads as adoptable answers nil and nothing opens; the page it
    /// was on is revalidating away in the same breath.
    private func adoptGroup(repositoryID: UUID, planID: UUID) {
        adoptingPlan = model.adoptDraft(repositoryID: repositoryID, planID: planID)
    }

    /// The add-with-history landing: a repository whose first completed
    /// listing holds no plan of its own and at least one adoptable group
    /// opens the shelf that history sits on — Other backups, and the first
    /// group's fold — so the groups are in view without hunting. A
    /// repository whose first listing arrives beside plans never lands
    /// here, and each repository is considered once however the listing
    /// answers — the mark lives in the model, so a closed and reopened
    /// window cannot re-arm the reveal.
    private func considerAdoptionLandings() {
        for repository in model.configuration.repositories {
            guard model.snapshotsLoadedAt(for: repository.id) != nil,
                  !model.adoptionLandingsConsidered.contains(repository.id)
            else { continue }
            model.adoptionLandingsConsidered.insert(repository.id)
            guard model.plans(in: repository.id).isEmpty,
                  case let .plan(planID, _)? = model.shelves(for: repository.id).adoptableGroups.first
            else { continue }
            sidebarFolds.otherBackups.insert(repository.id)
            sidebarFolds.otherGroups.insert(OtherGroupFoldID(repositoryID: repository.id, planID: planID))
        }
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
        // The Find pane over a non-first repository: the first plan whose
        // repository is not the landing pane's (a plan's own page searches
        // its Files tab instead). Plain `find` cannot tell the opening rule
        // from the first-repository fallback — the landing selection IS the
        // first repository — so a configuration without such a plan stops
        // the run rather than photographing that fallback.
        case "findMoved":
            guard let repositoryID = model.configuration.plans.lazy.compactMap(\.repositoryID).first(where: {
                $0 != model.configuration.repositories.first?.id
            }) else {
                preconditionFailure("findMoved needs a plan whose repository is not the first")
            }
            router.selection = .repository(repositoryID)
            isShowingFind = true
        // ⇧⌘F on the first plan's page, through the menu's own route: the
        // page turns to its Files tab, the search field focused.
        case "filesSearch":
            router.selection = model.configuration.plans.first.map { .plan($0.id) }
            router.request(.showFind)
        // The first plan's page on its Files tab, its first source open and
        // selected — or SWIFTRESTIC_CAPTURE_ITEM, an absolute path under
        // that source (a folder spelled with a trailing slash), with every
        // folder above it open.
        case "files":
            guard let plan = model.configuration.plans.first, let repositoryID = plan.repositoryID,
                  let source = plan.sources.first
            else { preconditionFailure("files needs a plan with a repository and a source") }
            router.selection = .plan(plan.id)
            router.setTab(.files, of: .plan(plan.id))
            let chain = ResticService.planTag(plan.id)
            let roots = FileNode.roots(repositoryID: repositoryID, chainKey: chain)
            func folder(_ path: String) -> FileNode {
                FileNode(repositoryID: repositoryID, chainKey: chain, path: path, isDirectory: true)
            }
            router.openFolders.insert(folder(source))
            router.filesSelection[roots] = folder(source)
            if let item = ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_ITEM"] {
                let isDirectory = ResticPath.isDirectorySpelling(item)
                let path = ResticPath.normalized(item)
                var above = ResticPath.parent(of: path)
                while above.utf8.count > source.utf8.count {
                    router.openFolders.insert(folder(above))
                    above = ResticPath.parent(of: above)
                }
                router.filesSelection[roots] = FileNode(
                    repositoryID: repositoryID, chainKey: chain, path: path, isDirectory: isDirectory
                )
            }
            // SWIFTRESTIC_CAPTURE_SEARCH: the tab's search field holding a
            // query, its hits in the tree's place.
            if let query = ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_SEARCH"] {
                router.filesSearchText[roots] = query
            }
        case "concepts": isShowingConcepts = true
        case "console": router.selection = .console
        // The restore pane needs a snapshot row to select, and those arrive
        // only after the launch refresh — the selection happens in
        // `RootDetailView`'s snapshots onChange.
        case "restore":
            pendingCaptureRestore = true
        // The group pages need group rows, which the listing builds: the
        // ask parks and the backupShelves onChange consumes it — the same
        // wait as the restore pane's. The adoptable group is the adopt
        // flow's landing, so it gets its own value.
        case "orphanGroup":
            pendingCaptureGroupPane = .adoptable
        case "movedGroup":
            pendingCaptureGroupPane = .moved
        case "lineage":
            pendingCaptureGroupPane = .lineage
        case "repositoryHooks": editingRepository = model.configuration.repositories.first
        // Same sheet on its first tab: captures a specific kind's fields, e.g.
        // the rclone Remote row and its suggestion menu.
        case "repositoryEditor": editingRepository = model.configuration.repositories.first
        // Lets a capture run photograph the *new*-repository sheet, whose
        // destination-before-kind picker only exists before a repository exists.
        case "newRepository": editingRepository = Repository()
        // Same for the *new*-plan sheet: its first-run footer caption and
        // the name and repository header over the Files tab are what a
        // fresh creator sees, not an existing plan.
        case "newPlan": editingPlan = BackupPlan()
        case "planRetention": editingPlan = model.configuration.plans.first
        default: break
        }
        applyCaptureTab()
    }

    /// `SWIFTRESTIC_CAPTURE_TAB=files`: the page the run selected, on its
    /// Files tab. A selection with no tabs ignores it.
    private func applyCaptureTab() {
        guard ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_TAB"] == "files",
              let page = router.selection
        else { return }
        router.setTab(.files, of: page)
    }

    /// The parked group-pane ask, once the shelves hold a group of its
    /// kind: selects its page and opens its fold beside it, so the capture
    /// shows the page with its records in view. Keeps waiting while no
    /// matching group exists — a later listing may still build one.
    private func consumeCaptureGroupPane() {
        guard let pane = pendingCaptureGroupPane,
              let target = captureGroupTarget(pane)
        else { return }
        pendingCaptureGroupPane = nil
        router.selection = .otherGroup(repositoryID: target.repositoryID, id: target.id)
        sidebarFolds.otherBackups.insert(target.repositoryID)
        // A lineage's fold starts open; a plan-UUID group's is opened here.
        guard case let .plan(planID) = target.id else {
            applyCaptureTab()
            return
        }
        sidebarFolds.otherGroups.insert(OtherGroupFoldID(repositoryID: target.repositoryID, planID: planID))
        applyCaptureTab()
        // The adopt sheet over the page it adopts: `adopt` opens it on the
        // Files tab, `adoptRetention` on the Retention tab, where the dry-run
        // preview and the anchored count live.
        let sheet = ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_SHEET"]
        if pane == .adoptable, sheet == "adopt" || sheet == "adoptRetention" {
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
                case (.adoptable, .plan): shelves.formerPlan(of: group) == nil
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
        router.selection = SidebarTree.landingSelection(repositories: model.configuration.repositories)
    }

    /// Applies one consumed intent. An ask arriving while a sheet is up is
    /// dropped with a beep — macOS's "not now" — since two sheets cannot
    /// present at once, and because the main menu stays live under a sheet:
    /// a Pause Schedule under the plan editor would be undone by its save
    /// (`merging(draft:)` keeps the draft's `isEnabled`), a Remove from
    /// SwiftRestic… would leave the editor saving against a repository
    /// that is gone. The panes' own sheets (Compare, a restore's
    /// destination) are invisible from here, so AppKit is asked: SwiftUI
    /// presents every sheet as the window's attached sheet. Each ask is
    /// checked again against the model — it may have waited for a window
    /// while the plan changed.
    private func consumeIntent() {
        guard let intent = router.takePendingIntent() else { return }
        let sheetsUp = editingPlan != nil || editingRepository != nil || isShowingFind || isShowingConcepts
            || pendingConfirmation != nil || retentionTarget != nil || adoptingPlan != nil
            || NSApp.windows.contains { $0.attachedSheet != nil }
        guard !sheetsUp else {
            NSSound.beep()
            return
        }
        switch intent {
        case .newPlan:
            // Into the repository on screen — the one the Repository menu
            // acts on — or the editor's own default when there is none.
            editingPlan = newPlan(in: model.commandRepositoryID(for: router.selection))
        case .newRepository:
            editingRepository = Repository()
        case .showFind:
            // A plan's or a group's page searches its own history in its
            // Files tab's field; every other pane, the whole repository in
            // Find Files.
            if let page = router.selection, let roots = model.filesSearchRoots(for: page) {
                router.searchFiles(on: page, roots: roots)
            } else {
                isShowingFind = true
            }
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
    /// sidebar, so retarget to the landing pane instead. A selected
    /// Other-backups group falls back to its repository's page — the place
    /// it lived — for every way it can disappear: adopted, its plan moved
    /// by the editor, refreshed away, its repository removed.
    private func revalidateSelection() {
        let landing = SidebarTree.landingSelection(repositories: model.configuration.repositories)
        switch router.selection {
        case .plan(let id) where model.plan(id: id) == nil,
             .repository(let id) where model.repository(id: id) == nil:
            router.selection = landing
        case .restoreSnapshot(let repositoryID, _)
            where model.repository(id: repositoryID) == nil:
            router.selection = landing
        case let .restoreSnapshot(repositoryID, snapshotID)
            where model.snapshots(for: repositoryID).first(where: { $0.id == snapshotID }) == nil:
            // The record itself is gone; the repository's newest record (or
            // its page, when none are left) is the nearest honest landing.
            router.selection = model.snapshots(for: repositoryID).first
                .map { .restoreSnapshot(repositoryID, $0.id) }
                ?? .repository(repositoryID)
        case let .orphanPlan(repositoryID, planID)
            where model.shelves(for: repositoryID).orphanPlanGroup(planID) == nil:
            // The group is gone — adopted, its plan moved by the editor, or
            // refreshed away. Its repository's page is where it lived; the
            // landing pane when the repository went with it.
            router.selection = model.repository(id: repositoryID) == nil
                ? landing
                : .repository(repositoryID)
        case let .lineage(repositoryID, key)
            where model.shelves(for: repositoryID).lineageGroup(key) == nil:
            // The same for a lineage — forgotten, given a plan tag by the
            // console, or refreshed away.
            router.selection = model.repository(id: repositoryID) == nil
                ? landing
                : .repository(repositoryID)
        case .console where model.configuration.repositories.isEmpty || !model.isResticAvailable:
            // The console menu item is disabled here; a selection parked on
            // the pane must not outlive the menu item that opens it.
            router.selection = nil
        default:
            break
        }
    }
}
