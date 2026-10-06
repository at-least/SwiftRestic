import SwiftUI

/// The split view's sidebar: each repository with its plans always in view
/// beneath it, then Activity. The repository's row opens its page, which is
/// its overview, and never collapses; beneath it sit its plans — each folds
/// open to the dated backups it made there — "New Backup Plan…" while it has
/// none, and Other backups while the repository holds backups none of its
/// plans made (`BackupShelves`), grouped by the plan that made them when a
/// plan tag says which, by folders and Mac otherwise. A group's row, either
/// kind, is a page like a plan's is — the row selects, the chevron ahead of
/// it folds — while the Other backups node stays a fold only. The context
/// menus and the Add footer ride along.
///
/// Every row is a top-level List row, and the tree's levels are leading
/// indentation (`Indent`): a DisclosureGroup draws its triangle at the
/// row's outer edge, which an indented child would leave stranded far to
/// the left of its title. Only places carry a tag — a repository, a plan,
/// a group under Other backups, a backup record — so selection stays
/// unique; a plan's or a group's chevron and the Other backups node are
/// folds, and "New Backup Plan…" is an action.
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

    /// Which plans and Other backups are open — the backup records
    /// underneath are the restore pane's entry points. Shared with the detail
    /// column: selecting a record from anywhere must find its fold open.
    @Binding var folds: SidebarFolds

    /// Untagged lineage groups under Other backups that the user folded
    /// shut. They start open, as Arq's tree does, and a record selected from
    /// anywhere reopens its group — the promise `folds` keeps one level up.
    /// The plan-UUID groups follow the plan folds' syntax instead: closed
    /// until opened, in `folds.otherGroups`.
    @State private var collapsedLineages: Set<LineageFoldID> = []
    /// Taken back by a click in the sidebar (`focusOnClick`), once a click
    /// in the restore tree has taken it away.
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

            // Header-less: one row needs no title above it. The restic
            // console has no row — it is a power tool, reached from
            // Repository ▸ restic Console….
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
        }
        .listStyle(.sidebar)
        .focusOnClick($isFocused)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
        // The keyboard an outline gives its disclosure rows: with a plan or
        // a plan-UUID group selected, → shows its backups and ← hides them.
        // Plain arrows only: a modified arrow keeps its system meaning, the
        // restore pane's rule for its own folds.
        .onKeyPress(.rightArrow, phases: .down) { press in
            isPlain(press) ? foldSelection(open: true) : .ignored
        }
        .onKeyPress(.leftArrow, phases: .down) { press in
            isPlain(press) ? foldSelection(open: false) : .ignored
        }
        .onChange(of: router.selection) {
            // A lineage's fold is the sidebar's own view state, so an
            // unowned record with no plan tag reopens it here; plan-UUID
            // groups reopen through RootDetailView's SidebarFolds.reveal on
            // the same change (a plan's record must not reopen a lineage,
            // and a tagged record's group is a plan fold, closed until
            // opened).
            guard case let .restoreSnapshot(repositoryID, snapshotID) = router.selection,
                  let snapshot = model.snapshots(for: repositoryID).first(where: { $0.id == snapshotID }),
                  snapshot.planID == nil,
                  BackupShelves.owner(of: snapshot, among: model.plans(in: repositoryID)) == nil
            else { return }
            collapsedLineages.remove(LineageFoldID(repositoryID: repositoryID, key: snapshot.lineageKey))
        }
    }

    /// Arq's bare + in the corner. A missing restic is not repeated here: the
    /// banner above every pane (RootDetailView) already says it, with the
    /// install instruction a cursor-only triangle could not show. The bar
    /// background stays — an open fold scrolls under it.
    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Menu {
                // Into the repository on screen, as ⌘N does.
                Button("New Backup Plan…") { onNewPlan(model.commandRepositoryID(for: router.selection)) }
                    .disabled(model.configuration.repositories.isEmpty)
                Button("Add Repository…") { onNewRepository() }
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
        Button("Back Up Now") { model.runBackup(planID: plan.id) }
            // The rule every Back Up Now follows, the menu bar's included:
            // enabled only for a complete, idle plan with restic to run it —
            // an error banner is not a substitute for a disabled item.
            .disabled(!commands.canBackUp)
        Button("Edit…") { onEditPlan(plan) }
        // The Schedule card's pair, word for word. The row's caption says the
        // pause while the schedule is held; manual runs stay possible either
        // way, and a manual plan has no schedule to pause.
        if !plan.isScheduleActive(at: .now) {
            Button("Resume Schedule") { model.resumePlanSchedule(id: plan.id) }
        } else if plan.schedule.frequency == .manual {
            Button("Pause Schedule") {}
                .disabled(true)
        } else {
            Menu("Pause Schedule") {
                ForEach(PauseLength.allCases) { length in
                    Button(length.menuTitle) {
                        model.pausePlanSchedule(id: plan.id, for: length)
                    }
                }
            }
        }
        Button("Apply Retention Now…") { router.request(.applyRetention(plan.id)) }
            .disabled(!commands.canApplyRetention)
        Divider()
        Button("Delete Plan…", role: .destructive) { onDeletePlan(plan) }
    }

    @ViewBuilder
    private func repositoryContextMenu(_ repository: Repository) -> some View {
        let commands = model.repositoryCommands(for: .repository(repository.id))
        Button("New Backup Plan…") { onNewPlan(repository.id) }
        Divider()
        Button("Edit…") { onEditRepository(repository) }
        Button("Refresh") { Task { await model.refreshSnapshots(repositoryID: repository.id) } }
        Divider()
        // The two the pane and the menu bar offer that a row most often
        // wants; the shared confirmations ask first.
        Button("Check…") { router.request(.confirm(.check(repository.id))) }
            .disabled(!commands.canMaintain)
        Button("Prune Now…", role: .destructive) { router.request(.confirm(.prune(repository.id))) }
            .disabled(!commands.canMaintain)
        Divider()
        Button("Remove from SwiftRestic…", role: .destructive) {
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
                    Text(repository.name)
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
                Text(Format.firstSentence(message))
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
    /// password fails none.
    /// The words stay with the rows; the mark only points at them.
    @ViewBuilder
    private func attentionMark(_ repository: Repository) -> some View {
        let rows = OverviewMetrics.needingAttention(
            model.protectionRows(for: model.plans(in: repository.id), now: now)
        )
        if !rows.isEmpty {
            let words = rows.map { "\($0.planName): \($0.stateText)" }.joined(separator: "\n")
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.small)
                .foregroundStyle(Theme.warning)
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
                // The newest snapshot from the same shelf the fold below
                // shows — one dictionary hit — rather than re-filtering the
                // repository's whole listing inside the row, whose body
                // re-runs on every minute tick and selection change.
                planRow(plan, latestSnapshot: shelves.byPlan[plan.id]?.first)
                if folds.plans.contains(plan.id) {
                    planBackups(shelves.byPlan[plan.id] ?? [], in: repository)
                }
            }
        case .addPlan:
            addPlanRow(repository)
        case .otherBackups:
            otherBackupsRow(repository, shelves: shelves)
            if folds.otherBackups.contains(repository.id) {
                otherBackups(repository, shelves: shelves)
            }
        }
    }

    /// The way to a repository's first plan, where its plans would be. An
    /// action, not a place: no tag, no chevron — its plus fills the fold
    /// column, so its title starts where plan names do. It leaves once a
    /// plan exists; the footer's + and the row's menu keep offering the
    /// next one.
    private func addPlanRow(_ repository: Repository) -> some View {
        Button { onNewPlan(repository.id) } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(Theme.tint)
                    .frame(width: Indent.fold)
                    .accessibilityHidden(true)
                Text("New Backup Plan…")
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, Indent.child)
        .help("Create a backup plan that backs up to “\(repository.name)”")
        // Every repository without a plan has one: the name tells them apart.
        .accessibilityLabel("New Backup Plan for “\(repository.name)”…")
    }

    // MARK: - Plans

    /// A plan: the row opens its page, and the chevron ahead of it folds
    /// the plan's backups open beneath it — Arq's RESTORE tree, where a
    /// backup plan's records sit under the plan. The row pads by `child`
    /// and the chevron fills the shared fold column, so the plan's title
    /// starts where every repository child's does.
    private func planRow(_ plan: BackupPlan, latestSnapshot: Snapshot?) -> some View {
        HStack(spacing: 4) {
            planFold(plan)
            PlanSidebarRow(plan: plan, latestSnapshot: latestSnapshot)
        }
        .padding(.leading, Indent.child)
        .tag(SidebarItem.plan(plan.id))
        .contextMenu { planContextMenu(plan) }
    }

    private func planFold(_ plan: BackupPlan) -> some View {
        let isExpanded = folds.plans.contains(plan.id)
        return Button { togglePlan(plan) } label: {
            FoldChevron(isExpanded: isExpanded)
                .frame(width: Indent.fold)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(planFoldHelp(isExpanded: isExpanded))
        .accessibilityLabel(planFoldName(plan))
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private func planFoldHelp(isExpanded: Bool) -> String {
        isExpanded ? "Hide this plan's backups" : "Show this plan's backups"
    }

    /// Named for its plan: every plan has a fold, and as flat rows they
    /// have no outline parent to tell them apart.
    private func planFoldName(_ plan: BackupPlan) -> String {
        "Backups of “\(plan.displayName)”"
    }

    private func isPlain(_ press: KeyPress) -> Bool {
        press.modifiers.isDisjoint(with: [.command, .option, .control, .shift])
    }

    /// The keyboard fold for whatever selectable row holds a fold: a plan,
    /// or a group under Other backups. Other rows ignore the key.
    private func foldSelection(open: Bool) -> KeyPress.Result {
        switch router.selection {
        case let .plan(id):
            guard let plan = model.plan(id: id) else { return .ignored }
            if open != folds.plans.contains(id) { togglePlan(plan) }
            return .handled
        case let .orphanPlan(repositoryID, planID):
            // The group's title, by the same label derivation the row read
            // it from — also how a selection the shelves no longer hold is
            // told apart from one to fold.
            guard let title = model.shelves(for: repositoryID)
                .otherLabels(repositories: model.configuration.repositories, localHost: model.localHostname)[.plan(planID)]?.title
            else { return .ignored }
            let id = OtherGroupFoldID(repositoryID: repositoryID, planID: planID)
            if open != folds.otherGroups.contains(id) { toggleOtherGroup(id, title: title) }
            // The group's rows render only inside the repository's Other
            // backups node, so opening one whose node is folded shut would
            // move a fold nobody can see — reveal the node too, the same
            // reveal a record's selection performs.
            if open { folds.otherBackups.insert(repositoryID) }
            return .handled
        case let .lineage(repositoryID, key):
            guard let title = model.shelves(for: repositoryID)
                .otherLabels(repositories: model.configuration.repositories, localHost: model.localHostname)[.lineage(key)]?.title
            else { return .ignored }
            let id = LineageFoldID(repositoryID: repositoryID, key: key)
            // Open is "not folded shut": a lineage starts open.
            if open == collapsedLineages.contains(id) { toggleLineage(id, title: title) }
            if open { folds.otherBackups.insert(repositoryID) }
            return .handled
        default:
            return .ignored
        }
    }

    /// The first opening loads the record list; later refreshes come from
    /// the launch sweep and the repository's own Refresh.
    /// Spoken when it folds, as a disclosure row was: the fold is a button,
    /// whose changed value VoiceOver does not read out by itself.
    private func togglePlan(_ plan: BackupPlan) {
        let opened = folds.plans.remove(plan.id) == nil
        if opened {
            folds.plans.insert(plan.id)
            if let repositoryID = plan.repositoryID, model.snapshotListingOutcome(for: repositoryID) == .idle {
                Task { await model.refreshSnapshots(repositoryID: repositoryID) }
            }
        }
        announceFold(planFoldName(plan), opened: opened)
    }

    private func announceFold(_ name: String, opened: Bool) {
        AccessibilityNotification.Announcement("\(name) \(opened ? "expanded" : "collapsed")").post()
    }

    /// An open plan's backups, newest first — flat, even when the plan's
    /// folders changed: each record's Change column still compares within
    /// its own folders, and the restore pane's header says which.
    @ViewBuilder
    private func planBackups(_ records: [Snapshot], in repository: Repository) -> some View {
        if records.isEmpty {
            BackupsStatusRow(repositoryID: repository.id)
                .padding(.leading, Indent.planRecord)
        } else {
            ForEach(records) { snapshot in
                RestoreRecordRow(snapshot: snapshot, run: model.backupRun(forSnapshot: snapshot.id))
                    .padding(.leading, Indent.planRecord)
                    .tag(SidebarItem.restoreSnapshot(repository.id, snapshot.id))
            }
        }
    }

    // MARK: - Other backups

    /// The backups in the repository none of its plans made — another
    /// Mac's, the console's, a deleted plan's, or a plan's that now backs up
    /// elsewhere. Only there while it holds some, so it never reads as
    /// empty; it carries no tag, so a click only folds it. Its chevron sits
    /// where a plan's does, so its title starts where plan names do.
    private func otherBackupsRow(_ repository: Repository, shelves: BackupShelves) -> some View {
        let isExpanded = folds.otherBackups.contains(repository.id)
        let title = SidebarTree.otherBackupsTitle(repositoryHasPlans: !shelves.plans.isEmpty)
        // The one count every surface reads — the page's Protection line,
        // its Other backups card and its Snapshots split included.
        let count = Format.plural(shelves.otherBackupsCount, "backup")
        return Button { toggleOtherBackups(repository, title: title) } label: {
            HStack(spacing: 4) {
                FoldChevron(isExpanded: isExpanded)
                    .frame(width: Indent.fold)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                    Text(count)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, Indent.child)
        .help("Backups in “\(repository.name)” that none of its plans made — from another Mac or the restic console, a deleted plan, or a plan that now backs up elsewhere")
        // Named for its repository, as a plan's fold is for its plan.
        .accessibilityLabel("\(title) in “\(repository.name)”, \(count)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private func toggleOtherBackups(_ repository: Repository, title: String) {
        let opened = folds.otherBackups.remove(repository.id) == nil
        if opened { folds.otherBackups.insert(repository.id) }
        announceFold("\(title) in “\(repository.name)”", opened: opened)
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
                planGroupRows(
                    id: id,
                    snapshots: snapshots,
                    label: labels[.plan(id)],
                    repository: repository,
                    formerPlan: shelves.formerPlan(of: group)
                )
            case let .lineage(lineage):
                lineageRows(lineage, label: labels[.lineage(lineage.key)], repository: repository)
            }
        }
    }

    /// One plan's history in this repository that none of the repository's
    /// plans owns — a deleted plan's, or a plan that now backs up elsewhere.
    /// A page, the plan row's own grammar: the row selects, the chevron
    /// ahead of it folds, and its records sit one fold-step under its
    /// title, the way a plan's sit under it, so the group reads as the
    /// plan's history and not a folder's. The label's caption and tooltip
    /// say which of the three kinds it is.
    @ViewBuilder
    private func planGroupRows(
        id planID: UUID,
        snapshots: [Snapshot],
        label: SnapshotLineage.Label?,
        repository: Repository,
        formerPlan: BackupPlan?
    ) -> some View {
        let id = OtherGroupFoldID(repositoryID: repository.id, planID: planID)
        let isExpanded = folds.otherGroups.contains(id)
        let title = label?.title ?? "Backups"
        let caption = label?.caption ?? .init(count: Format.plural(snapshots.count, "backup"))
        HStack(spacing: 4) {
            groupFold(title: title, isExpanded: isExpanded) { toggleOtherGroup(id, title: title) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                GroupCaptionLine(caption: caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, Indent.groupPad)
        .tag(SidebarItem.orphanPlan(repositoryID: repository.id, planID: planID))
        .help(label?.detail ?? "")
        .contextMenu {
            groupContextMenu(planID: planID, snapshots: snapshots, repository: repository, formerPlan: formerPlan)
        }
        // The same plan can have left backups in two repositories.
        .accessibilityLabel("\(title), \(caption.text), in “\(repository.name)”")
        if isExpanded {
            ForEach(snapshots) { snapshot in
                RestoreRecordRow(snapshot: snapshot, run: model.backupRun(forSnapshot: snapshot.id))
                    .padding(.leading, Indent.groupRecord)
                    .tag(SidebarItem.restoreSnapshot(repository.id, snapshot.id))
            }
        }
    }

    /// A group's fold, either kind, the plan fold's own grammar: a chevron
    /// column that toggles, named for what it holds.
    private func groupFold(title: String, isExpanded: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            FoldChevron(isExpanded: isExpanded)
                .frame(width: Indent.lineageSlot)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(groupFoldHelp(isExpanded: isExpanded))
        .accessibilityLabel("Backups of “\(title)”")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private func groupFoldHelp(isExpanded: Bool) -> String {
        isExpanded ? "Hide this group's backups" : "Show this group's backups"
    }

    /// The plan folds' open/closed idiom, for a group under Other backups.
    private func toggleOtherGroup(_ id: OtherGroupFoldID, title: String) {
        let opened = folds.otherGroups.remove(id) == nil
        if opened { folds.otherGroups.insert(id) }
        announceFold(title, opened: opened)
    }

    /// A lineage's fold: open unless the user folded it shut.
    private func toggleLineage(_ id: LineageFoldID, title: String) {
        let opened = collapsedLineages.remove(id) != nil
        if !opened { collapsedLineages.insert(id) }
        announceFold(title, opened: opened)
    }

    /// A plan-UUID group's menu: an adoptable group's verb first, a moved
    /// plan's history opens that plan, and every group gets its two ways in
    /// — its newest backup, and its page's Files.
    @ViewBuilder
    private func groupContextMenu(
        planID: UUID,
        snapshots: [Snapshot],
        repository: Repository,
        formerPlan: BackupPlan?
    ) -> some View {
        if formerPlan == nil {
            Button("Adopt as a Backup Plan…") {
                onAdoptGroup(repository.id, planID)
            }
        }
        if let formerPlan {
            Button("Open the “\(formerPlan.displayName)” Plan") {
                router.selection = .plan(formerPlan.id)
            }
        }
        restoreFromGroupItem(snapshots, repository: repository)
        Button("Show Files") {
            router.showFiles(of: .orphanPlan(repositoryID: repository.id, planID: planID))
        }
    }

    /// Restore Files…, the one entry an untagged lineage's menu has — and
    /// the group row's other one: the history's newest record, selected in
    /// the sidebar, which opens the fold it sits in. A group exists only
    /// around backups, so it always has a newest one.
    private func restoreFromGroupItem(_ snapshots: [Snapshot], repository: Repository) -> some View {
        Button("Restore Files…") {
            router.showRestore(repositoryID: repository.id, snapshotID: snapshots[0].id)
        }
    }

    /// One lineage's records — Arq's backed-up-folder level, so the row
    /// below a record is the one its Change column compares against. A
    /// page, the plan-UUID group's grammar: the row selects, the chevron ahead of it folds —
    /// its host and folders are identity enough for a page that browses
    /// and restores, though not for a plan to adopt. The label's caption
    /// carries the qualifier and the "outside SwiftRestic" kind; the
    /// tooltip names the console escape hatch.
    @ViewBuilder
    private func lineageRows(
        _ lineage: SnapshotLineage,
        label: SnapshotLineage.Label?,
        repository: Repository
    ) -> some View {
        let repositoryID = repository.id
        let id = LineageFoldID(repositoryID: repositoryID, key: lineage.key)
        let isExpanded = !collapsedLineages.contains(id)
        let title = label?.title ?? "Backups"
        let caption = label?.caption ?? .init(count: Format.plural(lineage.snapshots.count, "backup"))
        HStack(spacing: 4) {
            groupFold(title: title, isExpanded: isExpanded) { toggleLineage(id, title: title) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                GroupCaptionLine(caption: caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, Indent.groupPad)
        .tag(SidebarItem.lineage(repositoryID: repositoryID, key: lineage.key))
        .help(label?.detail ?? "")
        // Its newest record and its files: no plan to open or adopt.
        .contextMenu {
            restoreFromGroupItem(lineage.snapshots, repository: repository)
            Button("Show Files") {
                router.showFiles(of: .lineage(repositoryID: repositoryID, key: lineage.key))
            }
        }
        // The same folders from the same Mac can sit in two repositories.
        .accessibilityLabel("\(title), \(caption.text), in “\(repository.name)”")
        if isExpanded {
            ForEach(lineage.snapshots) { snapshot in
                RestoreRecordRow(snapshot: snapshot, run: model.backupRun(forSnapshot: snapshot.id))
                    .padding(.leading, Indent.groupRecord)
                    .tag(SidebarItem.restoreSnapshot(repositoryID, snapshot.id))
            }
        }
    }
}

/// The tree's levels, as the leading indentation of top-level List rows.
/// A repository's children keep one shared column ahead of their titles —
/// a plan's or Other backups' fold chevron, the plus of "New Backup
/// Plan…" — so every child's title starts at one x, level with the
/// repository's own title. A backup record sits one fold-step (a
/// chevron column plus the row spacing) past its parent's title, and no
/// further.
private enum Indent {
    /// A repository's children: plan rows, "New Backup Plan…" and the
    /// Other backups node. With `fold` and the row's spacing it puts the
    /// fold column under the repository's icon and the titles at the
    /// repository title's x.
    static let child: CGFloat = 12
    /// The chevron / plus column those children share. plus.circle's
    /// canvas is a point wider; only its empty margin overhangs — the
    /// drawn circle fits.
    static let fold: CGFloat = 14
    /// A group under Other backups, of either kind: its chevron column
    /// starts where the plan family's titles do, putting its title one
    /// fold deeper than theirs.
    static let groupPad: CGFloat = child + fold + 4
    /// A group's chevron column, either kind. With the row spacing it is
    /// the fold-step a record sits past its parent's title.
    static let lineageSlot: CGFloat = 14
    /// A record under a plan, and the status rows an open plan's fold
    /// shows: one fold-step past the plan's title, the x a group's title
    /// starts at.
    static let planRecord: CGFloat = groupPad + lineageSlot + 4
    /// A record under an Other-backups group, plan-UUID or lineage
    /// alike: one fold-step past the group's title.
    static let groupRecord: CGFloat = planRecord + lineageSlot + 4
}

/// A fold's disclosure mark, the restore pane's own: chevron right when
/// closed, down when open. The row around it is the button.
struct FoldChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

/// A lineage group under Other backups, per repository: the same folders
/// from the same host can live in two repositories, and each group folds on
/// its own.
private struct LineageFoldID: Hashable {
    let repositoryID: UUID
    let key: SnapshotLineage.Key
}

/// One dated backup record under a plan or Other backups — the row whose
/// selection fills the detail pane with that record's files. One line, like Arq's: the
/// completeness mark and the moment are the whole record at sidebar size.
private struct RestoreRecordRow: View {
    let snapshot: Snapshot
    /// The backup run that wrote it, when the history still holds one.
    let run: RunRecord?

    var body: some View {
        Text(Format.timestamp(snapshot.time))
            .lineLimit(1)
            // The row's help sits on the timestamp, not the row: a help on
            // the row overwrites the mark's own ("Incomplete: …") in the
            // accessibility tree.
            .help("Browse this backup's files and restore from it")
            .frame(maxWidth: .infinity, alignment: .leading)
            // State trails identity, PlanSidebarRow's rule: the mark sits at
            // the row's right end, and only a visible one claims room there —
            // a reserved slot on every row would truncate group records'
            // dates at the default sidebar width.
            .padding(.trailing, run?.snapshotCompleteness == .incomplete ? Self.markWidth + 6 : 0)
            // An overlay, so the clear "Complete" text and the hidden
            // slot-holder stay in the row — VoiceOver keeps its
            // Complete/Incomplete word — without taking the date's width.
            .overlay(alignment: .trailing) {
                SnapshotCompletenessMark(run: run)
                    .font(.caption)
                    .frame(width: Self.markWidth)
            }
            // One utterance per record: the mark's label, when it has one,
            // merges with the date, so there is no second row label to keep
            // in step with it.
            .accessibilityElement(children: .combine)
    }

    private static let markWidth: CGFloat = 14
}

/// An Other backups group's second line. The count and the kind keep their
/// width; the qualifiers between them take what is left and lose their
/// middle first, so "not set up here" survives a long hostname. Each piece
/// after the first carries its own leading separator.
private struct GroupCaptionLine: View {
    let caption: SnapshotLineage.Label.Caption

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(caption.count)
            if !caption.qualifiers.isEmpty {
                Text(" · " + caption.qualifiers.joined(separator: " · "))
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
            if !caption.kind.isEmpty {
                Text(" · " + caption.kind.joined(separator: " · "))
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
    /// The plan's newest snapshot, from the same shelf the fold beneath
    /// this row shows. It is what the moment falls back to when the app
    /// never ran the plan: history adopted with the repository counts as
    /// its last backup.
    let latestSnapshot: Snapshot?

    var body: some View {
        // As of the window's minute clock, and counting from the one moment
        // every surface's "Last backup" reads (PlanStatus.lastBackupAt) —
        // the repository page's Protection line and the plan page agree
        // with this row by construction.
        let caption = PlanStatus.sidebarCaption(
            for: plan,
            activity: model.activity[plan.id],
            problem: model.currentProblem(for: plan.id),
            latestSnapshot: latestSnapshot,
            existingRepositoryIDs: Set(model.configuration.repositories.map(\.id)),
            now: now,
            relative: { Format.ago($0, now: now) }
        )
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(plan.displayName)
                    .lineLimit(1)
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
                    // Middle truncation: the trailing marker narrows the
                    // column, and a tail cut would take "ago" — when it
                    // happened. The tooltip and VoiceOver keep the whole line.
                    Text(caption.text)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(caption.text)
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

/// What an open plan says while it holds no record — and a Files tab whose
/// chain has none. "No backups yet" only once a listing has succeeded:
/// before that it is still being read, and after a failure it says why.
struct BackupsStatusRow: View {
    @Environment(AppModel.self) private var model
    let repositoryID: UUID

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
            Text("No backups yet")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
