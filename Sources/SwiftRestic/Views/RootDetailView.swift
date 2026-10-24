import SwiftUI

/// The split view's detail column: the app-level progress strips (a restore
/// outlives the pane that started it; a missing restic greys every control),
/// the pane switch over the sidebar selection, and the selection-revalidation
/// `onChange`s that must fire in every pane state.
///
/// A real child view, split out of `RootView` so this stack type-checks on
/// its own — the root's modifier chain sits at the compiler's type-check
/// time limit. The sheet intents the panes raise are passed back as
/// closures; the presenting state stays in `RootView`.
struct RootDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.openSettings) private var openSettings

    /// Debug-capture state: `SWIFTRESTIC_CAPTURE_PANE=restore` — the record
    /// rows the pane needs land with the first listing, so the selection
    /// waits for it. Read and written only by the DEBUG capture paths, which
    /// own the flag in `RootView`; the unconditional declaration keeps the
    /// call site free of `#if` argument-list gymnastics.
    @Binding var pendingCaptureRestore: Bool

    /// Opens the plan editor, with the repository preset when one is given.
    let onAddPlan: (_ repositoryID: UUID?) -> Void
    /// Opens the adopt sheet for an Other backups group — its page or the
    /// repository page's card — the root owns the presenting state, as for
    /// every sheet a pane raises.
    let onAdoptGroup: (_ repositoryID: UUID, _ planID: UUID) -> Void
    let onRevalidateSelection: () -> Void
    /// "Search All Backups" — the Restore pane's, and a Files tab's with no
    /// match: Find Files, prefilled.
    let onSearchAllBackups: (_ repositoryID: UUID, _ query: String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // A restore outlives the pane that started it, so its progress is
            // an app-level fact: this strip sits above every pane, and the
            // menu bar line covers the window-closed case. Switching panes
            // hands the progress over to this strip. The fallback names the
            // work when no description has arrived.
            RestoreProgressStrip(fallbackTitle: "Restoring")
                .padding(.horizontal, 16)
                .padding(.top, 10)
            // The one disabled-state whose cause the user cannot see from the
            // panes themselves: every restic-backed control is grey, and this
            // is why.
            // Only once the search for restic has answered: until then the
            // binary is unknown, not missing.
            if let problem = model.binaryProblem {
                // Built in place, not posted: the condition is the model's
                // binary state, so there is nothing to dismiss.
                BannerView(
                    banner: Banner(
                        title: "restic is missing",
                        message: problem,
                        isError: true
                    ),
                    isDismissible: false,
                    settingsAction: { openSettings() }
                )
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            BannerQueue()
            if model.isBootstrapping {
                // Configuration still being read: a loading state, not the
                // empty states — an empty sidebar and Welcome here would read
                // as a fresh install or as breakage.
                ProgressView("Reading your configuration…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch router.selection {
                case let .plan(id):
                    if let plan = model.plan(id: id) {
                        PlanDetailView(
                            planID: plan.id,
                            onSearchAllBackups: onSearchAllBackups
                        )
                    } else {
                        ContentUnavailableView("Plan not found", systemImage: "questionmark.folder")
                    }
                case let .repository(id):
                    if let repository = model.repository(id: id) {
                        RepositoryDetailView(
                            repositoryID: repository.id,
                            onAddPlan: { onAddPlan(repository.id) },
                            onAdoptGroup: onAdoptGroup
                        )
                    } else {
                        ContentUnavailableView("Repository not found", systemImage: "questionmark.folder")
                    }
                case let .orphanPlan(repositoryID, planID):
                    OtherGroupView(
                        repositoryID: repositoryID,
                        groupID: .plan(planID),
                        onAdopt: { onAdoptGroup(repositoryID, $0) },
                        onSearchAllBackups: onSearchAllBackups
                    )
                case let .lineage(repositoryID, key):
                    OtherGroupView(
                        repositoryID: repositoryID,
                        groupID: .lineage(key),
                        onAdopt: { onAdoptGroup(repositoryID, $0) },
                        onSearchAllBackups: onSearchAllBackups
                    )
                case .console:
                    ResticConsoleView()
                case .findFiles:
                    FindFilesView()
                case .activity:
                    ActivityView()
                case .none:
                    WelcomeView(
                        onAddPlan: { onAddPlan(nil) }
                    )
                }
            }
        }
        // Find Files and the console need restic: a binary lost while either
        // is open must move the selection off it.
        .onChange(of: model.isResticAvailable) {
            onRevalidateSelection()
        }
        #if DEBUG
        .onChange(of: model.snapshots) {
            // SWIFTRESTIC_CAPTURE_PANE=restore: the first repository's
            // newest backup, open on its page's Backups tab — the listing
            // it needs lands after launch, so the selection happens here —
            // with SWIFTRESTIC_CAPTURE_ITEM's folder walked open.
            guard pendingCaptureRestore,
                  let repository = model.configuration.repositories.first,
                  let latest = model.snapshots(for: repository.id).first,
                  let page = model.page(ofBackup: latest.id, in: repository.id)
            else { return }
            pendingCaptureRestore = false
            router.showBackup(
                latest.id, on: page, repositoryID: repository.id,
                focusPath: ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_ITEM"]
            )
        }
        #endif
    }
}

/// The banner queue, once, above every pane — a plan's Files tab and the
/// console included, where each page had carried its own copy and some
/// none: a restore started from a Files tab finished out of sight. Its own
/// view, so a banner never re-renders the pane. Never height-pinned
/// (BannerView's rule); newer banners claim height first, so when the
/// column runs short the oldest is the one cut, never the news just in.
private struct BannerQueue: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.banners.isEmpty {
            VStack(spacing: 8) {
                let banners = model.banners
                ForEach(Array(banners.enumerated()), id: \.element.id) { index, banner in
                    BannerView(banner: banner)
                        .layoutPriority(Double(banners.count - index))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    let onAddPlan: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            // The app's own mark — the same construction the tray wears — at
            // hero scale, bare: a welcome screen's job is the mark and the
            // button, and a macOS welcome wears no plate behind its mark.
            Image(nsImage: MenuBarLogo.heroImage)
                .resizable()
                .foregroundStyle(Theme.tint)
                .aspectRatio(contentMode: .fit)
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)

            Text("SwiftRestic")
                .font(.largeTitle.weight(.bold))

            VStack(spacing: 8) {
                // The one prominent step. With no repository yet it starts
                // there and carries on to the plan (`RootView.startNewPlan`),
                // so "Add Repository" would be its own first half.
                Button("New Backup Plan", action: onAddPlan)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                if model.configuration.repositories.isEmpty {
                    Text("A backup plan backs up to a repository — New Backup Plan sets one up first.")
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
