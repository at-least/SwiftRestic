import SwiftUI

/// The split view's detail column: the app-level progress strips (a restore
/// outlives the pane that started it; a missing restic greys every control),
/// the pane switch over the sidebar selection, and the selection-revalidation
/// `onChange`s that must fire in every pane state.
///
/// Split out of `RootView` as a real child view so this stack type-checks on
/// its own — the root's modifier chain sat at the compiler's type-check
/// budget. The sheet intents the panes raise are passed back as closures;
/// the presenting state stays in `RootView`.
struct RootDetailView: View {
    @Environment(AppModel.self) private var model

    /// Which Restore-section repositories are expanded — selecting a record
    /// from anywhere (the repository page's Restore Files button included)
    /// must find its group open in the sidebar.
    @Binding var expandedRestoreRepos: Set<UUID>

    /// Debug-capture state: `SWIFTRESTIC_CAPTURE_PANE=restore` — the record
    /// rows the pane needs land with the first listing, so the selection
    /// waits for it. Read and written only by the DEBUG capture paths, which
    /// own the flag in `RootView`; the unconditional declaration keeps the
    /// call site free of `#if` argument-list gymnastics.
    @Binding var pendingCaptureRestore: Bool

    let onEditPlan: (BackupPlan) -> Void
    let onEditRepository: (Repository) -> Void
    let onAddRepository: () -> Void
    let onAddPlan: () -> Void
    let onRevalidateSelection: () -> Void
    /// The model-carried new-repository intent is consumed here rather than
    /// in the root's modifier chain: this stack exists in every pane state,
    /// so the consumption fires wherever the window is already open.
    let onConsumePendingNewRepository: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // A restore outlives the pane that started it, so its progress is
            // an app-level fact: this strip sits above every pane, and the
            // menu bar line covers the window-closed case. Switching panes
            // hands the progress over to this strip.
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
                        PlanDetailView(
                            planID: plan.id,
                            onEdit: { onEditPlan(plan) },
                            onShowRun: { model.sidebarSelection = .activity }
                        )
                    } else {
                        ContentUnavailableView("Plan not found", systemImage: "questionmark.folder")
                    }
                case let .repository(id):
                    if let repository = model.repository(id: id) {
                        RepositoryDetailView(
                            repositoryID: repository.id,
                            onEdit: { onEditRepository(repository) }
                        )
                    } else {
                        ContentUnavailableView("Repository not found", systemImage: "questionmark.folder")
                    }
                case let .restoreSnapshot(repositoryID, snapshotID):
                    RestorePaneView(repositoryID: repositoryID, snapshotID: snapshotID)
                        // Folder state belongs to one repository: switching
                        // to another must not carry paths or history over —
                        // the pane's own @State resets with the identity.
                        .id(repositoryID)
                case .console:
                    ResticConsoleView()
                case .activity:
                    ActivityView(onOpenPlan: { planID in
                        model.sidebarSelection = .plan(planID)
                    })
                case .none:
                    WelcomeView(
                        onAddRepository: onAddRepository,
                        onAddPlan: onAddPlan
                    )
                }
            }
        }
        // The new-repository intent lands on this unconditional stack rather
        // than the body's modifier chain — the chain is long enough that one
        // more modifier pushed it past the type-checker's budget, and this
        // stack exists in every state, so the consumption fires wherever the
        // window is already open.
        .onChange(of: model.pendingNewRepository) {
            onConsumePendingNewRepository()
        }
        // The console row disables on restic availability as well as on an
        // empty repository list, and only count changes revalidate the
        // selection — a binary lost while the console pane is open would
        // otherwise park the selection on a row the sidebar now refuses.
        .onChange(of: model.isResticAvailable) {
            onRevalidateSelection()
        }
        // A restore record picked from anywhere (the repository page's
        // Restore Files button included) must find its group open.
        .onChange(of: model.sidebarSelection) {
            if case let .restoreSnapshot(repositoryID, _) = model.sidebarSelection {
                expandedRestoreRepos.insert(repositoryID)
            }
        }
        // A refresh can drop the selected record (retention ran, the
        // repository was re-initialised); the pane must not dead-end.
        .onChange(of: model.snapshots) {
            onRevalidateSelection()
        }
        #if DEBUG
        .onChange(of: model.snapshots) {
            // SWIFTRESTIC_CAPTURE_PANE=restore: the rows the pane needs land
            // with the first listing, so the selection happens here.
            guard pendingCaptureRestore,
                  let repository = model.configuration.repositories.first,
                  let latest = model.snapshots(for: repository.id).first
            else { return }
            pendingCaptureRestore = false
            expandedRestoreRepos.insert(repository.id)
            model.sidebarSelection = .restoreSnapshot(repository.id, latest.id)
        }
        #endif
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    let onAddRepository: () -> Void
    let onAddPlan: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            // The app's own mark — the same construction the tray wears — at
            // hero scale, bare: a welcome screen's job is the mark and the
            // two buttons, and a macOS welcome wears no plate behind its mark.
            Image(nsImage: MenuBarLogo.heroImage)
                .resizable()
                .foregroundStyle(Theme.tint)
                .aspectRatio(contentMode: .fit)
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)

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
