import Charts
import SwiftUI

/// Dashboard: what is protected, what has been written lately, and what is next.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    /// Opens Activity, after the Problems tile has set the router's
    /// problems filter or a problem row the run to land on. The problems
    /// card must not be a dead end: a failure the user cannot reach is a
    /// failure they cannot fix.
    var onShowProblems: () -> Void = {}

    /// Series are reduced once when the history changes, not on every redraw —
    /// a few hundred runs reduced per frame is visible.
    @State private var daily: [DailyBackupVolume] = []
    @State private var domain: [String] = []
    @State private var selectedDay: Date?
    @State private var showsTable = false

    private static let windowDays = 30

    /// The problems window: the shared `OverviewMetrics` week, so the
    /// Problems tile and the failures card cannot disagree with the sidebar
    /// and menu bar on what "recent" covers. The predicate itself is
    /// `OverviewMetrics.problems`.
    private var problemWindowStart: Date {
        OverviewMetrics.problemWindowStart(from: .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            ForEach(model.banners) { banner in
                BannerView(banner: banner)
            }
            protectionCard
            statTiles
            // Space and history read as one unit: what accumulates daily,
            // where it lives. Pairing cards two-up (the grammar the
            // upcoming/problems row already sets) is what keeps the common
            // one-plan, one-repository overview inside the default window
            // instead of a scroll; genuinely long content still grows down.
            HStack(alignment: .top, spacing: Theme.Space.section) {
                volumeCard
                repositorySizeCard
            }
            HStack(alignment: .top, spacing: Theme.Space.section) {
                upcomingCard
                recentFailuresCard
            }
        }
        .detailPane()
        .navigationTitle("Overview")
        .task(id: chartSignature) { rebuild() }
    }

    /// What `rebuild()` reads, as one comparable value — the pure reduction
    /// in `OverviewMetrics`, which the test bundle pins. Counts alone went
    /// stale: the history trims to its cap, so the count stops changing and
    /// the chart would stop moving for a busy user; the newest record's
    /// identity moves with every append, cap or no cap.
    private var chartSignature: String {
        OverviewMetrics.chartSignature(
            plans: model.configuration.plans,
            runs: model.configuration.runs
        )
    }

    private func rebuild() {
        let planOrder = model.configuration.plans.map(\.name)
        daily = OverviewMetrics.dailyVolume(
            runs: model.configuration.runs,
            planOrder: planOrder,
            days: Self.windowDays
        )
        domain = OverviewMetrics.domain(for: daily, planOrder: planOrder)
    }

    // MARK: - Tiles

    /// The row type and its derivation live in `OverviewMetrics`, testable
    /// and shared with nothing — the view keeps only the hue each state
    /// wears.
    ///
    /// The state line's words carry every state, and scannability comes
    /// from severity ordering. Only an unreadable listing adds a glyph: the
    /// warning triangle carries the alarm, since the words stay secondary —
    /// orange caption text measured 2.05:1 on the card.
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

    private var statTiles: some View {
        // Coverage lives in the Protection card above; these are the app's
        // inventory counts.
        let problems = OverviewMetrics.problemCount(
            runs: model.configuration.runs,
            since: problemWindowStart
        )
        return HStack(spacing: Theme.Space.tile) {
            StatTile(
                title: "Repositories",
                value: Format.count(model.configuration.repositories.count)
            )
            StatTile(
                title: "Plans",
                value: Format.count(model.configuration.plans.count)
            )
            // A button in both states: a tile that only became clickable when
            // problems existed was a disappearing affordance, and arriving in
            // Activity pre-filtered is a fine answer to "zero problems" too.
            // The tile wears no glyph in any state — the count is the whole
            // message, and the failure itself is named in words in Recent
            // problems below.
            Button(action: showProblems) {
                StatTile(
                    title: "Problems (7 days)",
                    value: problems > 0 ? Format.count(problems) : "0",
                    trailingSymbol: "chevron.forward"
                )
            }
            .buttonStyle(HoverableButtonStyle())
            .accessibilityLabel(
                problems > 0
                    ? "Problems in the last 7 days: \(problems). Show them in Activity"
                    : "No problems in the last 7 days. Show Activity"
            )
        }
    }

    private func showProblems() {
        router.activityShowsProblemsOnly = true
        onShowProblems()
    }

    /// A problem row's landing: Activity with that run selected. A problem
    /// run shows under both of Activity's filters, so the user's filter
    /// stays as it was — the plan row's and the incomplete strip's rule.
    /// The Problems tile keeps the filter landing.
    private func showInActivity(_ run: RunRecord) {
        router.activityFocusRunID = run.id
        onShowProblems()
    }

    // MARK: - Daily volume

    private var volumeCard: some View {
        Card("Data added per day") {
            VStack(alignment: .leading, spacing: 8) {
                if daily.isEmpty {
                    Text("No backups in the last \(Self.windowDays) days.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 20)
                } else if showsTable {
                    volumeTable
                } else {
                    volumeChart
                }
            }
        } accessory: {
            // Several of the light-mode series colours sit below 3:1 against
            // the surface, so a non-colour reading of the same data is not
            // optional. Words, not icons: an icon-pair segment was findable
            // by mouse and invisible to everyone else.
            Picker("Data view", selection: $showsTable) {
                Text("Chart").tag(false)
                Text("Table").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
        }
    }

    private var volumeChart: some View {
        Chart(daily) { point in
            BarMark(
                x: .value("Day", point.day, unit: .day),
                y: .value("Added", point.dataAdded)
            )
            .foregroundStyle(by: .value("Plan", point.series))
            // No corner radius here: it rounds every stack segment on all
            // sides, so mid-stack pieces turn into lens shapes against their
            // neighbours. The 2px surface gap keeps segments legible; the
            // single-series repository chart below can afford rounding.
        }
        .chartForegroundStyleScale(
            domain: domain,
            range: colorRange(for: domain)
        )
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .chartXSelection(value: $selectedDay)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let bytes = value.as(Int64.self) {
                        Text(Format.bytes(bytes))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartOverlay { proxy in
            if let selectedDay, let anchor = proxy.position(forX: selectedDay) {
                selectionCallout(day: selectedDay, x: anchor)
            }
        }
        .frame(height: 220)
    }

    @ViewBuilder
    private func selectionCallout(day: Date, x: CGFloat) -> some View {
        let sameDay = daily.filter { Calendar.current.isDate($0.day, inSameDayAs: day) }
        if !sameDay.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(day.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption.weight(.semibold))
                ForEach(sameDay) { point in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(colorFor(point.series))
                            .frame(width: 7, height: 7)
                        Text(point.series).font(.caption)
                        Spacer(minLength: 8)
                        Text(Format.bytes(point.dataAdded))
                            .font(.caption.monospacedDigit())
                    }
                }
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .fixedSize()
            .offset(x: max(0, x - 60), y: 4)
        }
    }

    /// Series colours follow each plan's assigned palette slot instead of
    /// domain position, so a plan keeps its colour when plans are added,
    /// removed or reordered — on the chart, the sidebar and the run lists
    /// alike.
    private func colorRange(for domain: [String]) -> [Color] {
        domain.map { name in
            if name == OverviewMetrics.otherSeriesName { return ChartPalette.other }
            if let plan = model.configuration.plans.first(where: { $0.name == name }) {
                return ChartPalette.color(for: plan)
            }
            // Historical series recorded under a name no current plan bears —
            // a renamed plan's older runs, say. Keep a stable colour of their
            // own instead of collapsing into "Other" grey.
            return ChartPalette.color(forSeriesNamed: name)
        }
    }

    private func colorFor(_ series: String) -> Color {
        guard let index = domain.firstIndex(of: series) else { return ChartPalette.other }
        return colorRange(for: domain)[index]
    }

    private var volumeTable: some View {
        let rows = daily.sorted { $0.day > $1.day }
        return Table(rows) {
            TableColumn("Day") { Text($0.day.formatted(date: .abbreviated, time: .omitted)) }
            TableColumn("Plan") { Text($0.series) }
            TableColumn("Added") { Text(Format.bytes($0.dataAdded)).monospacedDigit() }
        }
        .frame(height: 220)
    }

    // MARK: - Repository sizes

    private var repositorySizeCard: some View {
        let volumes = model.configuration.repositories.compactMap { repository -> RepositoryVolume? in
            guard let stats = model.repositoryStats[repository.id] else { return nil }
            return RepositoryVolume(id: repository.id, name: repository.name, bytes: stats.totalSize)
        }
        return Card("Repository size") {
            // Stats that exist but total zero mean the repositories are empty,
            // not that measurement failed: drawing zero-width bars with
            // floating "0 bytes" labels reads as breakage.
            if volumes.isEmpty {
                Text("No repository statistics yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
            } else if volumes.allSatisfy({ $0.bytes == 0 }) {
                Text("The repositories are empty — sizes appear once data is written to them.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
            } else {
                // One series, so the title names it and no legend is needed; the
                // value sits beside each bar as a direct label.
                Chart(volumes) { volume in
                    BarMark(
                        x: .value("Size", volume.bytes),
                        y: .value("Repository", volume.name)
                    )
                    .foregroundStyle(ChartPalette.sequential)
                    .cornerRadius(3)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text(Format.bytes(volume.bytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let bytes = value.as(Int64.self) { Text(Format.bytes(bytes)) }
                        }
                    }
                }
                .frame(height: CGFloat(volumes.count) * 34 + 40)
                .padding(.trailing, 60)
            }
        }
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
                            if date <= .now, hold != nil {
                                // Due, but held: it runs once the hold lifts,
                                // not now. Icon and word in the secondary
                                // colour — a wait, not an alarm.
                                Label("Waiting", systemImage: "pause.circle")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            } else if date <= .now {
                                // Icon + word, not colour alone: orange
                                // caption text on light surfaces sat right
                                // at the contrast floor.
                                Label("Due now", systemImage: "clock.badge.exclamationmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.warning)
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
                // The same window the Problems tile counts. The card's
                // "recent" used to mean "all of history, latest five", which
                // let the tile read a green zero above a nine-day-old failure.
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
                                Text(Format.relative(run.finishedAt))
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
    /// pending or protected line stays quiet, and so do a failure's words —
    /// its glyph wears the warning hue.
    var stateHue: Color {
        if isKnown, !isProtected { return .primary }
        return .secondary
    }
}
