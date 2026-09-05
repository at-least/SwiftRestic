import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: RunRecord.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.configuration.runs.isEmpty {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Runs appear here once a plan has finished.")
                )
            } else {
                Table(model.configuration.runs, selection: $selection) {
                    TableColumn("") { run in
                        Image(systemName: run.outcome.symbolName)
                            .foregroundStyle(color(for: run.outcome))
                            .help(run.outcome.displayName)
                    }
                    .width(24)

                    TableColumn("Started") { run in
                        Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .monospacedDigit()
                    }
                    .width(min: 150, ideal: 170)

                    TableColumn("Plan") { run in
                        Text(run.planName.isEmpty ? "—" : run.planName)
                    }

                    TableColumn("Kind") { run in
                        Text(run.kind.rawValue.capitalized)
                    }
                    .width(min: 66, ideal: 76)

                    TableColumn("Duration") { run in
                        Text(Format.duration(run.duration)).monospacedDigit()
                    }
                    .width(min: 70, ideal: 80)

                    TableColumn("Added") { run in
                        Text(run.dataAdded > 0 ? Format.bytes(run.dataAdded) : "—")
                            .monospacedDigit()
                    }
                    .width(min: 70, ideal: 84)

                    TableColumn("Detail") { run in
                        Text(detail(for: run))
                            .foregroundStyle(run.outcome == .failed ? Theme.danger : .secondary)
                            .lineLimit(1)
                    }
                }

                if let selected = model.configuration.runs.first(where: { $0.id == selection }),
                   !selected.itemErrors.isEmpty || !selected.hookMessages.isEmpty
                   || selected.failureMessage != nil || selected.detailText != nil {
                    Divider()
                    detailPanel(selected)
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            Button("Clear History", systemImage: "trash") {
                model.configuration.runs.removeAll()
            }
            .disabled(model.configuration.runs.isEmpty)
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(height: 150)
    }

    private func detail(for run: RunRecord) -> String {
        if let failure = run.failureMessage { return failure }
        if !run.itemErrors.isEmpty {
            return "\(max(run.itemErrorCount, run.itemErrors.count)) unreadable item(s)"
        }
        if !run.hookMessages.isEmpty { return "\(run.hookMessages.count) hook issue(s)" }
        if run.kind == .backup {
            return "\(Format.count(run.filesNew)) new, \(Format.count(run.filesChanged)) changed"
        }
        return run.outcome.displayName
    }

    private func color(for outcome: RunRecord.Outcome) -> Color {
        ChartPalette.status(outcome)
    }
}
