import SwiftUI

/// The split view's sidebar: Activity, then each repository with its plans
/// always in view beneath it — two levels, the HIG's most for a sidebar
/// ("When a data hierarchy is deeper than two levels, consider using a
/// split view interface that includes a content list between the sidebar
/// items and detail view"). The repository's row opens its page, which is
/// its overview, and never collapses; beneath it sit its plans, "Back Up a
/// Folder" while it has none, and — under an Other backups caption while the
/// repository holds backups none of its plans made (`BackupShelves`) — their
/// groups, by the plan that made them when a plan tag says which, by folders
/// and Mac otherwise. A plan's or a group's row is a page whose Backups tab
/// lists its backups beside the one open: the content list, not a fold
/// here a year of rows deep. The context menus and the Add footer ride
/// along.
///
/// Every row is a top-level List row, and a repository's children are
/// leading indentation (`Indent`). Only places carry a tag — a repository,
/// a plan, a group under Other backups — so selection stays unique; the
/// Other backups caption is text, and "Back Up a Folder" is an action.
///
/// The sidebar's list is its own view so it type-checks on its own: the
/// root's modifier chain sits at the compiler's type-check budget. The
/// sheet and deletion intents the sidebar raises are passed back as
/// closures — the presenting state stays in `RootView` — and, for the same
/// budget, each row kind is its own function.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.now) private var now

    /// Taken back by a click in the sidebar (`focusOnClick`), once a click
    /// in a page's list has taken it away.
    @FocusState private var isFocused: Bool

    let onEditPlan: (BackupPlan) -> Void
    let onNewPlan: (_ repositoryID: UUID?) -> Void
    let onEditRepository: (Repository) -> Void
    let onNewRepository: () -> Void
    /// Arms the shared deletion confirmation — the sidebar's menus must not
    /// be a faster way around it.
    let onDeletePlan: (BackupPlan) -> Void
    let onRemoveRepository: (Repository) -> Void
    /// Opens the adopt sheet for an adoptable group's menu. The sidebar
    /// raises its sheets through the root, which owns the presenting state.
    let onAdoptGroup: (_ repositoryID: UUID, _ planID: UUID) -> Void

    var body: some View {
        List(selection: Binding(
            get: { router.selection },
            set: { router.selection = $0 }
        )) {
            let problemCount = model.activityBadgeCount(now: now)
            // First, above the repositories: its badge is every
            // repository's news and must not scroll away under a long tree.
            Section {
                Label("Activity", systemImage: "list.bullet.rectangle")
                    // The window's unread badge (`activityBadgeCount`). It
                    // yields to the unconfigured state like the tray's problem
                    // face does —
                    // a removed repository's old failures must not summon
                    // setup-bound attention — and stays silent when clean.
                    .badge(
                        problemCount > 0 && !model.configuration.repositories.isEmpty
                            ? Text(verbatim: "\(problemCount)")
                            : nil
                    )
                    // The tag must come after the badge: with .tag inside
                    // .badge — a nil badge too — neither a click nor
                    // Accessibility can select the row. .disabled and
                    // .contextMenu after .tag do no such harm.
                    .tag(SidebarItem.activity)
            }

            Section {
                ForEach(model.configuration.repositories) { repository in
                    let shelves = model.shelves(for: repository.id)
                    repositoryRow(repository)
                    ForEach(
                        SidebarTree.children(
                            of: repository.id,
                            in: model.configuration.plans,
                            hasOtherBackups: shelves.hasOtherBackups
                        ),
                        id: \.self
                    ) { child in
                        childRows(child, of: repository, shelves: shelves)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .focusOnClick($isFocused)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    /// Arq's bare + in the corner; actions only, every page is a row. A
    /// missing restic is not repeated here: the
    /// banner above every pane (RootDetailView) already says it, with the
    /// install instruction a cursor-only triangle could not show. The bar
    /// background stays — a long list scrolls under it.
    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Menu {
                // Into the repository on screen, as ⌘N does — with none
                // yet, through adding one.
                let commands = model.repositoryCommands(for: router.selection)
                Button("Back Up a Folder…") { onNewPlan(model.commandRepositoryID(for: router.selection)) }
                    .disabled(!commands.canNewPlan)
                Button("Add Backup Location…") { onNewRepository() }
                    .disabled(!commands.canAddRepository)
            } label: {
                Label("Add", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Back up a folder or add a backup location")

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func planContextMenu(_ plan: BackupPlan) -> some View {
        let commands = model.planCommands(for: .plan(plan.id))
        // The plan page's swap, worded as the Backup menu's: a running plan's
        // row offers the Stop that matters now, not a second backup.
        // A context menu leaves out what can't run (HIG: "Hide unavailable
        // menu items, don't dim them"); the Backup menu keeps its dimmed
        // items, a regular menu's place to say why.
        if model.isRunning(planID: plan.id) {
            if commands.canStop {
                Button(commands.stopTitle) { model.cancelBackup(planID: plan.id) }
            }
        } else if commands.canBackUp {
            Button("Back Up Now") { model.runBackup(planID: plan.id) }
        }
        Button("Edit Plan…") { onEditPlan(plan) }
        Divider()
        Button("Remove Plan…", role: .destructive) { onDeletePlan(plan) }
    }

    @ViewBuilder
    private func repositoryContextMenu(_ repository: Repository) -> some View {
        let commands = model.repositoryCommands(for: .repository(repository.id))
        Button("Back Up a Folder…") { onNewPlan(repository.id) }
        Divider()
        Button("Edit Backup Location…") { onEditRepository(repository) }
        // Left out, not dimmed, while it can't run, as the plan row's
        // commands.
        if commands.canMaintain {
            Divider()
            Button("Verify Backups") { router.request(.verifyBackups(repository.id)) }
        }
        Divider()
        Button("Remove from SwiftRestic…", role: .destructive) {
            onRemoveRepository(repository)
        }
    }

    /// The trunk: Arq's storage-location row, the target of its page. It
    /// never folds — its children are the next level of the tree, always in
    /// view.
    private func repositoryRow(_ repository: Repository) -> some View {
        Label {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.label(of: repository))
                        .lineLimit(1)
                    readProblem(repository)
                }
                Spacer(minLength: 4)
            }
        } icon: {
            // The sidebar's own icon tint, as on Activity: it turns white
            // under the selection, where an explicit accent vanished into
            // the selection's blue.
            Image(systemName: repository.kind.symbolName)
        }
        .tag(SidebarItem.repository(repository.id))
        .contextMenu { repositoryContextMenu(repository) }
    }

    /// The repository row's second line, only when its last read failed:
    /// "not connected", or the failure's first sentence, its whole message
    /// in the tooltip.
    @ViewBuilder
    private func readProblem(_ repository: Repository) -> some View {
        let caption = PlanStatus.repositoryCaption(outcome: model.snapshotListingOutcome(for: repository.id))
        if let caption {
            HStack(spacing: 3) {
                // The plan rows' glyph; the words stay secondary, as theirs.
                // A disk not connected is a normal state and wears none.
                if case .failed = caption {
                    StatusGlyph(outcome: .completedWithErrors)
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                Text(caption.text)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(caption.help)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func childRows(_ child: SidebarChild, of repository: Repository, shelves: BackupShelves) -> some View {
        switch child {
        case let .plan(id):
            if let plan = model.plan(id: id) {
                // The newest snapshot from the plan's own shelf — one
                // dictionary hit — rather than re-filtering the repository's
                // whole listing inside the row, whose body re-runs on every
                // minute tick and selection change.
                planRow(plan, latestSnapshot: shelves.byPlan[plan.id]?.first)
            }
        case .addPlan:
            addPlanRow(repository)
        case .otherBackups:
            otherBackupsCaption(repository, shelves: shelves)
            otherBackups(repository, shelves: shelves)
        }
    }

    /// The way to a repository's first plan, where its plans would be. An
    /// action, not a place: no tag, its title tinted, no icon — buttons
    /// wear none (the user's call). The hidden symbol
    /// holds the icon column, so its title starts where plan names do. It
    /// leaves once a plan exists; the footer's + and the row's menu keep
    /// offering the next one.
    private func addPlanRow(_ repository: Repository) -> some View {
        Button { onNewPlan(repository.id) } label: {
            HStack(spacing: 4) {
                Label {
                    Text("Back Up a Folder…")
                        .foregroundStyle(Theme.tint)
                } icon: {
                    Image(systemName: "plus.circle")
                        .hidden()
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, Indent.child)
        .help("Back up a folder to “\(model.label(of: repository))”")
        // Every repository without a plan has one: the name tells them apart.
        .accessibilityLabel("Back Up a Folder to “\(model.label(of: repository))”")
    }

    /// A plan: the row opens its page, whose Backups tab lists what it
    /// made here. A plan is its folder and wears one; a file wears it too,
    /// decoration whose SF label ("Move") would only mislead. The row pads
    /// by `child` and the folder fills the icon column, so the plan's title
    /// starts where every repository child's does.
    private func planRow(_ plan: BackupPlan, latestSnapshot: Snapshot?) -> some View {
        // A Label, so the folder takes the sidebar's icon tint as the
        // repository's icon does: grey in an inactive window, white under
        // the selection, where an explicit accent would vanish.
        Label {
            PlanSidebarRow(plan: plan, latestSnapshot: latestSnapshot)
        } icon: {
            Image(systemName: "folder.fill")
                .accessibilityHidden(true)
        }
        .padding(.leading, Indent.child)
        .tag(SidebarItem.plan(plan.id))
        .contextMenu { planContextMenu(plan) }
    }

    /// The caption over the backups in the repository none of its plans
    /// made — another Mac's, the console's, a deleted plan's, or a plan's
    /// that now backs up elsewhere. Only there while it holds some, so it
    /// never reads as empty. Text, not a level: no tag, no fold — the
    /// groups under it sit at the plans' level, as a list's month captions
    /// stand over its rows.
    private func otherBackupsCaption(_ repository: Repository, shelves: BackupShelves) -> some View {
        let title = SidebarTree.otherBackupsTitle(repositoryHasPlans: !shelves.plans.isEmpty)
        // The count stays for VoiceOver; on screen each group's row says
        // its own.
        let count = Format.plural(shelves.otherBackupsCount, "backup")
        return Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, Indent.child)
            .padding(.top, 4)
            .help("Backups in “\(model.label(of: repository))” that none of its plans made")
            // Named for its repository: every repository can have one.
            .accessibilityLabel("\(title) in “\(model.label(of: repository))”, \(count)")
            .accessibilityAddTraits(.isHeader)
    }

    /// Both kinds of group, interleaved newest-first: a plan's history here
    /// that none of the repository's plans owns, and the backups no plan
    /// made — which, unlike a plan's, have no name above them to say what
    /// they are.
    @ViewBuilder
    private func otherBackups(_ repository: Repository, shelves: BackupShelves) -> some View {
        let labels = shelves.otherLabels(
            repositories: model.configuration.repositories, localHost: model.localHostname
        )
        ForEach(shelves.others) { group in
            // One factory for either kind's page; the switch is only about
            // the menus, which need the kind's own pieces.
            let page = SidebarItem.otherGroup(repositoryID: repository.id, id: group.id)
            switch group {
            case let .plan(id, _):
                groupRow(
                    page: page,
                    label: labels[group.id]!,
                    repository: repository
                )
                .contextMenu {
                    if shelves.adoptablePath(of: group, localHost: model.localHostname) != nil {
                        Button("Continue Backups…") { onAdoptGroup(repository.id, id) }
                    }
                }
            case .lineage:
                // `otherLabels` labels every group it is given.
                groupRow(page: page, label: labels[group.id]!, repository: repository)
            }
        }
    }

    /// One group under Other backups, either kind — a plan's history in
    /// this repository that none of its plans owns, or the backups of one
    /// Mac's folders that no plan made. A page, a plan row's grammar: the
    /// row selects, and its page lists the group's backups. Its box sits in
    /// the icon column, so its title starts where plan names do; the
    /// label's caption says which kind it is, and its tooltip keeps the
    /// folders and the Mac.
    private func groupRow(
        page: SidebarItem,
        label: SnapshotLineage.Label,
        repository: Repository
    ) -> some View {
        let title = label.title
        // `OtherBackupsGroup.labels` gives every group's label a caption.
        let caption = label.caption!
        return Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                GroupCaptionLine(caption: caption)
            }
        } icon: {
            Image(systemName: "archivebox")
                .accessibilityHidden(true)
        }
        .padding(.leading, Indent.child)
        .tag(page)
        .help(label.detail)
        // The same plan, or the same folders from the same Mac, can have
        // left backups in two repositories.
        .accessibilityLabel("\(title), \(caption.text), in “\(model.label(of: repository))”")
    }

}

/// A repository's children, as the leading indentation of top-level List
/// rows: plans, "Back Up a Folder", the Other backups caption and its
/// groups all start one step in, their icons under the repository's icon
/// and their titles where its title starts.
private enum Indent {
    static let child: CGFloat = 12
}

/// An Other backups group's second line. The count and the kind always read
/// whole; the qualifiers between them are the piece that yields — all of
/// them when the line fits, none of them when it does not, never a
/// mid-word fragment (the row's tooltip keeps the folders and the Mac), as
/// FilesTreeRow yields its tag to the name.
private struct GroupCaptionLine: View {
    let caption: SnapshotLineage.Label.Caption

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                Text(caption.count)
                if !caption.qualifiers.isEmpty {
                    Text(" · " + caption.qualifiers.joined(separator: " · "))
                }
                if !caption.kind.isEmpty {
                    Text(" · " + caption.kind.joined(separator: " · "))
                }
            }
            HStack(spacing: 0) {
                Text(caption.count)
                if !caption.kind.isEmpty {
                    Text(" · " + caption.kind.joined(separator: " · "))
                }
            }
        }
        .lineLimit(1)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct PlanSidebarRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.now) private var now
    let plan: BackupPlan
    /// The plan's newest snapshot, from the plan's own shelf. It is what
    /// the moment falls back to when the app never ran the plan: history
    /// adopted with the repository counts as its last backup.
    let latestSnapshot: Snapshot?

    var body: some View {
        // As of the window's minute clock, and counting from the one moment
        // every surface's "Last backup" reads (PlanStatus.lastBackupAt) —
        // the repository page's Status line and the plan page agree
        // with this row by construction.
        let caption = PlanStatus.sidebarCaption(
            for: plan,
            activity: model.activity[plan.id],
            isQueued: model.isQueued(plan.id),
            problem: model.currentProblem(for: plan.id),
            latestSnapshot: latestSnapshot,
            existingRepositoryIDs: Set(model.configuration.repositories.map(\.id)),
            now: now,
            relative: { Format.ago($0, now: now) }
        )
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                // A plan is its path; the row shows its label and keeps the
                // path for the tooltip, the rows staying one line each.
                Text(model.label(of: plan))
                    .lineLimit(1)
                    .help((plan.path as NSString).abbreviatingWithTildeInPath)
                if let caption {
                    captionLine(caption)
                }
            }
            // State trails identity, the sidebar's one reading rule —
            // Activity's badge follows it too. A trailing marker takes only
            // leftover space, so it can never push the title.
            Spacer(minLength: 0)
            marker
        }
    }

    private func captionLine(_ caption: PlanCaption) -> some View {
        HStack(spacing: 3) {
            // The words stay secondary: orange caption text is too
            // low-contrast on the light sidebar.
            if let outcome = caption.outcome {
                StatusGlyph(outcome: outcome)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            // The whole line when it fits, its shorter spelling when
            // one exists ("Warnings — 2 days ago"), and only then the
            // middle cut: the trailing marker narrows the column,
            // and a tail cut would take "ago" — when it happened.
            // The tooltip and VoiceOver keep the whole line.
            Group {
                if let shortText = caption.shortText {
                    ViewThatFits(in: .horizontal) {
                        Text(caption.text)
                        Text(shortText)
                        Text(caption.text)
                            .truncationMode(.middle)
                    }
                } else {
                    Text(caption.text)
                        .truncationMode(.middle)
                }
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(caption.text)
            .accessibilityLabel(caption.text)
        }
        .font(.caption)
    }

    @ViewBuilder
    private var marker: some View {
        if model.isRunning(planID: plan.id) {
            ProgressView().controlSize(.small)
        }
    }
}

