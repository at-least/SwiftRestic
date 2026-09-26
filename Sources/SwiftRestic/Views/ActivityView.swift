import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    /// Route from a failure to the plan that owns it.
    var onOpenPlan: ((UUID) -> Void)?
    @State private var selection: RunRecord.ID?
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
                                .foregroundStyle(color(for: run.outcome))
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

                    TableColumn("Started", value: \.startedAt) { run in
                        Text(Format.timestamp(run.startedAt))
                            .monospacedDigit()
                    }
                    .width(min: 150, ideal: 170)

                    // Check and prune runs belong to a repository, backups to
                    // a plan — the column names the subject, the Kind column
                    // names the operation.
                    TableColumn("Subject", value: \.planName) { run in
                        Text(run.planName.isEmpty ? "—" : run.planName)
                    }

                    TableColumn("Kind") { run in
                        Text(run.kind.rawValue.capitalized)
                    }
                    .width(min: 66, ideal: 76)

                    TableColumn("Duration", value: \.duration) { run in
                        Text(Format.duration(run.duration)).monospacedDigit()
                    }
                    .width(min: 70, ideal: 80)

                    TableColumn("Added", value: \.dataAdded) { run in
                        Text(run.dataAdded > 0 ? Format.bytes(run.dataAdded) : "—")
                            .monospacedDigit()
                    }
                    .width(min: 70, ideal: 84)

                    TableColumn("Detail") { run in
                        Text(RunRecordPresentation.detail(for: run))
                            .foregroundStyle(run.outcome == .failed ? Theme.danger : .secondary)
                            // A failure's first sentence is the one thing the
                            // user came for; never cut it at the scan surface.
                            .lineLimit(run.failureMessage != nil ? 2 : 1)
                            // Failure messages lead with the subject ("which
                            // repository") and end with the verdict ("why").
                            // Tail truncation removed exactly the verdict, so
                            // a long path now sacrifices its middle instead.
                            .truncationMode(run.failureMessage != nil ? .middle : .tail)
                    }
                }
                // A full-height table that outlives its records paints striped
                // phantom rows under the last one — an uncanny loading
                // skeleton that never resolves. The stripes are the table's
                // alternating-row background, not its content background, so
                // it is the alternating behavior that gets disabled; the
                // outcome glyphs and the Detail column keep rows scannable.
                .alternatingRowBackgrounds(.disabled)

                // Every selected run opens the drawer, a clean one too: the
                // plan page's Last backup tile lands on exactly such a run.
                if let selected = runs.first(where: { $0.id == selection }) {
                    Divider()
                    RunDetailPanel(
                        run: selected,
                        onOpenPlan: onOpenPlan,
                        onCompare: { comparing = $0 },
                        onShowLog: { loggedRun = $0 }
                    )
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItemGroup {
                // The two-state filter the dashboard's problem rows send you to;
                // full per-outcome filtering would serve nobody who reaches for it.
                Picker("Show", selection: Binding(
                    get: { router.activityShowsProblemsOnly },
                    set: { router.activityShowsProblemsOnly = $0 }
                )) {
                    Text("All runs").tag(false)
                    Text("Problems").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                Button("Clear History", systemImage: "trash") {
                    isConfirmingClear = true
                }
                .labelStyle(.titleAndIcon)
                .disabled(model.configuration.runs.isEmpty)
                .help("Permanently remove all run records")
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
            // Arriving from the dashboard's problem rows should land with the
            // newest problem already selected — otherwise the detail panel
            // below sits empty at the exact moment the user wants answers.
            guard router.activityShowsProblemsOnly,
                  !visibleRuns.contains(where: { $0.id == selection })
            else { return }
            selection = visibleRuns.first?.id
        }
        // The "Last backup" tile's landing: the plan page hands over a run to
        // land selected, the way the problems filter hands over a filter.
        .task(id: router.activityFocusRunID) {
            guard let id = router.activityFocusRunID else { return }
            router.activityFocusRunID = nil
            if visibleRuns.contains(where: { $0.id == id }) {
                selection = id
            }
        }
    }

    private func color(for outcome: RunRecord.Outcome) -> Color {
        ChartPalette.status(outcome)
    }
}
