import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case plan(UUID)
    case repository(UUID)
    case activity
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem?
    @State private var editingPlan: BackupPlan?
    @State private var editingRepository: Repository?
    @State private var isShowingConsole = false
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
        .sheet(isPresented: $isShowingConsole) {
            ResticConsoleView().environment(model)
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
            Text("The backup data itself is not deleted. Plans pointing at it will be paused.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftResticShowFind)) { _ in
            isShowingFind = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftResticRunSelected)) { _ in
            // ⌘B: run whichever plan the sidebar is on. A no-op when the
            // selection is not a runnable plan — the menu item's name says as
            // much — and while a sheet is up, where a run would start unseen.
            guard editingPlan == nil, editingRepository == nil,
                  !isShowingConsole, !isShowingFind
            else { return }
            if case let .plan(id) = selection,
               let plan = model.plan(id: id),
               plan.isConfigurationComplete,
               !model.isRunning(planID: id)
            {
                model.runBackup(planID: id)
            }
        }
        .toolbar {
            Button("Find Files", systemImage: "magnifyingglass") { isShowingFind = true }
                .disabled(model.configuration.repositories.isEmpty || !model.isResticAvailable)
                .help("Search snapshots for files, across every snapshot (⇧⌘F)")
            Button("restic Console", systemImage: "apple.terminal") { isShowingConsole = true }
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
        .onReceive(NotificationCenter.default.publisher(for: .swiftResticShowConcepts)) { _ in
            isShowingConcepts = true
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
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
                if model.configuration.plans.isEmpty {
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
                if model.configuration.repositories.isEmpty {
                    Text("No repositories yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
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
            .disabled(model.isRunning(planID: plan.id))
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
        Button("Remove from SwiftRestic", role: .destructive) {
            repositoryPendingRemoval = repository
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
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
            switch selection {
            case .overview:
                OverviewView(onShowProblems: {
                    selection = .activity
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
            case .activity:
                ActivityView(onOpenPlan: { planID in
                    selection = .plan(planID)
                })
            case .none:
                WelcomeView(
                    onAddRepository: { editingRepository = Repository() },
                    onAddPlan: { editingPlan = BackupPlan() }
                )
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
        case "plan": selection = model.configuration.plans.first.map { .plan($0.id) }
        case "repository": selection = model.configuration.repositories.first.map { .repository($0.id) }
        case "activity": selection = .activity
        case "find": isShowingFind = true
        case "console": isShowingConsole = true
        case "overview": selection = .overview
        case "repositoryHooks": editingRepository = model.configuration.repositories.first
        default: break
        }
    }
    #endif

    private func selectSomething() {
        guard selection == nil else { return }
        // The dashboard is the useful landing place once anything is configured.
        selection = model.configuration.repositories.isEmpty ? nil : .overview
    }

    /// After a deletion the selected plan or repository may no longer exist;
    /// landing on "Plan not found" is a dead end whose only exit is the
    /// sidebar, so retarget to the dashboard instead.
    private func revalidateSelection() {
        switch selection {
        case .plan(let id) where model.plan(id: id) == nil,
             .repository(let id) where model.repository(id: id) == nil:
            selection = model.configuration.repositories.isEmpty ? nil : .overview
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

            Image(systemName: "externaldrive.badge.timemachine")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .shadow(color: Color.accentColor.opacity(0.25), radius: 14, y: 6)

            VStack(spacing: 6) {
                Text("SwiftRestic")
                    .font(.largeTitle.weight(.bold))
                Text("Scheduled, encrypted, deduplicated backups powered by restic.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Theme.Space.section) {
                welcomeFeature("lock.shield", "Encrypted", "Client-side, before anything leaves the Mac")
                welcomeFeature("clock.arrow.circlepath", "Scheduled", "Hourly to weekly, with catch-up after sleep")
                welcomeFeature("magnifyingglass", "Searchable", "Browse and restore any snapshot, any file")
            }
            .padding(.vertical, 6)

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

            HStack(spacing: 10) {
                Button("Add a Repository…", action: onAddRepository)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("New Backup Plan…", action: onAddPlan)
                    .controlSize(.large)
                    .disabled(model.configuration.repositories.isEmpty)
            }

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func welcomeFeature(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.tint)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 150)
    }
}
