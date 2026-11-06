import SwiftUI

/// The repository page's Protection card: one line — how many of the
/// repository's plans are protected, a run in flight, when its newest
/// backup landed, and, while one is on, the app-wide hold's words with a
/// Resume — then one line per plan that is not protected, which opens that
/// plan. Until the listing succeeds the card says why in the caveat's words
/// instead; the plan-less page's prominent button stays either way.
struct ProtectionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    /// The window's minute clock, as the sidebar's captions read it.
    @Environment(\.now) private var now

    let repositoryID: UUID
    let onAddPlan: () -> Void
    /// Opens the adopt sheet for a group — the root owns the presenting
    /// state, as for every sheet a pane raises.
    let onAdoptGroup: (_ repositoryID: UUID, _ planID: UUID) -> Void

    var body: some View {
        let plans = model.plans(in: repositoryID)
        let summary = model.protectionSummary(repositoryID: repositoryID, now: now)
        let commands = model.planCommands(for: .repository(repositoryID))
        return Card("Protection") {
            VStack(alignment: .leading, spacing: 7) {
                if let summary {
                    HStack(spacing: 8) {
                        Text(summary.text)
                        // Only the user's own pause has one: a metered
                        // network's hold ends with the network.
                        if summary.showsResume {
                            Spacer(minLength: 8)
                            Button("Resume") { model.resumeBackups() }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .help("Resume scheduled backups, checks and cleanups")
                        }
                    }
                    // The sidebar mark's glyphs for what needs attention — a
                    // failed run's red octagon, else the warning triangle;
                    // Activity's skip glyph for a backup around an away drive,
                    // with the record's words; a pause is a choice, so its
                    // glyph, not the warning's. The words stay secondary
                    // throughout, as the caveat's do.
                    captionLines(summary.failureLines, symbol: RunRecord.Outcome.failed.symbolName!, tint: StatusPalette.status(.failed))
                    captionLines(summary.attentionLines, symbol: "exclamationmark.triangle.fill", tint: Theme.warning)
                    captionLines(summary.skippedLines, symbol: RunRecord.Outcome.skipped.symbolName!, tint: .secondary)
                    captionLines(summary.heldLines, symbol: "pause.circle", tint: .secondary)
                } else {
                    // No count is honest yet: the card's first glance says why.
                    SnapshotListingCaveat(outcome: model.snapshotListingOutcome(for: repositoryID))
                }
                // The repository's first plan: the way to it is the whole
                // point of a plan-less page, in the empty card's prominent
                // form. Once a plan exists the next one starts from the
                // sidebar's +, ⌘N or the repository row's menu. Not while the
                // repository can't be read: a plan for a drive that isn't
                // here is not the next step, reaching it is.
                if case .loaded = model.snapshotListingOutcome(for: repositoryID) {
                    let prompt = continuePrompt
                    // A new Mac's way back to its history: a location added
                    // with backups in it. Primary until the location has a
                    // plan of its own.
                    if let prompt {
                        continueRow(prompt, isPrimary: plans.isEmpty)
                    }
                    if plans.isEmpty {
                        if prompt == nil {
                            Button("New Backup Plan…", action: onAddPlan)
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("New Backup Plan…", action: onAddPlan)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } accessory: {
            // The one verb this page's first glance asks for: ⌘B's, here.
            if !plans.isEmpty {
                Button("Back Up Now") { model.runBackups(planIDs: commands.repositoryPlanIDs) }
                    .controlSize(.small)
                    .disabled(!commands.canBackUp)
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
        Button(prompt.isOne ? "Continue Backups…" : "Show Backups") {
            if prompt.isOne {
                onAdoptGroup(repositoryID, prompt.firstPlanID)
            } else {
                router.selection = .orphanPlan(repositoryID: repositoryID, planID: prompt.firstPlanID)
            }
        }
        .help("Keep backing up from this Mac, with these backups as the history")
    }

    private func captionLines(_ lines: [ProtectionLine], symbol: String, tint: some ShapeStyle) -> some View {
        ForEach(lines, id: \.text) { line in
            Button {
                router.selection = .plan(line.planID)
            } label: {
                Label {
                    Text(line.text).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Show this plan")
        }
    }
}
