import SwiftUI

/// A real child view, split out of `RootView` so this stack type-checks on
/// its own — the root's modifier chain sits at the compiler's type-check
/// time limit. The sheet intents the panes raise are passed back as
/// closures; the presenting state stays in `RootView`.
struct RootDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router

    /// Debug-capture state: `SWIFTRESTIC_CAPTURE_PANE=restore` — the record
    /// rows the pane needs land with the first listing, so the selection
    /// waits for it. Read and written only by the DEBUG capture paths, which
    /// own the flag in `RootView`; the unconditional declaration keeps the
    /// call site free of `#if` argument-list gymnastics.
    @Binding var pendingCaptureRestore: Bool

    let onAddPlan: (_ repositoryID: UUID?) -> Void
    /// Opens the adopt sheet for an Other backups group — its page or the
    /// location page — the root owns the presenting state, as for
    /// every sheet a pane raises.
    let onAdoptGroup: (_ repositoryID: UUID, _ planID: UUID) -> Void
    let onRevalidateSelection: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // A restore outlives the pane that started it, so its progress is
            // an app-level fact: this strip sits above every pane, and the
            // menu bar line covers the window-closed case. Switching panes
            // hands the progress over to this strip.
            RestoreProgressStrip()
            // The one disabled-state whose cause the user cannot see from the
            // panes themselves: every restic-backed control is grey, and this
            // is why. Built in place, not posted: the condition is the model's
            // state, so there is nothing to dismiss.
            if model.isResticDamaged, router.selection != nil {
                BannerView(
                    banner: Banner(title: ResticError.damagedInstall.localizedDescription, message: "", level: .error),
                    isDismissible: false
                )
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
                        PlanDetailView(planID: plan.id)
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
                        ContentUnavailableView("Backup location not found", systemImage: "questionmark.folder")
                    }
                case let .orphanPlan(repositoryID, planID):
                    OtherGroupView(
                        repositoryID: repositoryID,
                        groupID: .plan(planID),
                        onAdopt: { onAdoptGroup(repositoryID, $0) }
                    )
                case let .lineage(repositoryID, key):
                    OtherGroupView(
                        repositoryID: repositoryID,
                        groupID: .lineage(key),
                        onAdopt: { onAdoptGroup(repositoryID, $0) }
                    )
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
        // Search All Backups needs restic: a damaged one must move the
        // selection off it.
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
            VStack(spacing: 0) {
                let banners = model.banners
                ForEach(Array(banners.enumerated()), id: \.element.id) { index, banner in
                    BannerView(banner: banner)
                        .layoutPriority(Double(banners.count - index))
                }
            }
        }
    }
}

private struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    let onAddPlan: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("SwiftRestic")
            } icon: {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
            }
        } description: {
            Text(model.isResticDamaged
                ? ResticError.damagedInstall.localizedDescription
                : "Keep a copy of your folders on another disk or in the cloud.")
        } actions: {
            if !model.isResticDamaged {
                Button("Back Up a Folder…", action: onAddPlan)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier(AccessibilityID.Welcome.backUpAFolder)
            }
        }
    }
}

/// The restore strip: while a restore runs, its progress is a fact above
/// whatever surface is on screen, wired to the model's cancel. A restore
/// outlives the pane that started it, so the strip's home is the window's
/// detail column, above every pane; the panes add no copy of their own.
private struct RestoreProgressStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let progress = model.restoreActivity {
            OperationProgressView(
                title: title,
                progress: progress,
                onCancel: { model.cancelRestore() }
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    /// "Restoring…" stands in for an empty description: the strip has no
    /// other context to name the work.
    private var title: String {
        model.restoreDescription.isEmpty ? "Restoring…" : model.restoreDescription
    }
}
