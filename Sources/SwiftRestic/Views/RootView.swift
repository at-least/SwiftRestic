import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var editingPlan: BackupPlan?
    @State private var editingRepository: Repository?
    @State private var isShowingFind = false
    @State private var isShowingConcepts = false
    // Destructive actions armed from the sidebar context menus. The detail
    // pages confirm their own; these menus must not be a faster way around.
    @State private var planPendingDeletion: BackupPlan?
    @State private var repositoryPendingRemoval: Repository?
    #if DEBUG
    @State private var didApplyCaptureOverride = false
    #endif

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
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
        .confirmationDialog(
            planPendingDeletion.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(
                get: { planPendingDeletion != nil },
                set: { if !$0 { planPendingDeletion = nil } }
            ),
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
            isPresented: Binding(
                get: { repositoryPendingRemoval != nil },
                set: { if !$0 { repositoryPendingRemoval = nil } }
            ),
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
        .onReceive(NotificationCenter.default.publisher(for: .swiftResticShowFind)) { _ in
            isShowingFind = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftResticRunSelected)) { _ in
            // ⌘B: run whichever plan the sidebar is on. A no-op when the
            // selection is not a runnable plan — the menu item's name says as
            // much — and while a sheet is up, where a run would start unseen.
            guard editingPlan == nil, editingRepository == nil, !isShowingFind
            else { return }
            if case let .plan(id) = model.sidebarSelection,
               let plan = model.plan(id: id),
               plan.isConfigurationComplete,
               !model.isRunning(planID: id)
            {
                model.runBackup(planID: id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftResticNewPlan)) { _ in
            guard editingPlan == nil, editingRepository == nil, !isShowingFind else { return }
            editingPlan = BackupPlan()
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftResticNewRepository)) { _ in
            guard editingPlan == nil, editingRepository == nil, !isShowingFind else { return }
            editingRepository = Repository()
        }
        .toolbar {
            Button("Find Files", systemImage: "magnifyingglass") { isShowingFind = true }
                .disabled(model.configuration.repositories.isEmpty || !model.isResticAvailable)
                .help("Search snapshots for files, across every snapshot (⇧⌘F)")
            Button("restic Console", systemImage: "apple.terminal") {
                model.sidebarSelection = .console
            }
            .disabled(model.configuration.repositories.isEmpty || !model.isResticAvailable)
            .help("Run restic commands directly against a repository")
        }
        .onAppear {
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
        .onReceive(NotificationCenter.default.publisher(for: .swiftResticShowConcepts)) { _ in
            isShowingConcepts = true
        }
        .onChange(of: model.banners) { old, new in
            // The VoiceOver channel for transient messages: announced once,
            // here at the root, when the message lands — never per rendering
            // pane, so switching panes cannot re-speak a banner still on
            // screen, and the queue's dismissals say nothing.
            guard new.count > old.count, let banner = new.first else { return }
            AccessibilityNotification.Announcement("\(banner.title). \(banner.message)").post()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding(
            get: { model.sidebarSelection },
            set: { model.sidebarSelection = $0 }
        )) {
            Section {
                Label("Overview", systemImage: "square.grid.2x2")
                    .tag(SidebarItem.overview)
            }

            Section("Backup Plans") {
                ForEach(model.configuration.plans) { plan in
                    PlanSidebarRow(plan: plan)
                        .tag(SidebarItem.plan(plan.id))
                        .contextMenu { planContextMenu(plan) }
                }
                if model.configuration.plans.isEmpty, !model.isBootstrapping {
                    Text("No plans yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Repositories") {
                ForEach(model.configuration.repositories) { repository in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(repository.name)
                                .lineLimit(1)
                            Text(repository.displayLocation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } icon: {
                        Image(systemName: repository.kind.symbolName)
                            .foregroundStyle(Theme.tint)
                    }
                    .tag(SidebarItem.repository(repository.id))
                    .contextMenu { repositoryContextMenu(repository) }
                }
                if model.configuration.repositories.isEmpty, !model.isBootstrapping {
                    Text("No repositories yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // Console and Activity are peers, not a lone tool plus a footnote.
            Section("Tools") {
                Label("restic Console", systemImage: "apple.terminal")
                    .tag(SidebarItem.console)
                Label("Activity", systemImage: "list.bullet.rectangle")
                    .tag(SidebarItem.activity)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Menu {
                Button("New Backup Plan…") { editingPlan = BackupPlan() }
                    .disabled(model.configuration.repositories.isEmpty)
                Button("Add Repository…") { editingRepository = Repository() }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if !model.isResticAvailable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .help(model.binaryProblem ?? "restic not found")
                    .accessibilityLabel(model.binaryProblem ?? "restic not found")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func planContextMenu(_ plan: BackupPlan) -> some View {
        Button("Back Up Now") { model.runBackup(planID: plan.id) }
            // Same guard the menu bar applies: an incomplete plan has nothing
            // to run, and an error banner is not a substitute for a disabled
            // item.
            .disabled(model.isRunning(planID: plan.id) || !plan.isConfigurationComplete)
        Button("Edit…") { editingPlan = plan }
        // The sidebar row already wears a pause icon when disabled; the menu
        // is where that state is changed. Manual runs stay possible either way.
        Button(plan.isEnabled ? "Pause Scheduled Runs" : "Resume Scheduled Runs") {
            model.setPlanEnabled(id: plan.id, isEnabled: !plan.isEnabled)
        }
        Divider()
        Button("Delete Plan", role: .destructive) { planPendingDeletion = plan }
    }

    @ViewBuilder
    private func repositoryContextMenu(_ repository: Repository) -> some View {
        Button("Edit…") { editingRepository = repository }
        Button("Refresh") { Task { await model.refreshSnapshots(repositoryID: repository.id) } }
        Divider()
        Button("Remove from SwiftRestic…", role: .destructive) {
            repositoryPendingRemoval = repository
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            // A restore outlives the sheet that started it, so its progress is
            // an app-level fact: this strip sits above every pane, and the
            // menu bar line covers the window-closed case. Dismissing the
            // browser or Find sheet hands the progress over to this strip.
            if let progress = model.restoreActivity {
                OperationProgressView(
                    title: model.restoreDescription.isEmpty ? "Restoring" : model.restoreDescription,
                    progress: progress,
                    startedAt: nil,
                    onCancel: { model.cancelRestore() }
                )
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            // The one disabled-state whose cause the user cannot see from the
            // panes themselves: every restic-backed control is grey, and this
            // is why.
            if !model.isResticAvailable {
                // Built in place, not posted: the condition is the model's
                // binary state, so there is nothing to dismiss.
                BannerView(
                    banner: Banner(
                        title: "restic is missing",
                        message: model.binaryProblem ?? "restic could not be found. Install it with `brew install restic`, or set the path in Settings.",
                        isError: true
                    ),
                    isDismissible: false
                )
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            if model.isBootstrapping {
                // Configuration still being read: a loading state, not the
                // empty states — an empty sidebar and Welcome here would read
                // as a fresh install or as breakage.
                ProgressView("Reading your configuration…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch model.sidebarSelection {
                case .overview:
                    OverviewView(onShowProblems: {
                        model.sidebarSelection = .activity
                    })
                case let .plan(id):
                    if let plan = model.plan(id: id) {
                        PlanDetailView(planID: plan.id, onEdit: { editingPlan = plan })
                    } else {
                        ContentUnavailableView("Plan not found", systemImage: "questionmark.folder")
                    }
                case let .repository(id):
                    if let repository = model.repository(id: id) {
                        RepositoryDetailView(
                            repositoryID: repository.id,
                            onEdit: { editingRepository = repository }
                        )
                    } else {
                        ContentUnavailableView("Repository not found", systemImage: "questionmark.folder")
                    }
                case .console:
                    ResticConsoleView()
                case .activity:
                    ActivityView(onOpenPlan: { planID in
                        model.sidebarSelection = .plan(planID)
                    })
                case .none:
                    WelcomeView(
                        onAddRepository: { editingRepository = Repository() },
                        onAddPlan: { editingPlan = BackupPlan() }
                    )
                }
            }
        }
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
        case "plan": model.sidebarSelection = model.configuration.plans.first.map { .plan($0.id) }
        case "repository": model.sidebarSelection = model.configuration.repositories.first.map { .repository($0.id) }
        case "activity": model.sidebarSelection = .activity
        case "find": isShowingFind = true
        case "console": model.sidebarSelection = .console
        case "overview": model.sidebarSelection = .overview
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
        guard model.sidebarSelection == nil, !model.isBootstrapping else { return }
        // The dashboard is the useful landing place once anything is configured.
        model.sidebarSelection = model.configuration.repositories.isEmpty ? nil : .overview
    }

    /// After a deletion the selected plan or repository may no longer exist;
    /// landing on "Plan not found" is a dead end whose only exit is the
    /// sidebar, so retarget to the dashboard instead.
    private func revalidateSelection() {
        switch model.sidebarSelection {
        case .plan(let id) where model.plan(id: id) == nil,
             .repository(let id) where model.repository(id: id) == nil:
            model.sidebarSelection = model.configuration.repositories.isEmpty ? nil : .overview
        default:
            break
        }
    }
}

private struct PlanSidebarRow: View {
    @Environment(AppModel.self) private var model
    let plan: BackupPlan

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(plan.name.isEmpty ? "Untitled Plan" : plan.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            if model.isRunning(planID: plan.id) {
                ProgressView().controlSize(.small)
            } else if !plan.isEnabled {
                Image(systemName: "pause.circle")
                    .foregroundStyle(.secondary)
            } else {
                // The plan's own colour, the same one its chart series and
                // run rows use — identity carried across every surface.
                Circle()
                    .fill(ChartPalette.color(for: plan))
                    .frame(width: 9, height: 9)
            }
        }
    }

    private var subtitle: String {
        if let activity = model.activity[plan.id] {
            return activity.phase.displayName
        }
        // The icon alone carried the paused state; the subtitle says it so
        // colour and symbol are never the only signals.
        if !plan.isEnabled {
            return "Paused — \(plan.schedule.summary)"
        }
        if plan.lastSuccessAt != nil {
            return "Last backup \(Format.relative(plan.lastSuccessAt))"
        }
        return plan.schedule.summary
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    let onAddRepository: () -> Void
    let onAddPlan: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            // The tinted chip the rest of the app uses (sheet headers, tiles,
            // banners) at hero scale — the old gradient-and-shadow plate was
            // the one ornamental surface in an otherwise flat, hairline world.
            Image(systemName: "externaldrive.badge.timemachine")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Theme.tint)
                .frame(width: 84, height: 84)
                .background(
                    Theme.tint.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Theme.tint.opacity(0.22), lineWidth: 1)
                )

            Text("SwiftRestic")
                .font(.largeTitle.weight(.bold))

            if let problem = model.binaryProblem {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("restic is not available")
                            .font(.headline)
                        Text(problem)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Theme.Space.cardPadding)
                .frame(maxWidth: 460)
                .cardSurface()
            }

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button("Add a Repository…", action: onAddRepository)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button("New Backup Plan…") {
                        // The plan's first requirement is where backups go.
                        // With no repository yet, this button starts there —
                        // a disabled button with an invisible reason was a
                        // dead end at the exact moment adoption is decided.
                        if model.configuration.repositories.isEmpty {
                            onAddRepository()
                        } else {
                            onAddPlan()
                        }
                    }
                    .controlSize(.large)
                }
                if model.configuration.repositories.isEmpty {
                    Text("A backup plan backs up to a repository — add the repository first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
