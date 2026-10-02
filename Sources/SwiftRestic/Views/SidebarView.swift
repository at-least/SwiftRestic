import SwiftUI

/// The split view's sidebar: each repository with its plans and its Restore
/// node always in view beneath it, then Activity. The repository's row
/// opens its page, which is its overview, and never collapses; beneath it
/// sit its plans, "New Backup Plan…" while it has none, and Restore, which
/// folds open to the repository's dated backups. The context menus and the
/// Add footer ride along.
///
/// Every row is a top-level List row, and the tree's levels are leading
/// indentation (`Indent`): a DisclosureGroup draws its triangle at the
/// row's outer edge, which an indented child would leave stranded far to
/// the left of its title. Only places carry a tag — a repository, a plan, a
/// backup record — so selection stays unique; Restore and the lineage
/// groups are folds, and "New Backup Plan…" is an action.
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

    /// Which repositories' Restore nodes are open — the backup records
    /// underneath are the restore pane's entry points. Shared with the detail
    /// column: selecting a record from anywhere must find its node open.
    @Binding var expandedRestoreRepos: Set<UUID>

    /// Lineage groups under Restore that the user folded shut. Groups start
    /// open, as Arq's tree does, and a record selected from anywhere reopens
    /// its group — the promise `expandedRestoreRepos` keeps one level up.
    @State private var collapsedRestoreLineages: Set<RestoreLineageID> = []

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
                    repositoryRow(repository)
                    ForEach(SidebarTree.children(of: repository.id, in: model.configuration.plans), id: \.self) { child in
                        childRows(child, of: repository)
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
        // The keyboard the outline gave the old disclosure rows: with a
        // repository selected, → opens its Restore node and ← closes it.
        // The node itself takes no selection, so the arrows act through
        // the repository that owns it.
        // Plain arrows only: a modified arrow keeps its system meaning, the
        // restore pane's rule for its own folds.
        .onKeyPress(.rightArrow, phases: .down) { press in
            isPlain(press) ? foldSelectedRepository(open: true) : .ignored
        }
        .onKeyPress(.leftArrow, phases: .down) { press in
            isPlain(press) ? foldSelectedRepository(open: false) : .ignored
        }
        .onChange(of: router.selection) {
            guard case let .restoreSnapshot(repositoryID, snapshotID) = router.selection,
                  let snapshot = model.snapshots(for: repositoryID).first(where: { $0.id == snapshotID })
            else { return }
            collapsedRestoreLineages.remove(RestoreLineageID(repositoryID: repositoryID, key: snapshot.lineageKey))
        }
    }

    /// Arq's bare + in the corner. A missing restic is not repeated here: the
    /// banner above every pane (RootDetailView) already says it, with the
    /// install instruction a cursor-only triangle could not show. The bar
    /// background stays — an open Restore node scrolls under it.
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
                    restoreCaption(repository, listing: model.snapshots(for: repository.id))
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

    /// The repository row's second line: how many backups it holds — but
    /// only once that is known. A repository still being read, or whose
    /// read failed (a wrong password, an unreachable server), never says
    /// "0 backups", which reads as "your data is gone"; it says what the
    /// Restore node says — a repository missing from its location (restic
    /// exit 10, an unplugged disk) included. A count from an earlier listing
    /// stands under a failed re-read, as the records do.
    @ViewBuilder
    private func restoreCaption(_ repository: Repository, listing: [Snapshot]) -> some View {
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
    private func childRows(_ child: SidebarChild, of repository: Repository) -> some View {
        switch child {
        case let .plan(id):
            if let plan = model.plan(id: id) {
                PlanSidebarRow(plan: plan)
                    .padding(.leading, Indent.child)
                    .tag(SidebarItem.plan(plan.id))
                    .contextMenu { planContextMenu(plan) }
            }
        case .addPlan:
            addPlanRow(repository)
        case .restore:
            restoreRow(repository)
            if expandedRestoreRepos.contains(repository.id) {
                restoreContents(repository)
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

    // MARK: - Restore

    /// The repository's Restore node, Arq's RESTORE tree one level down:
    /// it folds open to the repository's backup records, and picking a
    /// record shows its files in the detail pane. It carries no tag — as a
    /// selection it would duplicate the repository row or a record — so a
    /// click only folds it. Its chevron sits in the slot a plan's state mark
    /// uses, so the word Restore starts where plan names do.
    private func restoreRow(_ repository: Repository) -> some View {
        let isExpanded = expandedRestoreRepos.contains(repository.id)
        return Button { toggleRestore(repository.id) } label: {
            HStack(spacing: 4) {
                FoldChevron(isExpanded: isExpanded)
                    .frame(width: Indent.slot)
                Text("Restore")
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, Indent.child)
        .help("Browse the backups in “\(repository.name)” and restore files")
        // Named for its repository: every repository has a Restore node, and
        // as flat rows they have no outline parent to tell them apart.
        .accessibilityLabel("Restore “\(repository.name)”")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private func isPlain(_ press: KeyPress) -> Bool {
        press.modifiers.isDisjoint(with: [.command, .option, .control, .shift])
    }

    private func foldSelectedRepository(open: Bool) -> KeyPress.Result {
        guard case let .repository(id) = router.selection else { return .ignored }
        if open != expandedRestoreRepos.contains(id) { toggleRestore(id) }
        return .handled
    }

    /// The first opening loads the record list; later refreshes come from
    /// the launch sweep and the repository's own Refresh.
    /// Spoken when it folds, as a disclosure row was: the fold is a button,
    /// whose changed value VoiceOver does not read out by itself.
    private func toggleRestore(_ repositoryID: UUID) {
        let opened = expandedRestoreRepos.remove(repositoryID) == nil
        if opened {
            expandedRestoreRepos.insert(repositoryID)
            if model.snapshotListingOutcome(for: repositoryID) == .idle {
                Task { await model.refreshSnapshots(repositoryID: repositoryID) }
            }
        }
        if let repository = model.repository(id: repositoryID) {
            announceFold("Restore “\(repository.name)”", opened: opened)
        }
    }

    private func announceFold(_ name: String, opened: Bool) {
        AccessibilityNotification.Announcement("\(name) \(opened ? "expanded" : "collapsed")").post()
    }

    @ViewBuilder
    private func restoreContents(_ repository: Repository) -> some View {
        let listing = model.snapshots(for: repository.id)
        if listing.isEmpty {
            restoreStatusRow(repository)
                .padding(.leading, Indent.grandchild)
        } else {
            // One lineage — one plan, or a repository only one tree ever
            // went into — stays a flat list: a group level would only
            // repeat the Restore row above it.
            let lineages = model.lineages(for: repository.id)
            if lineages.count > 1 {
                let labels = SnapshotLineage.labels(for: lineages, plans: model.configuration.plans)
                ForEach(lineages) { lineage in
                    lineageRows(lineage, label: labels[lineage.key], repository: repository)
                }
            } else {
                ForEach(listing) { snapshot in
                    RestoreRecordRow(snapshot: snapshot, run: model.backupRun(forSnapshot: snapshot.id))
                        .padding(.leading, Indent.grandchild)
                        .tag(SidebarItem.restoreSnapshot(repository.id, snapshot.id))
                }
            }
        }
    }

    /// What an open Restore node says while it holds no record. "No backups
    /// yet" only once a listing has succeeded: before that it is still being
    /// read, and after a failure it says why.
    @ViewBuilder
    private func restoreStatusRow(_ repository: Repository) -> some View {
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

    /// One lineage's records — Arq's backed-up-folder level, so a
    /// repository several plans share no longer interleaves their dates, and
    /// the row below a record is the one its Change column compares against.
    @ViewBuilder
    private func lineageRows(
        _ lineage: SnapshotLineage,
        label: SnapshotLineage.Label?,
        repository: Repository
    ) -> some View {
        let repositoryID = repository.id
        let id = RestoreLineageID(repositoryID: repositoryID, key: lineage.key)
        let isExpanded = !collapsedRestoreLineages.contains(id)
        let title = label?.title ?? "Backups"
        let caption = [Format.plural(lineage.snapshots.count, "backup"), label?.qualifier]
            .compactMap { $0 }
            .joined(separator: " · ")
        Button {
            if isExpanded {
                collapsedRestoreLineages.insert(id)
            } else {
                collapsedRestoreLineages.remove(id)
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
        .help(label?.detail ?? "")
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
/// state mark, the plus of "New Backup Plan…", Restore's chevron — so every
/// child's title starts at one x.
private enum Indent {
    static let slot: CGFloat = 26
    /// A repository's plans, "New Backup Plan…" and Restore.
    static let child: CGFloat = 16
    /// Under Restore: past the child's slot and its spacing, so a record or
    /// a lineage group starts where the word Restore does.
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

/// A lineage group under Restore, per repository: the same folders from the
/// same host can live in two repositories, and each group folds on its own.
private struct RestoreLineageID: Hashable {
    let repositoryID: UUID
    let key: SnapshotLineage.Key
}

/// One dated backup record under a repository's Restore node — the row whose selection
/// fills the detail pane with that record's files. One line, like Arq's: the
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
            // Backup Plan…" and "Restore", whose plus and chevron sit in the
            // same slot (`Indent.slot`). The marker sat inline before, and a
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
