import Foundation

struct Schedule: Codable, Sendable, Hashable {
    enum Frequency: String, Codable, Sendable, CaseIterable, Identifiable {
        case manual, hourly, daily, weekly
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .manual: "Manually"
            case .hourly: "Hourly"
            case .daily: "Daily"
            case .weekly: "Weekly"
            }
        }
    }

    var frequency: Frequency = .daily

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = c.value(.frequency, default: .daily)
    }

    func summary() -> String {
        switch frequency {
        case .manual: "Manually"
        case .hourly: "Every hour"
        case .daily: "Every day"
        case .weekly: "Every week"
        }
    }

    var interval: TimeInterval? {
        switch frequency {
        case .manual: nil
        case .hourly: 3600
        case .daily: 86_400
        case .weekly: 7 * 86_400
        }
    }

    /// How far behind the moment the window's now can be: its minute clock.
    static let windowClockLag: TimeInterval = 60

    /// An interval after the last run, never a time of day (user decision):
    /// a run missed while the Mac slept or the app was closed starts as soon
    /// as the app is running again.
    func nextRunDate(after lastRun: Date?, now: Date = .now) -> Date? {
        guard let interval else { return nil }
        // A stamp after now comes from a clock that was set ahead; kept, it
        // would hold the plan back until that date. Within a minute of now it
        // is a run of this minute: the window's now is the minute's start
        // (TimelineView(.everyMinute)), and dropping the stamp made the page
        // say Due now until the minute turned.
        guard let lastRun, lastRun <= now.addingTimeInterval(Self.windowClockLag) else { return now }
        return lastRun.addingTimeInterval(interval)
    }
}

/// Recommended or Keep everything: the only two choices (user decision).
struct RetentionPolicy: Codable, Sendable, Hashable {
    /// Off is Keep everything.
    var isEnabled: Bool = true
    /// Recommended's rules. Never stored: a configuration's own rules read
    /// as Recommended. Variables so tests can keep fewer, which makes restic
    /// remove a backup made seconds before.
    var keepLast: Int = 0
    var keepHourly: Int = 24
    var keepDaily: Int = 7
    var keepWeekly: Int = 4
    var keepMonthly: Int = 12
    var keepYearly: Int = 3

    private enum CodingKeys: String, CodingKey { case isEnabled }

    init(
        isEnabled: Bool = true,
        keepLast: Int = 0,
        keepHourly: Int = 24,
        keepDaily: Int = 7,
        keepWeekly: Int = 4,
        keepMonthly: Int = 12,
        keepYearly: Int = 3
    ) {
        self.isEnabled = isEnabled
        self.keepLast = keepLast
        self.keepHourly = keepHourly
        self.keepDaily = keepDaily
        self.keepWeekly = keepWeekly
        self.keepMonthly = keepMonthly
        self.keepYearly = keepYearly
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.value(.isEnabled, default: true)
    }

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

    /// restic refuses `forget` with no `--keep-*` rule (it would delete every
    /// snapshot). Guarded here rather than at each call site.
    var isSafeToRun: Bool { isEnabled && !forgetArguments.isEmpty }

    var summary: String {
        guard isEnabled else { return "Keep everything" }
        guard isSafeToRun else { return "No rules set" }
        // Counts of backups, not spans: restic keeps the newest backup of
        // each of the last N hours (days, …) that hold one, so a daily plan's
        // 24 hourly backups reach back 24 days. "24h" read as either.
        let rules = [
            (keepLast, keepLast == 1 ? "the latest one" : "the latest \(keepLast)"), (keepHourly, "\(keepHourly) hourly"),
            (keepDaily, "\(keepDaily) daily"), (keepWeekly, "\(keepWeekly) weekly"),
            (keepMonthly, "\(keepMonthly) monthly"), (keepYearly, "\(keepYearly) yearly"),
        ].filter { $0.0 > 0 }
        if rules.count == 1, keepLast == 1 { return "Keep the latest backup" }
        let noun = rules.count == 1 && rules[0].0 == 1 ? "backup" : "backups"
        return "Keep " + Format.list(rules.map(\.1)) + " " + noun
    }
}

struct BackupPlan: Identifiable, Codable, Sendable, Hashable {
    var id: UUID = UUID()
    var repositoryID: UUID?
    /// The folder or file the plan backs up, as typed or picked (a tilde
    /// expands at run time). Fixed once the plan is saved, like its
    /// repository: restic keeps one history per set of paths (a backup's
    /// parent is the newest of the same host whose paths cover its own, and
    /// retention groups by `host,paths`; restic 0.19.1), so another path is
    /// another plan, and a list of folders that lost one for a run would
    /// split its history and retention. Older builds saved a list
    /// (`sources`), split into one plan per entry at load
    /// (`AppConfiguration`).
    var path: String = ""

    var resolvedPath: String { ResticService.expandTilde(path) }

    /// The patterns the user added, as typed or picked: the editor's
    /// *Also skip* list. What the switches and the fixed rules leave out is
    /// not among them — a run passes those beside them (`excludesToPass`).
    var excludePatterns: [String] = []
    var tags: [String] = []
    var schedule = Schedule()
    var retention = RetentionPolicy()
    var hooks: [BackupHook] = []
    var lastRunAt: Date?
    var lastSuccessAt: Date?
    /// The last backup the quiet-plan alert last named this plan for
    /// (`StaleAlert`): one notification per stretch, re-armed by a newer
    /// success.
    var staleAlertedFor: Date?
    /// Created here and not yet backed up: its first success is announced
    /// whatever `notifyOnSuccess` says. Off for an adopted plan and a plan
    /// saved before this existed, whose first backup is long past.
    var announcesFirstBackup = false
    /// What developer tools download or build again
    /// (`ExcludeCategory.rebuildableGroups`). On for new plans.
    var skipsDeveloperFiles: Bool = true
    /// Simulators, containers and virtual machines
    /// (`ExcludeCategory.machineGroups`): their disks are recreated empty, so
    /// what is inside may be the only copy. Off for new plans (user decision).
    var skipsMachines: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, repositoryID, path, excludePatterns, tags, schedule, retention
        case hooks, lastRunAt, lastSuccessAt, staleAlertedFor
        case skipsDeveloperFiles, skipsMachines, announcesFirstBackup
    }

    /// Read, never written. `isEnabled`: a plan an older build switched off
    /// stays stopped. `skipDeveloperGroups`: older builds ticked each language
    /// on its own; any group turns on the switch that now holds it.
    private enum LegacyKeys: String, CodingKey { case isEnabled, skipDeveloperGroups }

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        repositoryID = c.optional(.repositoryID)
        path = c.value(.path, default: "")
        tags = c.value(.tags, default: [])
        schedule = c.value(.schedule, default: Schedule())
        retention = c.value(.retention, default: RetentionPolicy())
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if !legacy.value(.isEnabled, default: true) {
            schedule.frequency = .manual
        }
        hooks = c.value(.hooks, default: [StoredHook]()).compactMap(\.hook)
        lastRunAt = c.optional(.lastRunAt)
        lastSuccessAt = c.optional(.lastSuccessAt)
        staleAlertedFor = c.optional(.staleAlertedFor)
        announcesFirstBackup = c.value(.announcesFirstBackup, default: false)
        // A plan saved without either key asked for neither, so its backups
        // do not change under a switch it never turned on.
        let groups = legacy.value(.skipDeveloperGroups, default: [String]())
        skipsDeveloperFiles = c.value(.skipsDeveloperFiles, default: !groups.isEmpty)
        skipsMachines = c.value(.skipsMachines, default: groups.contains {
            ExcludeCategory(rawValue: $0).map(ExcludeCategory.machineGroups.contains) ?? false
        })
        // A duplicate here means a hand-edited config, and duplicates would
        // give the list's rows colliding identities. First occurrence wins.
        // Older builds kept the rules the app now passes itself among these.
        excludePatterns = withoutSwitchRules(Self.withoutDuplicates(c.value(.excludePatterns, default: [])))
    }

    static let defaultExcludes = ExcludeRule.defaults.map(\.pattern)

    private static func patterns(of rules: [ExcludeRule], in groups: [ExcludeCategory]) -> [String] {
        rules.filter { groups.contains($0.category) }.map(\.pattern)
    }

    static let developerExcludes = patterns(of: ExcludeRule.developer, in: ExcludeCategory.rebuildableGroups)
    static let machineExcludes = patterns(of: ExcludeRule.developer, in: ExcludeCategory.machineGroups)

    /// `--exclude-if-present` file names: restic leaves out the contents of a
    /// folder holding one and keeps the marker itself.
    var developerMarkers: [String] {
        skipsDeveloperFiles ? ExcludeRule.developerMarkers.map(\.pattern) : []
    }

    /// The rules the app passes itself, whatever the path, since a rule naming
    /// nothing under it matches nothing. A plan stores the switches, not their
    /// rules, so a rule a later build adds reaches every plan with its switch on.
    private var switchExcludes: [String] {
        Self.defaultExcludes
            + (skipsDeveloperFiles ? Self.developerExcludes : [])
            + (skipsMachines ? Self.machineExcludes : [])
    }

    var excludesToPass: [String] {
        Self.withoutDuplicates(switchExcludes + excludePatterns)
    }

    func withoutSwitchRules(_ patterns: [String]) -> [String] {
        let passed = Set(switchExcludes)
        return patterns.filter { !passed.contains($0) }
    }

    /// The switches a backup's recorded excludes imply. A group counts when
    /// most of its rules are there: a later build may add a rule an older list
    /// never held, and a few of them are rows the user typed.
    mutating func readSwitches(fromRecorded patterns: [String]) {
        let present = Set(patterns)
        func holds(_ group: ExcludeCategory) -> Bool {
            let rules = Self.patterns(of: ExcludeRule.developer, in: [group])
            return rules.filter(present.contains).count * 2 > rules.count
        }
        skipsDeveloperFiles = ExcludeCategory.rebuildableGroups.contains(where: holds)
        skipsMachines = ExcludeCategory.machineGroups.contains(where: holds)
    }

    static func withoutDuplicates(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    var isConfigurationComplete: Bool {
        repositoryID != nil && !path.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static let incompleteConfigurationReason = "This plan needs a backup location and a folder or file to back up"

    static let busyRepositoryReason = "This location is in use. Try again when the work finishes."

    /// The same words on a plan's page, a repository's Status row and
    /// the menu bar's summary: every surface's name for a plan with none.
    static let noBackupLocationReason = "No backup location set"

    /// What every surface calls the plan — it has no name of its own: the
    /// last component of its path, the folder's or file's name. When
    /// another of `plans` backs up, to the same repository, a path ending
    /// in the same name, each reads as its path, tilde-abbreviated, so the
    /// two never look alike. "Untitled Plan" while it has no path. Older
    /// builds stored a name; a configuration's key is ignored.
    func label(among plans: [BackupPlan]) -> String {
        let name = Self.lastComponent(of: path)
        guard !name.isEmpty else { return "Untitled Plan" }
        let twin = plans.contains {
            $0.id != id && $0.repositoryID == repositoryID && Self.lastComponent(of: $0.path) == name
        }
        return twin ? (resolvedPath as NSString).abbreviatingWithTildeInPath : name
    }

    private static func lastComponent(of path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "" : (ResticService.expandTilde(trimmed) as NSString).lastPathComponent
    }

    /// The scheduler owns this plan's timing, complete or not — distinct
    /// from `runsOnSchedule`, which also asks that the plan can run.
    var isScheduled: Bool {
        schedule.frequency != .manual
    }

    var runsOnSchedule: Bool {
        isScheduled && isConfigurationComplete
    }

    func dueSlot(at now: Date) -> Date? {
        schedule.nextRunDate(after: lastRunAt, now: now).flatMap { $0 <= now ? $0 : nil }
    }

    /// The stored plan wins over the editor's draft for the model-written
    /// fields the draft may hold stale: the run stamps (`markPlanRun`), the
    /// quiet-plan alert's mark.
    /// A new model-written field joins this list, or the next save reverts it
    /// to the draft.
    func merging(draft: BackupPlan) -> BackupPlan {
        var merged = draft
        merged.lastRunAt = lastRunAt
        merged.lastSuccessAt = lastSuccessAt
        merged.staleAlertedFor = staleAlertedFor
        merged.announcesFirstBackup = announcesFirstBackup
        return merged
    }
}
