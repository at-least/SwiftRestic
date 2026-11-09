import SwiftUI

/// The location page's first answer: how many of its plans are up to date, then
/// one row per plan that is not, which opens that plan.
struct StatusSection: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.now) private var now

    let repositoryID: UUID
    let onAddPlan: () -> Void
    let onAdoptGroup: (_ repositoryID: UUID, _ planID: UUID) -> Void

    var body: some View {
        let plans = model.plans(in: repositoryID)
        let summary = model.upToDateSummary(repositoryID: repositoryID, now: now)
        let commands = model.planCommands(for: .repository(repositoryID))
        Section {
            if let summary {
                HStack(spacing: 8) {
                    Text(summary.text)
                    // Only the user's own pause has one: a metered network's
                    // hold ends with the network.
                    if summary.showsResume {
                        Spacer(minLength: 8)
                        Button("Resume") { model.resumeBackups() }
                            .help("Resume scheduled backups, verifications and cleanups")
                    }
                }
                planRows(summary.failureLines, symbol: RunRecord.Outcome.failed.symbolName!, tint: StatusPalette.status(.failed))
                planRows(summary.attentionLines, symbol: "exclamationmark.triangle.fill", tint: Theme.warning)
                planRows(summary.skippedLines, symbol: RunRecord.Outcome.skipped.symbolName!, tint: .secondary)
                planRows(summary.heldLines, symbol: "pause.circle", tint: .secondary)
            } else {
                SnapshotListingCaveat(outcome: model.snapshotListingOutcome(for: repositoryID))
            }
            // Not while the location can't be read: a plan for a drive that
            // isn't here is not the next step, reaching it is.
            if case .loaded = model.snapshotListingOutcome(for: repositoryID) {
                let prompt = continuePrompt
                if let prompt {
                    continueRow(prompt, isPrimary: plans.isEmpty)
                }
                if plans.isEmpty {
                    if prompt == nil {
                        Button("Back Up a Folder…", action: onAddPlan)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Back Up a Folder…", action: onAddPlan)
                    }
                }
            }
        } header: {
            HStack {
                Text("Status")
                Spacer()
                if !plans.isEmpty {
                    Button("Back Up Now") { model.runBackups(planIDs: commands.repositoryPlanIDs) }
                        .controlSize(.small)
                        .disabled(!commands.canBackUp)
                }
            }
        }
    }

    private var continuePrompt: ContinueBackupsPrompt? {
        model.shelves(for: repositoryID).continuePrompt(
            repositories: model.configuration.repositories,
            localHost: model.localHostname
        )
    }

    private func continueRow(_ prompt: ContinueBackupsPrompt, isPrimary: Bool) -> some View {
        HStack(spacing: 8) {
            Text(prompt.text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if isPrimary {
                continueButton(prompt).buttonStyle(.borderedProminent)
            } else {
                continueButton(prompt)
            }
        }
    }

    /// One group's sheet straight away; of several, the first one's page,
    /// which offers its own Continue Backups.
    private func continueButton(_ prompt: ContinueBackupsPrompt) -> some View {
        Button(prompt.isOne ? "Continue Backups…" : "Show Other Backups") {
            if prompt.isOne {
                onAdoptGroup(repositoryID, prompt.firstPlanID)
            } else {
                router.selection = .orphanPlan(repositoryID: repositoryID, planID: prompt.firstPlanID)
            }
        }
        .help("Keep backing up from this Mac, with these backups as the history")
    }

    private func planRows(_ lines: [UpToDateLine], symbol: String, tint: some ShapeStyle) -> some View {
        ForEach(lines, id: \.text) { line in
            Button {
                router.selection = .plan(line.planID)
            } label: {
                HStack {
                    Label {
                        Text(line.text)
                    } icon: {
                        Image(systemName: symbol).foregroundStyle(tint)
                    }
                    Spacer()
                    RowChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show this plan")
        }
    }
}

private struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.forward")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}
