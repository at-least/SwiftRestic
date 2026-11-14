import SwiftUI

/// The location page's first answer: how many of its plans are up to date, then
/// one row per plan that is not, which opens that plan and carries its
/// problem's fix.
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
                            .help("Resume scheduled backups, verifications and freeing space")
                    }
                }
                planRows(summary.failureLines, symbol: RunRecord.Outcome.failed.symbolName!, tint: StatusPalette.status(.failed))
                planRows(summary.attentionLines, symbol: "exclamationmark.triangle.fill", tint: Theme.warning)
                planRows(summary.awaitingLines, symbol: nil, tint: Color.clear)
            } else {
                SnapshotListingCaveat(repositoryID: repositoryID)
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
        .help(prompt.isOne
            ? "Keep backing up from this Mac, with these backups as the history"
            : "Show the backups other Macs or removed plans made here")
    }

    /// A line without a symbol keeps the glyph's room, so its text lines up
    /// with the lines above.
    private func planRows(_ lines: [UpToDateLine], symbol: String?, tint: some ShapeStyle) -> some View {
        ForEach(lines, id: \.text) { line in
            HStack {
                Button {
                    router.selection = .plan(line.planID)
                } label: {
                    HStack {
                        Label {
                            Text(line.text)
                        } icon: {
                            Image(systemName: symbol ?? "exclamationmark.triangle.fill")
                                .foregroundStyle(tint)
                                .opacity(symbol == nil ? 0 : 1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show this plan")
                if line.isProblem, let problem = model.currentProblem(for: line.planID), let fix = model.fix(for: problem) {
                    RunFixButton(fix: fix)
                        .controlSize(.small)
                }
                Button {
                    router.selection = .plan(line.planID)
                } label: {
                    RowChevron()
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
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
