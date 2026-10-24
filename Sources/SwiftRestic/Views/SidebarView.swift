import SwiftUI

/// The split view's sidebar: Activity, then each repository with its plans
/// always in view beneath it, then restic Console — two levels, the HIG's most for a sidebar
/// ("When a data hierarchy is deeper than two levels, consider using a
/// split view interface that includes a content list between the sidebar
/// items and detail view"). The repository's row opens its page, which is
/// its overview, and never collapses; beneath it sit its plans, "New Backup
/// Plan" while it has none, and — under an Other backups caption while the
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
/// Other backups caption is text, and "New Backup Plan" is an action.
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
    /// Opens the plan editor, with the repository preset when one is given.
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
            // The week's problem count, the Recent problems card's set;
            // computed once per body so the badge and that card agree.
            let problemCount = OverviewMetrics.problemCount(
                runs: model.configuration.runs,
                since: OverviewMetrics.problemWindowStart(from: now)
            )
            // First, above the repositories: its badge is every
            // repository's news and must not scroll away under a long tree.
            Section {
                Label("Activity", systemImage: "list.bullet.rectangle")
                    // The window's unread badge: the week's problems, as a
                    // repository page's Recent problems lists them — a
                    // backup failure its plan's next backup healed included,
                    // which the tray dot and the menu's problem line drop
                    // (`OverviewMetrics.isHealed`), in the same 7-day
                    // window. It also yields to the unconfigured state like
                    // the tray's problem face does — a removed repository's
                    // old failures must not summon setup-bound attention —
                    // and stays silent when clean.
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

            // Last: a power tool, a place rather than an action, so a row
            // and not a footer button (the user's call).
            Section {
                Label("restic Console", systemImage: "terminal")
                    .tag(SidebarItem.console)
                    .disabled(!model.repositoryCommands(for: router.selection).canOpenConsole)
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
                Button("New Backup Plan") { onNewPlan(model.commandRepositoryID(for: router.selection)) }
                Button("Add Repository") { onNewRepository() }
            } label: {
                Label("Add", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a backup plan or a repository")

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func planContextMenu(_ plan: BackupPlan) -> some View {
        let commands = model.planCommands(for: .plan(plan.id))
        // The plan card's swap, worded as the Plan menu's: a running plan's
        // row offers the Stop that matters now, not a second backup.
        if model.isRunning(planID: plan.id) {
            Button(commands.stopTitle) { model.cancelBackup(planID: plan.id) }
                .disabled(!commands.canStop)
        } else {
            Button("Back Up Now") { model.runBackup(planID: plan.id) }
                // The rule every Back Up Now follows, the menu bar's included:
                // enabled only for a complete, idle plan with restic to run it —
                // an error banner is not a substitute for a disabled item.
                .disabled(!commands.canBackUp)
        }
        Button("Edit Plan") { onEditPlan(plan) }
        // The Schedule card's pair, word for word. The row's caption says the
        // pause while the schedule is held; manual runs stay possible either
        // way, and a manual plan has no schedule to pause — no item either,
        // as the card has no control (the menu bar's Plan menu keeps its
        // dimmed item, a regular menu's place to say why).
        if !plan.isScheduleActive(at: .now) {
            Button("Resume Schedule") { model.resumePlanSchedule(id: plan.id) }
        } else if plan.schedule.frequency != .manual {
            Menu("Pause Schedule") {
                ForEach(PauseLength.allCases) { length in
                    Button(length.menuTitle) {
                        model.pausePlanSchedule(id: plan.id, for: length)
                    }
                }
            }
        }
        Button("Apply Retention Now") { router.request(.applyRetention(plan.id)) }
            .disabled(!commands.canApplyRetention)
        Divider()
        Button("Delete Plan", role: .destructive) { onDeletePlan(plan) }
    }

    @ViewBuilder
    private func repositoryContextMenu(_ repository: Repository) -> some View {
        let commands = model.repositoryCommands(for: .repository(repository.id))
        Button("New Backup Plan") { onNewPlan(repository.id) }
        Divider()
        Button("Edit Repository") { onEditRepository(repository) }
        Button("Refresh") { Task { await model.refreshSnapshots(repositoryID: repository.id) } }
        Divider()
        // The two of the Repository menu's a row most often wants; the
        // shared confirmations ask first.
        Button("Check") { router.request(.confirm(.check(repository.id))) }
            .disabled(!commands.canMaintain)
        Button("Clean Up Now") { router.request(.confirm(.prune(repository.id))) }
            .disabled(!commands.canMaintain)
        Divider()
        Button("Remove from SwiftRestic", role: .destructive) {
            onRemoveRepository(repository)
        }
    }

    // MARK: - Repository

    /// The trunk: Arq's storage-location row, the target of its page. It
    /// never folds — its children are the next level of the tree, always in
    /// view.
    private func repositoryRow(_ repository: Repository) -> some View {
        Label {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.label(of: repository))
                        .lineLimit(1)
                    backupsCaption(repository, listing: model.snapshots(for: repository.id))
                }
                Spacer(minLength: 4)
                attentionMark(repository)
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

    /// The repository row's second line: how many backups it holds, every
    /// plan's and the other ones together — but only once that is known. A
    /// repository still being read, or whose read failed (a wrong password,
    /// an unreachable server), never says "0 backups", which reads as "your
    /// data is gone"; it says what an open plan says — a repository missing
    /// from its location (restic exit 10, an unplugged disk) included. A
    /// count from an earlier listing stands under a failed re-read, as the
    /// records do.
    @ViewBuilder
    private func backupsCaption(_ repository: Repository, listing: [Snapshot]) -> some View {
        Group {
            if !listing.isEmpty {
                Text(Format.plural(listing.count, "backup"))
            } else if model.loadingSnapshots.contains(repository.id) {
                Text("Reading backups…")
            } else if case let .failed(message) = model.snapshotListingOutcome(for: repository.id) {
                // Under the repository's own name, its drive's absence needs
                // no name again: the sentence the listing wrote for it
                // (`RunRecord.notConnected`, the volume's name), matched as
                // that same derivation builds it — not the row's label,
                // which names a twin by its path.
                let line = Format.firstSentence(message)
                let away = repository.kind == .local ? RunRecord.notConnected([repository.resolvedLocalPath]) : nil
                Text(line.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == away ? "Not connected" : line)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(message)
            } else if model.snapshotListingOutcome(for: repository.id) == .loaded {
                Text(Format.plural(0, "backup"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// The warning a repository wears while one of its plans is not
    /// protected and should be — the rows its page's Protection line
    /// counts, read from the same derivation. With no page over every
    /// repository, this is where an unreadable repository shows at a
    /// glance: the badge and the menu bar count failed runs, and a wrong
    /// password fails none. A failed run's red octagon while a plan's last
    /// backup failed, as that plan's row wears it, else the triangle.
    /// The words stay with the rows; the mark only points at them.
    @ViewBuilder
    private func attentionMark(_ repository: Repository) -> some View {
        let rows = OverviewMetrics.needingAttention(
            model.protectionRows(for: model.plans(in: repository.id), now: now)
        )
        if !rows.isEmpty {
            let words = rows.map { "\($0.planName): \($0.stateText)" }.joined(separator: "\n")
            let outcome = OverviewMetrics.attentionOutcome(rows)
            Image(systemName: outcome.symbolName!)
                .imageScale(.small)
                .foregroundStyle(StatusPalette.status(outcome))
                .help(words)
                .accessibilityLabel(words)
        }
    }

    // MARK: - Children

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
                    Text("New Backup Plan")
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
        .help("Create a backup plan that backs up to “\(model.label(of: repository))”")
        // Every repository without a plan has one: the name tells them apart.
        .accessibilityLabel("New Backup Plan for “\(model.label(of: repository))”")
    }

    // MARK: - Plans

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

    // MARK: - Other backups

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
            switch group {
            case let .plan(id, snapshots):
                groupRow(
                    page: .orphanPlan(repositoryID: repository.id, planID: id),
                    label: labels[.plan(id)]!,
                    repository: repository
                )
                .contextMenu {
                    planGroupMenu(
                        planID: id, snapshots: snapshots, repository: repository,
                        formerPlan: shelves.formerPlan(of: group),
                        isAdoptable: shelves.adoptablePath(of: group, localHost: model.localHostname) != nil
                    )
                }
            case let .lineage(lineage):
                let page = SidebarItem.lineage(repositoryID: repository.id, key: lineage.key)
                // `otherLabels` labels every group it is given.
                groupRow(page: page, label: labels[.lineage(lineage.key)]!, repository: repository)
                    // Its backups and its files: no plan to open or adopt.
                    .contextMenu { showMenuItems(page, snapshots: lineage.snapshots, repository: repository) }
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

    /// A plan-UUID group's menu: an adoptable group's verb first, a moved
    /// plan's history opens that plan, and every group gets its way in —
    /// its page's Backups (a group's page has no Files tab).
    @ViewBuilder
    private func planGroupMenu(
        planID: UUID,
        snapshots: [Snapshot],
        repository: Repository,
        formerPlan: BackupPlan?,
        isAdoptable: Bool
    ) -> some View {
        if isAdoptable {
            Button("Adopt as a Backup Plan") {
                onAdoptGroup(repository.id, planID)
            }
        }
        if let formerPlan {
            Button("Show Plan") {
                router.selection = .plan(formerPlan.id)
            }
        }
        showMenuItems(.orphanPlan(repositoryID: repository.id, planID: planID), snapshots: snapshots, repository: repository)
    }

    /// Show Backups — the page's Backups tab, its newest backup open: the
    /// way into a group's backups from its row. A group's page has no Files
    /// tab, so no Show Files.
    @ViewBuilder
    private func showMenuItems(_ page: SidebarItem, snapshots: [Snapshot], repository: Repository) -> some View {
        Button("Show Backups") {
            router.showBackup(snapshots[0].id, on: page, repositoryID: repository.id)
        }
    }
}

/// A repository's children, as the leading indentation of top-level List
/// rows: plans, "New Backup Plan", the Other backups caption and its
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
        // the repository page's Protection line and the plan page agree
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
                HStack(spacing: 3) {
                    // The glyph carries the severity — red for a failed run
                    // (restic exit 1, no snapshot), orange for one that
                    // completed with errors (exit 3, an incomplete snapshot)
                    // — and the words stay in the secondary colour: orange
                    // caption text is too low-contrast on the light sidebar.
                    // Beside words that say it, the glyph is decoration to
                    // VoiceOver. The words, and which state wins the line,
                    // come from `PlanStatus.sidebarCaption`.
                    if let outcome = caption.outcome, let symbol = outcome.symbolName {
                        Image(systemName: symbol)
                            .imageScale(.small)
                            .foregroundStyle(StatusPalette.status(outcome))
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
                // A paused plan whose problem took the line above: the pause
                // gets its own, so neither state hides the other — on screen
                // or to VoiceOver.
                if let pauseNote = caption.pauseNote {
                    Text(pauseNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(pauseNote)
                }
            }
            // State trails identity, the sidebar's one reading rule —
            // Activity's badge follows it too. A trailing marker takes only
            // leftover space, so it can never push the title.
            Spacer(minLength: 0)
            marker
        }
    }

    /// A row wears state, never identity, and at its trailing edge,
    /// vertically centred on the row. In rank: the in-flight spinner,
    /// the Mail dot for a problem the user has not seen. A paused plan
    /// wears nothing — its caption already says "Paused — …" or
    /// "Paused until …".
    @ViewBuilder
    private var marker: some View {
        if model.isRunning(planID: plan.id) {
            ProgressView().controlSize(.small)
        } else if let label = model.unseenProblemLabel(for: plan.id) {
            // Accent blue like Mail's unread dot, never red: the dot is an
            // invitation ("a problem you haven't seen"), and the alarm lives
            // in the subtitle's glyph and words. It clears when the plan's
            // page is opened or the next run succeeds. Its label names the
            // outcome — a completed-with-errors run is not a failure.
            Circle()
                .fill(Theme.tint)
                .frame(width: 9, height: 9)
                .help(label)
                .accessibilityLabel(label)
        }
    }
}

/// What a page's Backups tab says while it lists no backup. "No backups
/// yet" only once a listing has succeeded: before that it is still being
/// read, and after a failure it says why. A plan's page offers its verb
/// under the words — the pane would otherwise hold nothing to do; a
/// group's page has no plan to run, so the words stand alone.
struct BackupsStatusRow: View {
    @Environment(AppModel.self) private var model
    let repositoryID: UUID
    /// The plan whose page this is, when Back Up Now is on offer.
    let planID: UUID?

    var body: some View {
        let outcome = model.snapshotListingOutcome(for: repositoryID)
        if model.loadingSnapshots.contains(repositoryID) || outcome == .idle {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading backups…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if case let .failed(message) = outcome {
            VStack(alignment: .leading, spacing: 4) {
                // Orange only on the glyph, the words secondary — the
                // plan rows' contrast rule.
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                        .foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                    Text(Format.firstSentence(message))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .font(.caption)
                Button("Try Again") {
                    Task { await model.refreshSnapshots(repositoryID: repositoryID) }
                }
                .controlSize(.small)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // A plan's page says which kind of empty this is, as the
                // Overview card's count line does; a group's page, or a
                // repository with nothing of anyone's, the plain fact.
                Text(
                    planID != nil && !model.snapshots(for: repositoryID).isEmpty
                        ? PlanStatus.noneFromThisPlanFact
                        : "No backups yet"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                if let planID {
                    Button("Back Up Now") { model.runBackup(planID: planID) }
                        // The rule every Back Up Now follows.
                        .disabled(!model.planCommands(for: .plan(planID)).canBackUp)
                        .controlSize(.small)
                }
            }
        }
    }
}
