import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @State private var selection: RunRecord.ID?
    /// Taken by a click in the table (`focusOnClick`), so ↑ and ↓ walk the
    /// runs rather than the sidebar out of Activity.
    @FocusState private var tableIsFocused: Bool
    @State private var isConfirmingClear = false
    /// The drawer's Compare with Previous… and Show Log… sheets.
    @State private var comparing: SnapshotDiffTarget?
    @State private var loggedRun: RunRecord?
    // Newest first by default: the "what happened" surface is scanned by
    // recency, and the stored history's order is neither.
    @State private var sortOrder: [KeyPathComparator<RunRecord>] = [
        KeyPathComparator(\RunRecord.startedAt, order: .reverse)
    ]

    private var visibleRuns: [RunRecord] {
        let base = router.activityShowsProblemsOnly
            ? model.configuration.runs.filter { $0.outcome == .failed || $0.outcome == .completedWithErrors }
            : model.configuration.runs
        return base.sorted(using: sortOrder)
    }

    var body: some View {
        @Bindable var model = model
        @Bindable var router = router
        // One filter+sort per render: the empty-state check, the table and
        // the detail lookup all need the same list, and the computed property
        // would re-run the history's sort at every access (the hoist
        // SnapshotDiffView documents for its own candidates).
        let runs = visibleRuns
        return VStack(alignment: .leading, spacing: 0) {
            // Activity is where failures get read, so it carries the banner
            // queue like the other panes — a refresh error must be visible
            // here too, not only on the pane that happened to be open.
            Group {
                ForEach(model.banners) { banner in
                    BannerView(banner: banner)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            if model.configuration.runs.isEmpty {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Runs appear here once a plan has finished.")
                )
            } else if runs.isEmpty {
                ContentUnavailableView(
                    "No problems recorded",
                    systemImage: "checkmark.circle",
                    description: Text("Every run in the history succeeded. Turn the filter off to see them.")
                )
            } else {
                Table(runs, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("") { run in
                        // Only trouble wears a glyph; a clean run leaves the
                        // cell empty, the way Mail's unread column does. The
                        // invisible text keeps the verdict in VoiceOver. It
                        // is clear ink: `hidden()` would silence it, and so
                        // does `opacity(0)` on macOS 26, which drops the text
                        // from the accessibility tree — a clean run's cell
                        // read as an empty group (SnapshotCompletenessMark
                        // measured the same).
                        if let symbolName = run.outcome.symbolName {
                            Image(systemName: symbolName)
                                .foregroundStyle(StatusPalette.status(run.outcome))
                                .help(run.outcome.displayName)
                                .accessibilityLabel(run.outcome.displayName)
                        } else {
                            Text(run.outcome.displayName)
                                .foregroundStyle(.clear)
                                .lineLimit(1)
                                .accessibilityLabel(run.outcome.displayName)
                        }
                    }
                    .width(24)

                    // Five columns after the glyph, Arq's one-line row with
                    // the kind and the verdict beside it: how long a run
                    // took and what it added are in the drawer below and in
                    // Copy Details. Widths: the caps on the fixed-length
                    // columns send the spare width to Detail, the one column
                    // whose text runs long. Measured on macOS 26, a table
                    // created in a window, or narrowed to it, puts every
                    // capped column at its minimum and the rest into Detail,
                    // while widening shares the growth out evenly up to the
                    // caps. So each minimum is what its column shows on
                    // arrival — Started's is the widest timestamp, "May 31,
                    // 2026 at 10:00 AM" (161.6 pt), Subject's holds a plan
                    // name like "Photos Library" (88.1 pt), Repository's a
                    // repository name of the same length. A row is 16 + the
                    // column widths + 5 × 17 + 16 pt wide, and the 940-pt
                    // window with the sidebar at its default 260 plus the
                    // split's 8 pt leaves the table 672, so the minimums may
                    // add up to 555 (they are 510) — room for a legacy
                    // scroller's 17 without a sideways scroll.
                    TableColumn("Started", value: \.startedAt) { run in
                        Text(Format.timestamp(run.startedAt))
                            .monospacedDigit()
                    }
                    .width(min: 162, ideal: 164, max: 164)

                    // Backups and restores name their plan or item, the Kind
                    // column names the operation. A check or prune has no
                    // plan to name — its subject is the repository, which
                    // the Repository column beside this one now says, and
                    // saying it here too would state one fact twice in
                    // adjacent columns. Display-only for the same reason:
                    // those rows' stored name is the repository's, so a sort
                    // on this header would order their "—" cells by a value
                    // on screen nowhere.
                    TableColumn("Subject") { run in
                        Group {
                            switch run.kind {
                            case .backup, .forget, .restore:
                                Text(run.planName.isEmpty ? "—" : run.planName)
                                    .help(run.planName)
                            case .check, .prune:
                                Text("—")
                            }
                        }
                    }
                    .width(min: 96, ideal: 112, max: 120)

                    // The repository a run belongs to, by ID at render time
                    // — check and prune runs recorded it in `planName` alone,
                    // which could not survive a repository rename. A "—" is
                    // either a run recorded before runs carried a repository
                    // or a repository since removed; the data cannot tell the
                    // two apart, so the tooltip says both and asserts
                    // neither.
                    TableColumn("Repository") { run in
                        if let name = model.repository(id: run.repositoryID)?.name {
                            Text(name)
                                .help(name)
                        } else {
                            Text("—")
                                .help("This run's repository is not known — it predates per-run records, or the repository was removed.")
                        }
                    }
                    .width(min: 96, ideal: 104, max: 140)

                    TableColumn("Kind") { run in
                        Text(run.kind.displayName)
                    }
                    .width(min: 52, ideal: 56, max: 56)

                    TableColumn("Detail") { run in
                        let detail = RunRecordPresentation.detail(for: run)
                        Text(detail)
                            .foregroundStyle(run.outcome == .failed ? Theme.danger : .secondary)
                            // One line on every row. A second line for
                            // failures kept its height only in rows the table
                            // was created with: a failed run inserted while
                            // Activity was open stayed 24 pt tall and cut its
                            // two lines in half. The whole sentence is the
                            // tooltip, and the drawer leads a problem run
                            // with it.
                            .lineLimit(1)
                            // Failure messages lead with the subject ("which
                            // repository") and end with the verdict ("why").
                            // Tail truncation removed exactly the verdict, so
                            // a long path sacrifices its middle instead.
                            .truncationMode(run.failureMessage != nil ? .middle : .tail)
                            .help(detail)
                    }
                    .width(min: 80, ideal: 200)
                }
                // A full-height table that outlives its records paints striped
                // phantom rows under the last one — an uncanny loading
                // skeleton that never resolves. The stripes are the table's
                // alternating-row background, not its content background, so
                // it is the alternating behavior that gets disabled; the
                // outcome glyphs and the Detail column keep rows scannable.
                .alternatingRowBackgrounds(.disabled)
                .focusOnClick($tableIsFocused)
                // Wiping the history is rare and final, so it is not chrome:
                // a right-click on the list, behind the same confirmation.
                .contextMenu(forSelectionType: RunRecord.ID.self) { _ in
                    Button("Clear History…", role: .destructive) {
                        isConfirmingClear = true
                    }
                }

                // Every selected run opens the drawer, a clean one too: the
                // plan page's Last backup value lands on exactly such a run.
                if let selected = runs.first(where: { $0.id == selection }) {
                    Divider()
                    RunDetailPanel(
                        run: selected,
                        onCompare: { comparing = $0 },
                        onShowLog: { loggedRun = $0 }
                    )
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItemGroup {
                // Two states: what went wrong, or everything. Full
                // per-outcome filtering would serve nobody who reaches for it.
                Picker("Show", selection: $router.activityShowsProblemsOnly) {
                    Text("All runs").tag(false)
                    Text("Problems").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
        }
        .confirmationDialog(
            "Clear the run history?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                model.clearRunHistory()
            }
        } message: {
            Text("This permanently removes all \(model.configuration.runs.count) run records and their logs. Backups and snapshots are not affected.")
        }
        .sheet(item: $comparing) { target in
            SnapshotDiffView(target: target)
                .environment(model)
        }
        .sheet(item: $loggedRun) { run in
            RunLogSheet(run: run)
                .environment(model)
        }
        .task(id: router.activityShowsProblemsOnly) {
            // Switching to Problems lands with the newest problem already
            // selected — otherwise the detail panel below sits empty at the
            // exact moment the user wants answers.
            guard router.activityShowsProblemsOnly,
                  !visibleRuns.contains(where: { $0.id == selection })
            else { return }
            selection = visibleRuns.first?.id
        }
        // The "Last backup" value's landing: the plan page hands over a run
        // to land selected.
        .task(id: router.activityFocusRunID) {
            guard let id = router.activityFocusRunID else { return }
            router.activityFocusRunID = nil
            if visibleRuns.contains(where: { $0.id == id }) {
                selection = id
            }
        }
        #if DEBUG
        .onChange(of: model.snapshots, initial: true) { applyCaptureSheetOverride() }
        #endif
    }

    #if DEBUG
    /// Debug-only: `SWIFTRESTIC_CAPTURE_SHEET=diff` opens the drawer's
    /// Compare with Previous… on the newest backup run that wrote a
    /// snapshot, once the listing holds that snapshot — this pane is the
    /// compare sheet's home. When the listing never does, nothing opens.
    private func applyCaptureSheetOverride() {
        guard ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_SHEET"] == "diff",
              comparing == nil,
              let run = model.configuration.runs.first(where: { $0.kind == .backup && $0.snapshotID != nil }),
              let repositoryID = run.repositoryID,
              case let .available(snapshot)? = model.snapshotLink(for: run)
        else { return }
        selection = run.id
        comparing = SnapshotDiffTarget(repositoryID: repositoryID, snapshot: snapshot)
    }
    #endif
}
