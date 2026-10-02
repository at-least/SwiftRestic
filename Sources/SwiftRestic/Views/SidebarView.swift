import SwiftUI

/// The split view's sidebar: each repository with its plans always in view
/// beneath it, then Activity. The repository's row opens its page, which is
/// its overview, and never collapses; beneath it sit its plans — each folds
/// open to the dated backups it made there — "New Backup Plan…" while it has
/// none, and Other backups while the repository holds backups none of its
/// plans made (`BackupShelves`). The context menus and the Add footer ride
/// along.
///
/// Every row is a top-level List row, and the tree's levels are leading
/// indentation (`Indent`): a DisclosureGroup draws its triangle at the
/// row's outer edge, which an indented child would leave stranded far to
/// the left of its title. Only places carry a tag — a repository, a plan, a
/// backup record — so selection stays unique; a plan's chevron, Other
/// backups and the lineage groups are folds, and "New Backup Plan…" is an
/// action.
///
/// Split out of `RootView` as a real child view so the sidebar's list
/// type-checks on its own: the root's modifier chain sat at the compiler's
/// type-check budget, and the sheet/deletion intents the sidebar raises are
/// passed back as closures — the presenting state stays in `RootView`. For
/// the same budget each row kind is its own function.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.now) private var now

    /// Which plans and Other backups are open — the backup records
    /// underneath are the restore pane's entry points. Shared with the detail
    /// column: selecting a record from anywhere must find its fold open.
    @Binding var folds: SidebarFolds

    /// Lineage groups under Other backups that the user folded shut. Groups
    /// start open, as Arq's tree does, and a record selected from anywhere
    /// reopens its group — the promise `folds` keeps one level up.
    @State private var collapsedLineages: Set<LineageFoldID> = []

    let onEditPlan: (BackupPlan) -> Void
    /// Opens the plan editor, with the repository preset when one is given.
    let onNewPlan: (_ repositoryID: UUID?) -> Void
    let onEditRepository: (Repository) -> Void
    let onNewRepository: () -> Void
    /// Arms the shared deletion confirmation — the sidebar's menus must not
    /// be a faster way around it.
    let onDeletePlan: (BackupPlan) -> Void
    let onRemoveRepository: (Repository) -> Void

    var body: some View {
        List(selection: Binding(
            get: { router.selection },
            set: { router.selection = $0 }
        )) {
            // The same recent-problem count every surface uses; computed once
            // per body so the badge and the surfaces it points at agree.
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
                    // The window's unread badge, wired to the same 7-day
                    // window the tray dot, a repository page's Recent
                    // problems and the menu's problem line share: one count,
                    // so no surface can claim trouble another denies. It also
                    // yields to the unconfigured state like the tray's
                    // problem face does — a removed repository's old
                    // failures must not summon setup-bound attention — and
                    // stays silent when clean.
                    .badge(
                        problemCount > 0 && !model.configuration.repositories.isEmpty
                            ? Text(verbatim: "\(problemCount)")
                            : nil
                    )
                    // The tag must come after the badge. With .tag inside
                    // .badge — a nil badge too — neither a click nor
                    // Accessibility could select the row (probed on macOS 26);
                    // .disabled and .contextMenu after .tag do no such harm.
                    .tag(SidebarItem.activity)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
        // The keyboard an outline gives its disclosure rows: with a plan
        // selected, → shows its backups and ← hides them.
        // Plain arrows only: a modified arrow keeps its system meaning, the
        // restore pane's rule for its own folds.
        .onKeyPress(.rightArrow, phases: .down) { press in
            isPlain(press) ? foldSelectedPlan(open: true) : .ignored
        }
        .onKeyPress(.leftArrow, phases: .down) { press in
            isPlain(press) ? foldSelectedPlan(open: false) : .ignored
        }
        .onChange(of: router.selection) {
            // Only a record under Other backups sits in a group: a plan's
            // record of the same folders must not reopen one.
            guard case let .restoreSnapshot(repositoryID, snapshotID) = router.selection,
                  let snapshot = model.snapshots(for: repositoryID).first(where: { $0.id == snapshotID }),
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
        // The plan toolbar's pair, word for word. The row wears the pause
        // glyph while the schedule is held; manual runs stay possible either
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
    /// protected and should be — the rows its page's Plans card shows, read
    /// from the same derivation. With no dashboard over every repository,
    /// this is where an unreadable repository shows at a glance: the badge
    /// and the menu bar count failed runs, and a wrong password fails none.
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
                planRow(plan)
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
    /// action, not a place: no tag, no chevron. It leaves once a plan exists;
    /// the page's Plans card and the row's menu keep offering the next one.
    private func addPlanRow(_ repository: Repository) -> some View {
        Button { onNewPlan(repository.id) } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(Theme.tint)
                    .frame(width: Indent.slot)
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
    /// backup plan's records sit under the plan. The chevron takes the
    /// indentation's place (`Indent.fold`), so the name starts where it
    /// would without one.
    private func planRow(_ plan: BackupPlan) -> some View {
        HStack(spacing: 4) {
            planFold(plan)
            PlanSidebarRow(plan: plan)
        }
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
        .help(isExpanded ? "Hide this plan's backups" : "Show this plan's backups")
        .accessibilityLabel(planFoldName(plan))
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    /// Named for its plan: every plan has a fold, and as flat rows they
    /// have no outline parent to tell them apart.
    private func planFoldName(_ plan: BackupPlan) -> String {
        "Backups of “\(plan.name.isEmpty ? "Untitled Plan" : plan.name)”"
    }

    private func isPlain(_ press: KeyPress) -> Bool {
        press.modifiers.isDisjoint(with: [.command, .option, .control, .shift])
    }

    private func foldSelectedPlan(open: Bool) -> KeyPress.Result {
        guard case let .plan(id) = router.selection, let plan = model.plan(id: id) else { return .ignored }
        if open != folds.plans.contains(id) { togglePlan(plan) }
        return .handled
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
            backupsStatusRow(repository)
                .padding(.leading, Indent.grandchild)
        } else {
            ForEach(records) { snapshot in
                RestoreRecordRow(snapshot: snapshot, run: model.backupRun(forSnapshot: snapshot.id))
                    .padding(.leading, Indent.grandchild)
                    .tag(SidebarItem.restoreSnapshot(repository.id, snapshot.id))
            }
        }
    }

    /// What an open plan says while it holds no record. "No backups yet"
    /// only once a listing has succeeded: before that it is still being
    /// read, and after a failure it says why.
    @ViewBuilder
    private func backupsStatusRow(_ repository: Repository) -> some View {
        let outcome = model.snapshotListingOutcome(for: repository.id)
        if model.loadingSnapshots.contains(repository.id) || outcome == .idle {
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
                    Task { await model.refreshSnapshots(repositoryID: repository.id) }
                }
                .controlSize(.small)
            }
        } else {
            Text("No backups yet")
                .font(.callout)
                .foregroundStyle(.secondary)
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
        let count = Format.plural(shelves.others.reduce(0) { $0 + $1.snapshots.count }, "backup")
        return Button { toggleOtherBackups(repository, title: title) } label: {
            HStack(spacing: 4) {
                FoldChevron(isExpanded: isExpanded)
                    .frame(width: Indent.fold)
                Image(systemName: "archivebox")
                    .foregroundStyle(.secondary)
                    .frame(width: Indent.slot)
                    .accessibilityHidden(true)
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

    /// Always by lineage, one group or several: unlike a plan's, these
    /// backups have no name above them to say what they are.
    @ViewBuilder
    private func otherBackups(_ repository: Repository, shelves: BackupShelves) -> some View {
        let plans = model.configuration.plans
        let labels = shelves.otherLabels(allPlans: plans)
        ForEach(shelves.others) { lineage in
            lineageRows(
                lineage,
                label: labels[lineage.key],
                movedTo: shelves.formerPlan(of: lineage, allPlans: plans)
                    .flatMap { model.repository(id: $0.repositoryID) },
                repository: repository
            )
        }
    }

    /// One lineage's records — Arq's backed-up-folder level, so the row
    /// below a record is the one its Change column compares against. A group
    /// one plan wrote wears the plan's name, and `movedTo` says why it is not
    /// under that plan: the plan backs up to another repository now.
    @ViewBuilder
    private func lineageRows(
        _ lineage: SnapshotLineage,
        label: SnapshotLineage.Label?,
        movedTo: Repository?,
        repository: Repository
    ) -> some View {
        let repositoryID = repository.id
        let id = LineageFoldID(repositoryID: repositoryID, key: lineage.key)
        let isExpanded = !collapsedLineages.contains(id)
        let title = label?.title ?? "Backups"
        let caption = [
            Format.plural(lineage.snapshots.count, "backup"),
            label?.qualifier,
            movedTo.map { "now backs up to “\($0.name)”" },
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
        let help = [
            label?.detail,
            movedTo.map { "The “\(title)” plan backs up to “\($0.name)” now; these are its earlier backups." },
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
        Button {
            if isExpanded {
                collapsedLineages.insert(id)
            } else {
                collapsedLineages.remove(id)
            }
            announceFold(title, opened: !isExpanded)
        } label: {
            HStack(spacing: 4) {
                FoldChevron(isExpanded: isExpanded)
                    .frame(width: Indent.lineageSlot)
                Image(systemName: "folder")
                    .foregroundStyle(Theme.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, Indent.grandchild)
        .help(help)
        // The same folders from the same Mac can sit in two repositories.
        .accessibilityLabel("\(title), \(caption), in “\(repository.name)”")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        if isExpanded {
            ForEach(lineage.snapshots) { snapshot in
                RestoreRecordRow(snapshot: snapshot, run: model.backupRun(forSnapshot: snapshot.id))
                    .padding(.leading, Indent.lineageRecord)
                    .tag(SidebarItem.restoreSnapshot(repositoryID, snapshot.id))
            }
        }
    }
}

/// The tree's levels, as the leading indentation of top-level List rows.
/// A repository's child keeps a fixed slot ahead of its title — a plan's
/// state mark, the plus of "New Backup Plan…", Other backups' box — so every
/// child's title starts at one x.
private enum Indent {
    static let slot: CGFloat = 26
    /// A repository's children. "New Backup Plan…" is indented by it; a plan
    /// and Other backups fill it with their fold's chevron (`fold`).
    static let child: CGFloat = 16
    /// The chevron column of a plan or Other backups, under the
    /// repository's icon: `child` less the row's spacing, so a title starts
    /// where it would without one.
    static let fold: CGFloat = child - 4
    /// Under a plan or Other backups: past the child's slot and its spacing,
    /// so a record or a lineage group starts where the titles above it do.
    static let grandchild: CGFloat = child + slot + 4
    /// A lineage group's chevron, narrower than a child's slot.
    static let lineageSlot: CGFloat = 14
    /// A record under a lineage group, starting where the group's folder does.
    static let lineageRecord: CGFloat = grandchild + lineageSlot + 4
}

/// A fold's disclosure mark, the restore pane's own: chevron right when
/// closed, down when open. The row around it is the button.
private struct FoldChevron: View {
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
        HStack(spacing: 6) {
            // A fixed slot, so every timestamp starts at the same x whether
            // or not its row wears the incomplete triangle.
            SnapshotCompletenessMark(run: run)
                .font(.caption)
                .frame(width: 14)
            // The row's help sits on the timestamp, not the HStack: a help
            // on the HStack overwrites the mark's own ("Incomplete: …") in
            // the accessibility tree.
            Text(Format.timestamp(snapshot.time))
                .lineLimit(1)
                .help("Browse this backup's files and restore from it")
                // The date leads the combined utterance, as in a list of
                // dates it should; the mark sits first only on screen.
                .accessibilitySortPriority(1)
        }
        // One utterance per record: the mark's label, when it has one,
        // merges with the date, so there is no second row label to keep
        // in step with it.
        .accessibilityElement(children: .combine)
    }
}

private struct PlanSidebarRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.now) private var now
    let plan: BackupPlan

    var body: some View {
        // As of the window's minute clock, the repository page's Plans card
        // spells the same run from the same tick.
        let caption = PlanStatus.sidebarCaption(
            for: plan,
            activity: model.activity[plan.id],
            problem: model.currentProblem(for: plan.id),
            existingRepositoryIDs: Set(model.configuration.repositories.map(\.id)),
            now: now,
            relative: { Format.ago($0, now: now) }
        )
        HStack(spacing: 4) {
            // A fixed leading slot on every row, marker or not, so every plan
            // name starts at the same x — and at the x of the words "New
            // Backup Plan…" and "Other backups", whose plus and box sit in
            // the same slot (`Indent.slot`). The marker sat inline before, and a
            // dotted Photos stood 17 pt right of an idle name.
            // Color.clear holds the slot's width: an empty marker is an
            // EmptyView, and EmptyView drops `.frame`.
            ZStack {
                Color.clear
                marker
            }
            .frame(width: Indent.slot)
            VStack(alignment: .leading, spacing: 1) {
                Text(plan.name.isEmpty ? "Untitled Plan" : plan.name)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    // The glyph carries the severity — red for a failed run
                    // (restic exit 1, no snapshot), orange for one that
                    // completed with errors (exit 3, an incomplete snapshot)
                    // — and the words stay in the secondary colour: orange
                    // caption text measured 2.16:1 on the light sidebar.
                    // Beside words that say it, the glyph is decoration to
                    // VoiceOver. The words, and which state wins the line,
                    // come from `PlanStatus.sidebarCaption`.
                    if let outcome = caption.outcome, let symbol = outcome.symbolName {
                        Image(systemName: symbol)
                            .imageScale(.small)
                            .foregroundStyle(StatusPalette.status(outcome))
                            .accessibilityHidden(true)
                    }
                    // Middle truncation: the slot narrows the column, and a
                    // tail cut would take "ago" — when it happened. The
                    // tooltip and VoiceOver keep the whole line.
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
        }
    }

    /// A row wears state, never identity. In rank: the in-flight spinner,
    /// the Mail dot for a problem the user has not seen, the pause mark. An
    /// otherwise idle plan wears nothing.
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
        } else if PlanStatus.showsPauseMarker(for: plan) {
            // Either kind of pause. The caption already says "Paused — …"
            // or "Paused until …".
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}
