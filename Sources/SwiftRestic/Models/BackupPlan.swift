import Foundation

/// How often a plan should run by itself.
struct Schedule: Codable, Sendable, Hashable {
    enum Frequency: String, Codable, Sendable, CaseIterable, Identifiable {
        case manual, hourly, daily, weekly
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .manual: "Manually"
            case .hourly: "Every N hours"
            case .daily: "Daily"
            case .weekly: "Weekly"
            }
        }
    }

    var frequency: Frequency = .daily
    /// Used when `frequency == .hourly`.
    var intervalHours: Int = 4
    var hour: Int = 2
    var minute: Int = 0
    /// 1 = Sunday, matching `Calendar.component(.weekday:)`.
    var weekday: Int = 2

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = c.value(.frequency, default: .daily)
        intervalHours = c.value(.intervalHours, default: 4)
        hour = c.value(.hour, default: 2)
        minute = c.value(.minute, default: 0)
        weekday = c.value(.weekday, default: 2)
    }

    var summary: String {
        switch frequency {
        case .manual: return "Manually"
        case .hourly: return intervalHours == 1 ? "Every hour" : "Every \(intervalHours) hours"
        case .daily: return String(format: "Daily at %02d:%02d", hour, minute)
        case .weekly:
            let name = Calendar.current.weekdaySymbols[max(0, min(6, weekday - 1))]
            return String(format: "%@ at %02d:%02d", name, hour, minute)
        }
    }

    /// The next moment this schedule is due, given when it last ran.
    /// Returns `nil` for manual plans.
    func nextRunDate(after lastRun: Date?, now: Date = .now, calendar: Calendar = .current) -> Date? {
        switch frequency {
        case .manual:
            return nil
        case .hourly:
            let step = TimeInterval(max(1, intervalHours) * 3600)
            guard let lastRun else { return now }
            return lastRun.addingTimeInterval(step)
        case .daily:
            return nextWallClock(after: lastRun, now: now, calendar: calendar, matchingWeekday: nil)
        case .weekly:
            return nextWallClock(after: lastRun, now: now, calendar: calendar, matchingWeekday: weekday)
        }
    }

    private func nextWallClock(
        after lastRun: Date?,
        now: Date,
        calendar: Calendar,
        matchingWeekday: Int?
    ) -> Date? {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        if let matchingWeekday { components.weekday = matchingWeekday }

        // The most recent firing time at or before `now`.
        guard let previous = calendar.nextDate(
            after: now,
            matching: components,
            matchingPolicy: .nextTime,
            direction: .backward
        ) else { return nil }

        // Due now if that firing time has not been covered by the last run.
        if lastRun == nil || lastRun! < previous { return previous }

        return calendar.nextDate(
            after: now,
            matching: components,
            matchingPolicy: .nextTime,
            direction: .forward
        )
    }
}

/// `restic forget` retention rules applied after a successful backup.
struct RetentionPolicy: Codable, Sendable, Hashable {
    var isEnabled: Bool = true
    var keepLast: Int = 0
    var keepHourly: Int = 24
    var keepDaily: Int = 7
    var keepWeekly: Int = 4
    var keepMonthly: Int = 12
    var keepYearly: Int = 3
    /// Run `--prune` as part of `forget`. Slow, so off by default.
    var runPrune: Bool = false

    init() {}

    init(
        isEnabled: Bool = true,
        keepLast: Int = 0,
        keepHourly: Int = 24,
        keepDaily: Int = 7,
        keepWeekly: Int = 4,
        keepMonthly: Int = 12,
        keepYearly: Int = 3,
        runPrune: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.keepLast = keepLast
        self.keepHourly = keepHourly
        self.keepDaily = keepDaily
        self.keepWeekly = keepWeekly
        self.keepMonthly = keepMonthly
        self.keepYearly = keepYearly
        self.runPrune = runPrune
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.value(.isEnabled, default: true)
        keepLast = c.value(.keepLast, default: 0)
        keepHourly = c.value(.keepHourly, default: 24)
        keepDaily = c.value(.keepDaily, default: 7)
        keepWeekly = c.value(.keepWeekly, default: 4)
        keepMonthly = c.value(.keepMonthly, default: 12)
        keepYearly = c.value(.keepYearly, default: 3)
        runPrune = c.value(.runPrune, default: false)
    }

    /// The `--keep-*` flags, omitting rules set to zero.
    var forgetArguments: [String] {
        var args: [String] = []
        func add(_ flag: String, _ value: Int) {
            if value > 0 { args += [flag, String(value)] }
        }
        add("--keep-last", keepLast)
        add("--keep-hourly", keepHourly)
        add("--keep-daily", keepDaily)
        add("--keep-weekly", keepWeekly)
        add("--keep-monthly", keepMonthly)
        add("--keep-yearly", keepYearly)
        return args
    }

    /// restic refuses to run `forget` with no `--keep-*` rule, which would delete
    /// every snapshot. Guard against that here rather than at the call site.
    var isSafeToRun: Bool { isEnabled && !forgetArguments.isEmpty }

    var summary: String {
        guard isEnabled else { return "Keep everything" }
        guard isSafeToRun else { return "No rules set" }
        var parts: [String] = []
        if keepLast > 0 { parts.append("\(keepLast) latest") }
        if keepHourly > 0 { parts.append("\(keepHourly)h") }
        if keepDaily > 0 { parts.append("\(keepDaily)d") }
        if keepWeekly > 0 { parts.append("\(keepWeekly)w") }
        if keepMonthly > 0 { parts.append("\(keepMonthly)m") }
        if keepYearly > 0 { parts.append("\(keepYearly)y") }
        return "Keep " + parts.joined(separator: ", ")
    }
}

/// A set of folders backed up to one repository on a schedule.
struct BackupPlan: Identifiable, Codable, Sendable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var repositoryID: UUID?
    var sources: [String] = []
    var excludePatterns: [String] = BackupPlan.defaultExcludes
    var excludeCaches: Bool = true
    var oneFileSystem: Bool = false
    var tags: [String] = []
    var schedule = Schedule()
    var retention = RetentionPolicy()
    var isEnabled: Bool = true
    /// Shell commands run around each backup.
    var hooks: [BackupHook] = []
    var lastRunAt: Date?
    var lastSuccessAt: Date?
    /// Stable slot in `ChartPalette`'s categorical order, assigned when the
    /// plan is created so its colour survives reordering and shows up in the
    /// sidebar, tiles and charts alike. `nil` on plans from older configs,
    /// which fall back to a hash of their ID.
    var chartIndex: Int?

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        name = c.value(.name, default: "")
        repositoryID = c.optional(.repositoryID)
        sources = c.value(.sources, default: [])
        excludePatterns = c.value(.excludePatterns, default: BackupPlan.defaultExcludes)
        excludeCaches = c.value(.excludeCaches, default: true)
        oneFileSystem = c.value(.oneFileSystem, default: false)
        tags = c.value(.tags, default: [])
        schedule = c.value(.schedule, default: Schedule())
        retention = c.value(.retention, default: RetentionPolicy())
        isEnabled = c.value(.isEnabled, default: true)
        hooks = c.value(.hooks, default: [])
        lastRunAt = c.optional(.lastRunAt)
        lastSuccessAt = c.optional(.lastSuccessAt)
        chartIndex = c.optional(.chartIndex)
    }

    /// Noise that is never worth storing, mirroring what Arq excludes by default.
    static let defaultExcludes = [
        ".DS_Store",
        "**/node_modules",
        "**/.git/objects",
        "~/Library/Caches",
        "~/Library/Containers/*/Data/Library/Caches",
        "~/.Trash",
        "~/Library/Application Support/Steam",
    ]

    var isConfigurationComplete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && repositoryID != nil
            && !sources.isEmpty
    }

    var nextRunDate: Date? {
        guard isEnabled else { return nil }
        return schedule.nextRunDate(after: lastRunAt)
    }
}
