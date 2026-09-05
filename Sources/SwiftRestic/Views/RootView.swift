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
        .onReceive(NotificationCenter.default.publisher(for: .swiftResticShowFind)) { _ in
            isShowingFind = true
        }
        .toolbar {
            Button("Find Files", systemImage: "magnifyingglass") { isShowingFind = true }
                .disabled(model.configuration.repositories.isEmpty || !model.isResticAvailable)
            Button("restic Console", systemImage: "apple.terminal") { isShowingConsole = true }
                .disabled(model.configuration.repositories.isEmpty || !model.isResticAvailable)
        }
        .onAppear {
            selectSomething()
            #if DEBUG
            applyCapturePaneOverride()
            #endif
        }
        .onChange(of: model.configuration.plans.count) {
            selectSomething()
            #if DEBUG
            applyCapturePaneOverride()
            #endif
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
        Divider()
        Button("Delete Plan", role: .destructive) { model.deletePlan(id: plan.id) }
    }

    @ViewBuilder
    private func repositoryContextMenu(_ repository: Repository) -> some View {
        Button("Edit…") { editingRepository = repository }
        Button("Refresh") { Task { await model.refreshSnapshots(repositoryID: repository.id) } }
        Divider()
        Button("Remove from SwiftRestic", role: .destructive) {
            model.deleteRepository(id: repository.id)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .overview:
            OverviewView()
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
            ActivityView()
        case .none:
            WelcomeView(
                onAddRepository: { editingRepository = Repository() },
                onAddPlan: { editingPlan = BackupPlan() }
            )
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
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(Theme.tint)
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
                                colors: [Theme.tint, Theme.tintDeep],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .shadow(color: Theme.tint.opacity(0.25), radius: 14, y: 6)

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
