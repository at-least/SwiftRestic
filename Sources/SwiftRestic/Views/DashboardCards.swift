import SwiftUI

// The repository page's cards — protection in one line, the adoptable
// history a repository may have arrived with, and the week's problems
// against it — over the repository the page shows, in the order the
// questions are asked. No charts or tiles: sizes live in the Details card,
// history in Activity.

// MARK: - Protection

/// The repository page's Protection card: one line — how many of the
/// repository's plans are protected, a run in flight, when its newest
/// backup landed, and, while one is on, the app-wide hold's words with a
/// Resume — then one line per plan that is not protected. The lines are
/// static text by rule: no hover, no chevron, no destination — the plans
/// they name sit in the sidebar beside it. Until the listing succeeds the
/// card says why in the caveat's words instead; the plan-less page's
/// prominent button stays either way.
struct ProtectionCard: View {
    @Environment(AppModel.self) private var model
    /// The window's minute clock, as the sidebar's captions read it.
    @Environment(\.now) private var now

    let repositoryID: UUID
    let onAddPlan: () -> Void

    var body: some View {
        let plans = model.plans(in: repositoryID)
        let summary = model.protectionSummary(repositoryID: repositoryID, now: now)
        return Card("Protection") {
            VStack(alignment: .leading, spacing: 7) {
                if let summary {
                    HStack(spacing: 8) {
                        Text(summary.text)
                        // The one in-window Resume, and only the user's own
                        // pause has one — the battery's ends by plugging in.
                        if summary.showsResume {
                            Spacer(minLength: 8)
                            Button("Resume") { model.resumeBackups() }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .help("Resume scheduled backups, checks and prunes")
                        }
                    }
                    ForEach(summary.attentionLines, id: \.self) { line in
                        // The sidebar triangle's glyph; the words stay
                        // secondary, as the caveat's do.
                        Label {
                            Text(line).foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.warning)
                        }
                        .font(.caption)
                    }
                    ForEach(summary.heldLines, id: \.self) { line in
                        // Protected, but it will not run by itself: a pause
                        // is a choice, so its glyph, not the warning's.
                        Label {
                            Text(line).foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "pause.circle")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                } else {
                    // No count is honest yet: the card's first glance says why.
                    SnapshotListingCaveat(outcome: model.snapshotListingOutcome(for: repositoryID))
                }
                // The repository's first plan: the way to it is the whole
                // point of a plan-less page, in the empty card's prominent
                // form. Once a plan exists the next one starts from the
                // sidebar's +, ⌘N or the repository row's menu.
                if plans.isEmpty {
                    Button("New Backup Plan…", action: onAddPlan)
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Other backups

/// The repository page's Other backups card — the adopt flow's landing
/// place, for a repository added with history already in it: one row per
/// adoptable plan-UUID group, with the group's own Adopt… beside it. An
/// exception to "the sidebar lists them": the rows carry a verb, the card
/// exists only while something can be adopted, and the groups it leaves
/// out — a moved plan's, an untagged lineage's — stay visible in the
/// sidebar beside it, counted by the Details split rather than restated
/// here. It hides while the listing has not succeeded, and adopting the
/// last group empties it away.
struct OtherBackupsCard: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router

    let repositoryID: UUID
    /// Opens the adopt sheet for one adoptable group — the root owns the
    /// presenting state, as for every sheet a pane raises.
    let onAdoptGroup: (_ repositoryID: UUID, _ planID: UUID) -> Void

    @ViewBuilder
    var body: some View {
        let shelves = model.shelves(for: repositoryID)
        let groups = shelves.adoptableGroups
        // The same rule as the Protection line: adoptable rows beside a
        // failed read promise action on stale facts. The sidebar keeps its
        // old groups beside the failure sentence, under its own rule.
        if !groups.isEmpty, !listingFailed {
            // The node's own name — "Other" only beside plans — the sidebar's
            // derivation. No count: the card lists the adoptable groups only,
            // and the shelf's total is the sidebar node's and the Details
            // split's to say.
            Card(LocalizedStringKey(SidebarTree.otherBackupsTitle(repositoryHasPlans: !shelves.plans.isEmpty))) {
                VStack(alignment: .leading, spacing: 7) {
                    // otherLabels names every group it is given, and these
                    // are among the shelves' own.
                    let labels = shelves.otherLabels(
                        repositories: model.configuration.repositories,
                        localHost: model.localHostname
                    )
                    ForEach(groups) { group in
                        if case let .plan(planID, _) = group {
                            row(planID: planID, label: labels[group.id]!)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Whether the last read of the listing failed — the card hides with
    /// the Protection line when it did.
    private var listingFailed: Bool {
        if case .failed = model.snapshotListingOutcome(for: repositoryID) { return true }
        return false
    }

    /// One adoptable group. The row opens the group's page — the in-page
    /// row grammar, hover and trailing chevron — and Adopt… sits before the
    /// chevron as its own control, Retry's grammar: never a button inside
    /// a button.
    private func row(planID: UUID, label: SnapshotLineage.Label) -> some View {
        HStack(spacing: 8) {
            Button {
                router.selection = .orphanPlan(repositoryID: repositoryID, planID: planID)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label.title)
                            .lineLimit(1)
                        if let caption = label.caption {
                            Text(caption.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 12)
                }
            }
            .buttonStyle(HoverableButtonStyle())
            .accessibilityLabel("\(label.title): \(label.caption?.text ?? ""). Show group page")
            Button("Adopt…") { onAdoptGroup(repositoryID, planID) }
                .controlSize(.small)
                // The group page's own words for the verb it opens.
                .help("Rebuild a plan around these backups — their history becomes its own, and nothing is written to the repository")
                .accessibilityLabel("Adopt \(label.title) as a backup plan")
            DashboardRowChevron()
        }
    }
}

// MARK: - Recent problems

/// The week's failed and completed-with-errors runs — the same window the
/// sidebar's Activity badge and the menu bar count. A row opens Activity on
/// that run: a failure the user cannot reach is a failure they cannot fix.
struct RecentProblemsCard: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.now) private var now

    /// Every run against this repository, of every kind.
    let repositoryID: UUID

    var body: some View {
        Card("Recent problems") {
            VStack(alignment: .leading, spacing: 7) {
                // The same window the sidebar's badge counts.
                let since = OverviewMetrics.problemWindowStart(from: now)
                let failures = OverviewMetrics.problems(
                    in: model.configuration.runs,
                    since: since,
                    repositoryID: repositoryID
                )
                    .sorted { $0.finishedAt > $1.finishedAt }
                    .prefix(5)

                if failures.isEmpty {
                    // Quiet by rule: a clean week is the absence of trouble,
                    // not an achievement — words, no celebratory checkmark.
                    Text("Nothing has failed in the last seven days.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(failures)) { run in
                        let title = RunRecordPresentation.problemRowTitle(for: run, plans: model.configuration.plans)
                        let caption = RunRecordPresentation.problemRowCaption(for: run)
                        Button { showInActivity(run) } label: {
                            HStack(spacing: 6) {
                                // This card lists only problems, so the
                                // outcome is said in words right under the
                                // name — a glyph would only repeat it — with
                                // why, as Activity's Detail column says it.
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(title)
                                        .lineLimit(1)
                                    Text(caption)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(caption)
                                }
                                Spacer()
                                Text(Format.ago(run.finishedAt, now: now))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                DashboardRowChevron()
                            }
                        }
                        .buttonStyle(HoverableButtonStyle())
                        .accessibilityLabel("\(title): \(caption). Show in Activity")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Activity with that run selected. A problem run shows under both of
    /// Activity's filters, so the user's filter stays as it was — the plan
    /// row's and the incomplete strip's rule.
    private func showInActivity(_ run: RunRecord) {
        router.focusRun(run.id)
    }
}

/// The trailing mark of a dashboard row that goes somewhere.
private struct DashboardRowChevron: View {
    var body: some View {
        Image(systemName: "chevron.forward")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}
