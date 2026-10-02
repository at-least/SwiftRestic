import SwiftUI

// The dashboard's three cards — what is protected, what runs next, what
// has gone wrong — over whichever plans a page shows, in the order the
// questions are asked. No charts or tiles: sizes live on each repository's
// page, history in Activity.

// MARK: - Protection

/// One row per plan with its own state texture — protected, empty,
/// unreadable, unknown — instead of one aggregate number that cannot say
/// which plan it is worried about. The count survives as a derived caption,
/// never the headline. The row type and its derivation live in
/// `OverviewMetrics`; the view keeps only the hue each state wears.
///
/// The state line's words carry every state, and scannability comes from
/// severity ordering. Only trouble adds a glyph, since orange caption text
/// measured 2.05:1 on the card: the warning triangle for an unreadable
/// listing, and for a standing problem the sidebar row's own outcome glyph
/// beside the sidebar row's own words.
struct ProtectionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    /// The window's minute clock, as the sidebar's captions read it.
    @Environment(\.now) private var now

    let title: LocalizedStringKey
    let plans: [BackupPlan]
    let emptyText: LocalizedStringKey
    /// "New Backup Plan…", when the page has a repository to preset: the
    /// prominent next step while the card is empty, a small button beside
    /// the count once it is not.
    var onAddPlan: (() -> Void)?

    private var rows: [ProtectionRow] {
        // One pass over the plans, with the model lookups behind closures so
        // this view keeps its observation on the state the rows read.
        OverviewMetrics.protectionRows(
            plans: plans,
            latestSnapshot: { repositoryID, planID in
                model.snapshots(for: repositoryID, planID: planID).first
            },
            repositoryHasSnapshots: { repositoryID in
                !model.snapshots(for: repositoryID).isEmpty
            },
            listingOutcome: { repositoryID in
                model.snapshotListingOutcome(for: repositoryID)
            },
            isChecking: { repositoryID in
                model.loadingSnapshots.contains(repositoryID)
            },
            activity: { planID in
                model.activity[planID]
            },
            standingProblem: { planID in
                model.currentProblem(for: planID)
            },
            relative: { date in
                Format.ago(date, now: now)
            }
        )
    }

    var body: some View {
        // The rows feed both the card and its caption; captured once so a
        // render costs one pass over the plans, not two.
        let rows = rows
        return Card(title) {
            VStack(alignment: .leading, spacing: 7) {
                if rows.isEmpty {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                    if let onAddPlan {
                        Button("New Backup Plan…", action: onAddPlan)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ForEach(rows) { row in
                        protectionRow(row)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } accessory: {
            HStack(spacing: 10) {
                let known = rows.filter(\.isKnown)
                if !known.isEmpty {
                    Text("\(known.filter(\.isProtected).count) of \(known.count) protected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let onAddPlan, !rows.isEmpty {
                    Button("New Backup Plan…", action: onAddPlan)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        }
    }

    /// The row opens its plan. The three cards list the same shape, so
    /// they share one grammar: a row that goes somewhere wears the hover
    /// tint and a trailing chevron, as Recent problems' rows do. Retry stays
    /// its own control beside the row, not a button inside a button.
    private func protectionRow(_ row: ProtectionRow) -> some View {
        HStack(spacing: 8) {
            Button { router.selection = .plan(row.planID) } label: {
                HStack(spacing: 8) {
                    protectionRowText(row)
                    Spacer(minLength: 12)
                    DashboardRowChevron()
                }
            }
            .buttonStyle(HoverableButtonStyle())
            .accessibilityLabel("\(row.planName): \(row.stateText). Show plan")
            if row.didFail, let repositoryID = row.repositoryID {
                Button("Retry") {
                    Task { await model.refreshSnapshots(repositoryID: repositoryID) }
                }
                .controlSize(.small)
                .accessibilityLabel("Retry reading snapshots for \(row.planName)")
            }
        }
    }

    private func protectionRowText(_ row: ProtectionRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.planName)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                // Beside words that say it: decoration to VoiceOver.
                if row.didFail {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                        .foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                } else if let outcome = row.problemOutcome, let symbol = outcome.symbolName {
                    Image(systemName: symbol)
                        .imageScale(.small)
                        .foregroundStyle(StatusPalette.status(outcome))
                        .accessibilityHidden(true)
                }
                Text(row.stateText)
                    .foregroundStyle(row.stateHue)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
        }
    }
}

private extension ProtectionRow {
    /// "Not protected" is the row's real news and reads at full weight; a
    /// pending, running or protected line stays quiet, and so do an
    /// unreadable listing's words — its glyph wears the warning hue. A
    /// first backup in flight is not protected yet, and not news either.
    var stateHue: Color {
        if isRunning { return .secondary }
        if isKnown, !isProtected { return .primary }
        return .secondary
    }
}

// MARK: - Next runs

struct NextRunsCard: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    /// Whether a run is due, and the dates, are as of the window's clock.
    @Environment(\.now) private var now

    let plans: [BackupPlan]

    var body: some View {
        Card("Next runs") {
            VStack(alignment: .leading, spacing: 7) {
                // The scheduler's own enumeration: an incomplete plan is
                // filtered out exactly where the scheduler filters it, so
                // the card can no longer announce a run that will never fire.
                // A timed hold moves every date to its end, where the
                // scheduler will pick the runs up.
                let hold = model.scheduleHold
                let upcoming = Scheduler.upcomingRuns(
                    in: plans,
                    now: now,
                    existingRepositoryIDs: Set(model.configuration.repositories.map(\.id)),
                    heldUntil: hold?.resumesAt
                )
                .sorted { $0.1 < $1.1 }
                .prefix(5)

                // First, above the rows: while backups are held, that is
                // what the rows mean.
                if let hold {
                    HStack(spacing: 8) {
                        Label(hold.summary(), systemImage: hold == .onBattery ? "battery.25" : "pause.circle")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if case .paused = hold {
                            Button("Resume") { model.resumeBackups() }
                                .buttonStyle(.borderless)
                                .help("Resume scheduled backups, checks and prunes")
                        }
                    }
                }

                if upcoming.isEmpty {
                    Text("Nothing scheduled.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(upcoming), id: \.0.id) { plan, date in
                        let status = UpcomingStatus(date: date, now: now, isBackingUp: model.activity[plan.id]?.isBackup == true, hold: hold)
                        // Opens the plan, as the Protection rows do.
                        Button { router.selection = .plan(plan.id) } label: {
                            HStack {
                                Text(plan.name).lineLimit(1)
                                Spacer()
                                switch status {
                                case .runningNow:
                                    // The due run is the one in flight, and
                                    // nothing stamps its slot until it ends:
                                    // "Due now" stood over every scheduled
                                    // backup beside the sidebar's spinner. The
                                    // plan page's Next backup says the same.
                                    Text(status.text)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                case .waiting:
                                    // Due, but held: it runs once the hold lifts,
                                    // not now. Icon and word in the secondary
                                    // colour — a wait, not an alarm.
                                    Label(status.text, systemImage: "pause.circle")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                case .dueNow:
                                    // Icon + word, not colour alone, and only
                                    // the glyph wears the warning hue: the word
                                    // in orange measured 2.33:1 on the card.
                                    Label {
                                        Text(status.text)
                                    } icon: {
                                        Image(systemName: "clock.badge.exclamationmark")
                                            .foregroundStyle(Theme.warning)
                                    }
                                    .font(.caption.weight(.semibold))
                                case .at:
                                    Text(status.text)
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                DashboardRowChevron()
                            }
                        }
                        .buttonStyle(HoverableButtonStyle())
                        .accessibilityLabel("\(plan.name): \(status.text). Show plan")
                    }
                    // Last, under the rows it qualifies: they promise runs,
                    // and this is the condition on that promise. "Nothing
                    // scheduled." has nothing to qualify.
                    if let offer = model.loginItemOffer() {
                        Divider()
                        LoginItemOfferLine(offer: offer)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A Next runs row's status. Its words are the row's text and its
    /// VoiceOver label both.
    private enum UpcomingStatus {
        case runningNow, waiting, dueNow
        case at(Date)

        init(date: Date, now: Date, isBackingUp: Bool, hold: ScheduleHold?) {
            if date > now {
                self = .at(date)
            } else if isBackingUp {
                self = .runningNow
            } else {
                self = hold != nil ? .waiting : .dueNow
            }
        }

        var text: String {
            switch self {
            case .runningNow: "Running now"
            case .waiting: "Waiting"
            case .dueNow: "Due now"
            case let .at(date): Format.timestamp(date)
            }
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

    /// Every run against this repository, of every kind; nil for all runs.
    let repositoryID: UUID?

    var body: some View {
        Card("Recent problems") {
            VStack(alignment: .leading, spacing: 7) {
                // The same window the sidebar's badge counts. The card's
                // "recent" used to mean "all of history, latest five", which
                // let a count read zero above a nine-day-old failure.
                let since = OverviewMetrics.problemWindowStart(from: now)
                let failures = (repositoryID.map {
                    OverviewMetrics.problems(in: model.configuration.runs, since: since, repositoryID: $0)
                } ?? OverviewMetrics.problems(in: model.configuration.runs, since: since))
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
