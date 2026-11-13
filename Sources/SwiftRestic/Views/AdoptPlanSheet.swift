import SwiftUI

/// Continue Backups: the history a new plan takes over, said once, with one
/// button. The plan's settings come from those backups
/// (`AppModel.adoptDraft`) and a new plan's defaults; Edit Plan… changes
/// them afterwards.
struct AdoptPlanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let draft: BackupPlan
    /// The presenting surface selects the new plan and turns its page to
    /// Backups, which are its states to move.
    let onAdopted: (UUID) -> Void

    /// Read off the main actor: a stalled share can hold the stat.
    @State private var sourceExists = true

    var body: some View {
        // Derived on every render, so a backup landing or the group leaving
        // while the sheet is open keeps the words true.
        let briefing = model.adoptBriefing(for: draft, sourceExists: sourceExists)
        let missingRequirement = EditorRequirements.plan(draft, isNew: true, among: model.configuration.plans)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Continue “\(model.label(of: draft))” on this Mac?")
                    .font(.headline)
                if let briefing {
                    Text(briefing.historyLine)
                    Text(briefing.madeLine)
                        .foregroundStyle(.secondary)
                } else {
                    // The group left while the sheet was open — its page is
                    // revalidating away behind the sheet.
                    Text("These backups are no longer here, so there’s nothing to continue.")
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                row("Folder or file") {
                    Text((draft.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(draft.path)
                }
                row("Location") {
                    // While the group is gone the bare name still says where
                    // this draft points.
                    Text(briefing?.repositoryLine ?? model.repository(id: draft.repositoryID).map { model.label(of: $0) } ?? "")
                }
                row("Schedule") { Text(draft.schedule.frequency.displayName) }
                // The plan page's switch, by its name there.
                row("Remove old backups automatically") { Text(draft.retention.isEnabled ? "On" : "Off") }
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 4) {
                if let briefing {
                    ForEach(briefing.warnings, id: \.self) { warning in
                        WarningLine(text: warning)
                    }
                    Text(AdoptBriefing.footer)
                        .foregroundStyle(.secondary)
                    // The scheduler's next tick starts it: a never-run plan
                    // counts as due.
                    if draft.isScheduled {
                        Text("Its next backup starts within a minute.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let missingRequirement {
                    Text(missingRequirement)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue Backups") {
                    model.adopt(draft: draft)
                    onAdopted(draft.id)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(briefing == nil || missingRequirement != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task(id: draft.path) {
            let path = draft.path
            sourceExists = await Task.detached { AppModel.sourceExists(path) }.value
        }
    }

    private func row(_ title: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            value()
        }
    }
}
