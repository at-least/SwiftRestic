import Charts
import SwiftUI

/// Dashboard: what is protected, what has been written lately, and what is next.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    /// Opens Activity, which reads `model.activityShowsProblemsOnly`. The
    /// problems card must not be a dead end: a failure the user cannot reach
    /// is a failure they cannot fix.
    var onShowProblems: () -> Void = {}

    /// Series are reduced once when the history changes, not on every redraw —
    /// a few hundred runs reduced per frame is visible.
    @State private var daily: [DailyBackupVolume] = []
    @State private var domain: [String] = []
    @State private var selectedDay: Date?
    @State private var showsTable = false

    private static let windowDays = 30

    /// The problems window, shared by the Problems tile and the failures card
    /// so the two can never disagree on what "recent" covers. The predicate
    /// itself is `OverviewMetrics.problems`, which the menu bar's problem
    /// line also draws from.
    private var problemWindowStart: Date {
        Date.now.addingTimeInterval(-7 * 86_400)
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
        .task(id: model.configuration.runs.count) { rebuild() }
        .onChange(of: model.configuration.plans.count) { rebuild() }
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

    /// One plan's protection state as the card states it: what is known,
    /// whether it protects, and the line the user is owed when it does not.
    private struct ProtectionRow: Identifiable {
        let planID: UUID
        let planName: String
        let repositoryID: UUID?
        let stateText: String
        let isKnown: Bool
        let isProtected: Bool
        let didFail: Bool
        var id: UUID { planID }

        var symbolName: String {
            if didFail { return "exclamationmark.triangle.fill" }
            if !isKnown { return "clock.arrow.circlepath" }
            return isProtected ? "checkmark.circle.fill" : "camera"
        }

        var hue: Color {
            if didFail { return Theme.warning }
            if !isKnown { return .secondary }
            return isProtected ? Theme.success : .secondary
        }

        init(
            planID: UUID,
            planName: String,
            repositoryID: UUID?,
            stateText: String,
            isKnown: Bool,
            isProtected: Bool,
            didFail: Bool
        ) {
            self.planID = planID
            self.planName = planName
            self.repositoryID = repositoryID
            self.stateText = stateText
            self.isKnown = isKnown
            self.isProtected = isProtected
            self.didFail = didFail
        }

        /// Derives straight from the plan, so each listing outcome states
        /// only the part that differs.
        init(
            plan: BackupPlan,
            stateText: String,
            isKnown: Bool,
            isProtected: Bool,
            didFail: Bool
        ) {
            planID = plan.id
            planName = plan.name.isEmpty ? "Untitled Plan" : plan.name
            repositoryID = plan.repositoryID
            self.stateText = stateText
            self.isKnown = isKnown
            self.isProtected = isProtected
            self.didFail = didFail
        }
    }

    private var protectionRows: [ProtectionRow] {
        model.configuration.plans.map { plan in
            guard let repositoryID = plan.repositoryID else {
                return ProtectionRow(
                    plan: plan,
                    stateText: "No repository set",
                    isKnown: true, isProtected: false, didFail: false
                )
            }
            let latest = model.snapshots(for: repositoryID, planID: plan.id).first
            switch model.snapshotListingOutcome(for: repositoryID) {
            case .loaded:
                let line: String
                if let latest {
                    line = "Latest backup \(latest.time.formatted(.relative(presentation: .named)))"
                } else if model.snapshots(for: repositoryID).isEmpty {
                    line = "No snapshots yet"
                } else {
                    // The repository has snapshots, but none tagged from this
                    // plan — the same distinction Plan Detail draws. A bare
                    // "No snapshots yet" reads as a false statement about a
                    // repository the user adopted with snapshots already in it.
                    line = "The repository has snapshots, but none from this plan yet."
                }
                return ProtectionRow(plan: plan, stateText: line, isKnown: true, isProtected: latest != nil, didFail: false)
            case let .failed(message):
                return ProtectionRow(
                    plan: plan,
                    stateText: "Can't read snapshots — \(Format.firstSentence(message))",
                    isKnown: false, isProtected: false, didFail: true
                )
            case .idle:
                let checking = model.loadingSnapshots.contains(repositoryID)
                return ProtectionRow(
                    plan: plan,
                    stateText: checking ? "Checking…" : "Snapshot list not loaded yet",
                    isKnown: false, isProtected: false, didFail: false
                )
            }
        }
    }

    /// Protection, the dashboard's actual subject: one row per plan with its
    /// own state texture — protected, empty, unreadable, unknown — instead of
    /// one aggregate number that cannot say which plan it is worried about.
    /// The count survives as a derived caption, never the headline.
    private var protectionCard: some View {
        Card("Protection") {
            VStack(alignment: .leading, spacing: 7) {
                let rows = protectionRows
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
            let rows = protectionRows
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
            // Symbol + words carry the state; the symbol is hidden from
            // VoiceOver because the words beside it say the same thing.
            Image(systemName: row.symbolName)
                .foregroundStyle(row.hue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.planName)
                    .lineLimit(1)
                Text(row.stateText)
                    .font(.caption)
                    .foregroundStyle(row.didFail ? Theme.warning : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
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
        // Worst-of-window, not a flat "problems exist" orange: a failed run
        // reads red here exactly like it does in Recent problems and
        // Activity below, instead of disagreeing with them on the same page.
        let worstProblem = OverviewMetrics.worstProblemOutcome(
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
            Button(action: showProblems) {
                StatTile(
                    title: "Problems (7 days)",
                    value: problems > 0 ? Format.count(problems) : "0",
                    systemImage: worstProblem?.symbolName ?? "checkmark.circle",
                    hue: worstProblem.map(ChartPalette.status) ?? Theme.success,
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
        model.activityShowsProblemsOnly = true
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
                // Same exclusion the scheduler applies: a plan whose repository
                // has vanished must not be announced as due forever.
                let existingRepositories = Set(model.configuration.repositories.map(\.id))
                let upcoming = model.configuration.plans
                    .compactMap { plan -> (BackupPlan, Date)? in
                        guard let repositoryID = plan.repositoryID,
                              existingRepositories.contains(repositoryID)
                        else { return nil }
                        guard let date = plan.nextRunDate else { return nil }
                        return (plan, date)
                    }
                    .sorted { $0.1 < $1.1 }
                    .prefix(5)

                if upcoming.isEmpty {
                    Text("Nothing scheduled.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(upcoming), id: \.0.id) { plan, date in
                        HStack {
                            Label {
                                Text(plan.name).lineLimit(1)
                            } icon: {
                                Circle()
                                    .fill(ChartPalette.color(for: plan))
                                    .frame(width: 6, height: 6)
                            }
                            Spacer()
                            if date <= .now {
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
                    Label {
                        Text("Nothing has failed in the last seven days.")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(Theme.success)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(failures)) { run in
                        Button(action: showProblems) {
                            HStack(spacing: 6) {
                                // Status is never carried by colour alone.
                                Image(systemName: run.outcome.symbolName)
                                    .foregroundStyle(ChartPalette.status(run.outcome))
                                    .accessibilityLabel(run.outcome.displayName)
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
