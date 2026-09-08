import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    /// Route from a failure to the plan that owns it.
    var onOpenPlan: ((UUID) -> Void)?
    @State private var selection: RunRecord.ID?
    @State private var isConfirmingClear = false
    // Newest first by default: the "what happened" surface is scanned by
    // recency, and the stored history's order is neither.
    @State private var sortOrder: [KeyPathComparator<RunRecord>] = [
        KeyPathComparator(\RunRecord.startedAt, order: .reverse)
    ]

    private var visibleRuns: [RunRecord] {
        let base = model.activityShowsProblemsOnly
            ? model.configuration.runs.filter { $0.outcome == .failed || $0.outcome == .completedWithErrors }
            : model.configuration.runs
        return base.sorted(using: sortOrder)
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
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
            } else if visibleRuns.isEmpty {
                ContentUnavailableView(
                    "No problems recorded",
                    systemImage: "checkmark.circle",
                    description: Text("Every run in the history succeeded. Turn the filter off to see them.")
                )
            } else {
                Table(visibleRuns, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("") { run in
                        Image(systemName: run.outcome.symbolName)
                            .foregroundStyle(color(for: run.outcome))
                            .help(run.outcome.displayName)
                            .accessibilityLabel(run.outcome.displayName)
                    }
                    .width(24)

                    TableColumn("Started", value: \.startedAt) { run in
                        Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
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
                        Text(detail(for: run))
                            .foregroundStyle(run.outcome == .failed ? Theme.danger : .secondary)
                            // A failure's first sentence is the one thing the
                            // user came for; never cut it at the scan surface.
                            .lineLimit(run.failureMessage != nil ? 2 : 1)
                    }
                }
                // A full-height table that outlives its records paints striped
                // phantom rows under the last one — an uncanny loading
                // skeleton that never resolves. The stripes are the table's
                // alternating-row background, not its content background, so
                // it is the alternating behavior that gets disabled; the
                // outcome glyphs and the Detail column keep rows scannable.
                .alternatingRowBackgrounds(.disabled)

                if let selected = visibleRuns.first(where: { $0.id == selection }),
                   !selected.itemErrors.isEmpty || !selected.hookMessages.isEmpty
                   || selected.failureMessage != nil || selected.detailText != nil {
                    Divider()
                    detailPanel(selected)
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItemGroup {
                // The two-state filter the dashboard's problem rows send you to;
                // full per-outcome filtering would serve nobody who reaches for it.
                Picker("Show", selection: $model.activityShowsProblemsOnly) {
                    Text("All runs").tag(false)
                    Text("Problems").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                Button("Clear History", systemImage: "trash") {
                    isConfirmingClear = true
                }
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
                model.configuration.runs.removeAll()
            }
        } message: {
            Text("This permanently removes all \(model.configuration.runs.count) run records. Backups and snapshots are not affected.")
        }
        .task(id: model.activityShowsProblemsOnly) {
            // Arriving from the dashboard's problem rows should land with the
            // newest problem already selected — otherwise the detail panel
            // below sits empty at the exact moment the user wants answers.
            guard model.activityShowsProblemsOnly,
                  !visibleRuns.contains(where: { $0.id == selection })
            else { return }
            selection = visibleRuns.first?.id
        }
    }

    private func detailPanel(_ run: RunRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let failure = run.failureMessage {
                    Text(failure)
                        .foregroundStyle(Theme.danger)
                        .textSelection(.enabled)
                }
                if let detail = run.detailText {
                    Text(detail)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                ForEach(Array(run.itemErrors.enumerated()), id: \.offset) { _, message in
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                ForEach(Array(run.hookMessages.enumerated()), id: \.offset) { _, message in
                    Label(message, systemImage: "terminal")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let planID = run.planID, model.plan(id: planID) != nil {
                    HStack(spacing: 10) {
                        Button("Open Plan") { onOpenPlan?(planID) }
                        if model.plan(id: planID)?.isConfigurationComplete == true {
                            Button("Back Up Now") { model.runBackup(planID: planID) }
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(height: 150)
    }

    private func detail(for run: RunRecord) -> String {
        if let failure = run.failureMessage { return failure }
        if !run.itemErrors.isEmpty {
            return Format.plural(max(run.itemErrorCount, run.itemErrors.count), "unreadable item")
        }
        if !run.hookMessages.isEmpty { return Format.plural(run.hookMessages.count, "hook issue") }
        if run.kind == .backup {
            return "\(Format.count(run.filesNew)) new, \(Format.count(run.filesChanged)) changed"
        }
        return run.outcome.displayName
    }

    private func color(for outcome: RunRecord.Outcome) -> Color {
        ChartPalette.status(outcome)
    }
}
