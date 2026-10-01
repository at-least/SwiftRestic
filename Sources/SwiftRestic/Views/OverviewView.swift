import SwiftUI

/// Dashboard: what is protected, what runs next, and what has gone wrong —
/// three cards in the order the questions are asked. No charts or tiles:
/// sizes live on each repository's page, history in Activity.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    /// The window's minute clock: every time on the dashboard — how long
    /// ago, whether a run is due, the problems' week — is as of it.
    @Environment(\.now) private var now
    /// Opens Activity, after a problem row has set the run to land on. The
    /// problems card must not be a dead end: a failure the user cannot reach
    /// is a failure they cannot fix.
    var onShowProblems: () -> Void = {}

    /// The problems window: the shared `OverviewMetrics` week, so the
    /// failures card cannot disagree with the sidebar's badge and the menu
    /// bar on what "recent" covers. The predicate itself is
    /// `OverviewMetrics.problems`.
    private var problemWindowStart: Date {
        OverviewMetrics.problemWindowStart(from: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            ForEach(model.banners) { banner in
                BannerView(banner: banner)
            }
            protectionCard
            upcomingCard
            recentFailuresCard
        }
        .detailPane()
        .navigationTitle("Overview")
    }

    // MARK: - Protection

    /// The row type and its derivation live in `OverviewMetrics`, testable
    /// and shared with nothing — the view keeps only the hue each state
    /// wears.
    ///
    /// The state line's words carry every state, and scannability comes
    /// from severity ordering. Only trouble adds a glyph, since orange
    /// caption text measured 2.05:1 on the card: the warning triangle for
    /// an unreadable listing, and for a standing problem the sidebar row's
    /// own outcome glyph beside the sidebar row's own words.
    private var protectionRows: [ProtectionRow] {
        // One pass over the plans, with the model lookups behind closures so
        // this view keeps its observation on the state the rows read.
        OverviewMetrics.protectionRows(
            plans: model.configuration.plans,
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

    /// Protection, the dashboard's actual subject: one row per plan with its
    /// own state texture — protected, empty, unreadable, unknown — instead of
    /// one aggregate number that cannot say which plan it is worried about.
    /// The count survives as a derived caption, never the headline.
    private var protectionCard: some View {
        // The rows feed both the card and its caption; captured once so a
        // render costs one pass over the plans, not two.
        let rows = protectionRows
        return Card("Protection") {
            VStack(alignment: .leading, spacing: 7) {
                if rows.isEmpty {
                    Text("Add a backup plan to start protecting your data.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        protectionRow(row)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } accessory: {
            let known = rows.filter(\.isKnown)
            if !known.isEmpty {
                Text("\(known.filter(\.isProtected).count) of \(known.count) protected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func protectionRow(_ row: ProtectionRow) -> some View {
        HStack(spacing: 8) {
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
            Spacer(minLength: 12)
            if row.didFail, let repositoryID = row.repositoryID {
                Button("Retry") {
                    Task { await model.refreshSnapshots(repositoryID: repositoryID) }
                }
                .controlSize(.small)
                .accessibilityLabel("Retry reading snapshots for \(row.planName)")
            }
        }
    }

    /// A problem row's landing: Activity with that run selected. A problem
    /// run shows under both of Activity's filters, so the user's filter
    /// stays as it was — the plan row's and the incomplete strip's rule.
    private func showInActivity(_ run: RunRecord) {
        router.activityFocusRunID = run.id
        onShowProblems()
    }

    // MARK: - Lists

    private var upcomingCard: some View {
        Card("Next runs") {
            VStack(alignment: .leading, spacing: 7) {
                // The scheduler's own enumeration: an incomplete plan is
                // filtered out exactly where the scheduler filters it, so
                // the card can no longer announce a run that will never fire.
                // A timed hold moves every date to its end, where the
                // scheduler will pick the runs up.
                let hold = model.scheduleHold
                let upcoming = Scheduler.upcomingRuns(
                    in: model.configuration.plans,
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
                        HStack {
                            Text(plan.name).lineLimit(1)
                            Spacer()
                            if date <= now, hold != nil {
                                // Due, but held: it runs once the hold lifts,
                                // not now. Icon and word in the secondary
                                // colour — a wait, not an alarm.
                                Label("Waiting", systemImage: "pause.circle")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            } else if date <= now {
                                // Icon + word, not colour alone, and only
                                // the glyph wears the warning hue: the word
                                // in orange measured 2.33:1 on the card.
                                Label {
                                    Text("Due now")
                                } icon: {
                                    Image(systemName: "clock.badge.exclamationmark")
                                        .foregroundStyle(Theme.warning)
                                }
                                .font(.caption.weight(.semibold))
                            } else {
                                Text(Format.timestamp(date))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
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

    private var recentFailuresCard: some View {
        Card("Recent problems") {
            VStack(alignment: .leading, spacing: 7) {
                // The same window the sidebar's badge counts. The card's
                // "recent" used to mean "all of history, latest five", which
                // let a count read zero above a nine-day-old failure.
                let failures = OverviewMetrics.problems(
                    in: model.configuration.runs,
                    since: problemWindowStart
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
                                Image(systemName: "chevron.forward")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
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
