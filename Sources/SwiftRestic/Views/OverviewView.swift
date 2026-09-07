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

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            if let banner = model.banner {
                BannerView(banner: banner)
            }
            statTiles
            volumeCard
            repositorySizeCard
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

    private var statTiles: some View {
        let latestSnapshots = model.configuration.plans.map { plan in
            model.snapshots(for: plan.repositoryID, planID: plan.id).first
        }
        let plansWithSnapshots = latestSnapshots.compactMap { $0 }.count
        let totalPlans = model.configuration.plans.count
        let problems = OverviewMetrics.problemCount(
            runs: model.configuration.runs,
            since: .now.addingTimeInterval(-7 * 86_400)
        )
        return HStack(spacing: Theme.Space.tile) {
            // Protection is coverage, not bytes: a sum nobody can act on
            // ("5 bytes protected") reads as nonsense on the dashboard's
            // first tile. Per-plan detail lives in the tooltip.
            StatTile(
                title: "Protected",
                value: totalPlans == 0
                    ? "—"
                    : "\(plansWithSnapshots) of \(totalPlans)",
                systemImage: "lock.shield",
                help: totalPlans == 0
                    ? "Add a backup plan to start protecting your data."
                    : helpLines(latestSnapshots: latestSnapshots)
            )
            StatTile(
                title: "Repositories",
                value: Format.count(model.configuration.repositories.count),
                systemImage: "externaldrive"
            )
            StatTile(
                title: "Plans",
                value: Format.count(model.configuration.plans.count),
                systemImage: "calendar"
            )
            if problems > 0 {
                Button(action: showProblems) {
                    StatTile(
                        title: "Problems (7 days)",
                        value: Format.count(problems),
                        systemImage: "exclamationmark.triangle.fill",
                        hue: Theme.warning
                    )
                }
                .buttonStyle(HoverableButtonStyle())
                .accessibilityLabel("Problems in the last 7 days: \(problems). Show them in Activity")
            } else {
                StatTile(
                    title: "Problems (7 days)",
                    value: "0",
                    systemImage: "checkmark.circle",
                    hue: Theme.success
                )
            }
        }
    }

    /// One line per plan for the Protected tile's tooltip: which plans have
    /// snapshots and how fresh the latest one is.
    private func helpLines(latestSnapshots: [Snapshot?]) -> String {
        guard !model.configuration.plans.isEmpty else {
            return "Add a backup plan to start protecting your data."
        }
        return zip(model.configuration.plans, latestSnapshots)
            .map { plan, snapshot in
                snapshot.map { "\(plan.name): latest \($0.time.formatted(.relative(presentation: .named)))" }
                    ?? "\(plan.name): no snapshots yet"
            }
            .joined(separator: "\n")
    }

    private func showProblems() {
        model.activityShowsProblemsOnly = true
        onShowProblems()
    }

    // MARK: - Daily volume

    private var volumeCard: some View {
        Card("Data added per day", systemImage: "chart.bar.fill") {
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
            // optional.
            Picker("Data view", selection: $showsTable) {
                Image(systemName: "chart.bar").tag(false).accessibilityLabel("Chart")
                Image(systemName: "tablecells").tag(true).accessibilityLabel("Table")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 90)
        }
    }

    private var volumeChart: some View {
        Chart(daily) { point in
            BarMark(
                x: .value("Day", point.day, unit: .day),
                y: .value("Added", point.dataAdded)
            )
            .foregroundStyle(by: .value("Plan", point.series))
            // A 2px surface gap keeps adjacent stack segments legible.
            .cornerRadius(3)
        }
        .chartForegroundStyleScale(
            domain: domain,
            range: ChartPalette.range(for: domain)
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

    private func colorFor(_ series: String) -> Color {
        guard let index = domain.firstIndex(of: series) else { return ChartPalette.other }
        return ChartPalette.range(for: domain)[index]
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
        return Card("Repository size", systemImage: "internaldrive.fill") {
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
        Card("Next runs", systemImage: "clock.arrow.circlepath") {
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
                                    .fill(Theme.tint.opacity(0.7))
                                    .frame(width: 6, height: 6)
                            }
                            Spacer()
                            if date <= .now {
                                Text("Due now")
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
        Card("Recent problems", systemImage: "exclamationmark.bubble.fill") {
            VStack(alignment: .leading, spacing: 7) {
                let failures = model.configuration.runs
                    .filter { $0.outcome == .failed || $0.outcome == .completedWithErrors }
                    .prefix(5)

                if failures.isEmpty {
                    Label {
                        Text("Nothing has failed recently.")
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
                                Text(Format.relative(run.startedAt))
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
