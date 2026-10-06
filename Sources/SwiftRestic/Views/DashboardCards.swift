import SwiftUI

// The repository page's cards — protection in one line, the adoptable
// history a repository may have arrived with, and the week's problems
// against it — over the repository the page shows, in the order the
// questions are asked. No charts or tiles: sizes live in the Details card,
// history in Activity.

// MARK: - Protection

/// The repository page's Protection card: one line — how many of the
/// repository's plans are protected, when its newest backup landed, and,
/// while one is on, the app-wide hold's words with a Resume. The line is
/// static text by rule: no hover, no chevron, no destination — the plans
/// it summarizes sit in the sidebar beside it. It waits for a succeeded
/// listing (the caveat under Details says why in words); the card and
/// the plan-less page's prominent button stay.
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
                        // The deleted Next runs card's hold line and its
                        // control, moved: this is the one in-window Resume,
                        // and only the user's own pause has one — the
                        // battery's ends by plugging in.
                        if summary.showsResume {
                            Spacer(minLength: 8)
                            Button("Resume") { model.resumeBackups() }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .help("Resume scheduled backups, checks and prunes")
                        }
                    }
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
/// accepted, deliberate exception to "the sidebar lists them": the rows
/// carry a verb, the card exists only while something can be adopted, and
/// the groups it leaves out — a moved plan's, an untagged lineage's — stay
/// visible in the sidebar beside it, counted by the Details split rather
/// than restated here. It hides while the listing has not succeeded, and
/// adopting the last group empties it away.
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
            // The node's own name — "Other" only beside plans — and its
            // total, both the sidebar's derivations, so the card and the
            // tree it sits beside cannot disagree.
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
            } accessory: {
                Text(Format.plural(shelves.otherBackupsCount, "backup"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                // The same window the sidebar's badge counts. The card's
                // "recent" used to mean "all of history, latest five", which
                // let a count read zero above a nine-day-old failure.
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
                        Button { showInActivity(run) } label: {
                            HStack(spacing: 6) {
                                // This card lists only problems, so the
                                // outcome is said in words right under the
                                // name — a glyph would only repeat it.
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(run.planName.isEmpty ? run.kind.rawValue : run.planName)
                                        .lineLimit(1)
                                    Text(run.outcome.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Format.ago(run.finishedAt, now: now))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                DashboardRowChevron()
                            }
                        }
                        .buttonStyle(HoverableButtonStyle())
                        .accessibilityLabel("\(run.planName.isEmpty ? run.kind.rawValue : run.planName): \(run.outcome.displayName). Show in Activity")
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
        router.activityFocusRunID = run.id
        router.selection = .activity
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
