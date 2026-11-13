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

    var interval: TimeInterval? {
        switch frequency {
        case .manual: nil
        case .hourly: 3600
        case .daily: 86_400
        case .weekly: 7 * 86_400
        }
    }

    /// The window's now is the minute's start (TimelineView(.everyMinute)).
    static let windowClockLag: TimeInterval = 60

    /// An interval after the last run, never a time of day (user decision):
    /// a run missed while the Mac slept or the app was closed starts as soon
    /// as the app is running again.
    func nextRunDate(after lastRun: Date?, now: Date) -> Date? {
        guard let interval else { return nil }
        // A stamp after now comes from a clock set ahead and would hold the
        // plan back until that date. Within a minute of now it is a run of
        // this minute; dropping it would show Due now until the minute turns.
        guard let lastRun, lastRun <= now.addingTimeInterval(Self.windowClockLag) else { return now }
        return lastRun.addingTimeInterval(interval)
    }
}

/// Every plan removes old backups with these rules after each backup (user
/// decision: no switch, no Keep everything). Never stored. Variables so
/// tests can keep fewer, which makes restic remove a backup made seconds
/// before.
struct RetentionPolicy: Sendable, Hashable {
    var keepLast: Int = 0
    var keepHourly: Int = 24
    var keepDaily: Int = 7
    var keepWeekly: Int = 4
    var keepMonthly: Int = 12
    var keepYearly: Int = 3

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
}

struct BackupPlan: Identifiable, Codable, Sendable, Hashable {
    var id: UUID = UUID()
    var repositoryID: UUID?
    /// As typed or picked; a tilde expands at run time. Fixed once the plan
    /// is saved, like its
    /// repository: restic keeps one history per set of paths (a backup's
    /// parent is the newest of the same host whose paths cover its own, and
    /// retention groups by `host,paths`; restic 0.19.1), so another path is
    /// another plan, and a list of folders that lost one for a run would
    /// split its history and retention.
    var path: String = ""

    var resolvedPath: String { ResticService.expandTilde(path) }

    /// The editor's Excluded Items list. The always-applied rules are not
    /// stored here; a run adds them (`excludesToPass`).
    var excludePatterns: [String] = []
    var tags: [String] = []
    var schedule = Schedule()
    var retention = RetentionPolicy()
    var lastRunAt: Date?
    var lastSuccessAt: Date?
    /// The last backup the quiet-plan alert (`StaleAlert`) named this plan
    /// for: one notification per stretch, re-armed by a newer success.
    var staleAlertedFor: Date?
    /// Created here and not yet backed up: its first success is the one
    /// success announced. Off for an adopted plan.
    var announcesFirstBackup = false

    private enum CodingKeys: String, CodingKey {
        case id, repositoryID, path, excludePatterns, tags, schedule
        case lastRunAt, lastSuccessAt, staleAlertedFor, announcesFirstBackup
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        repositoryID = c.optional(.repositoryID)
        path = c.value(.path, default: "")
        tags = c.value(.tags, default: [])
        schedule = c.value(.schedule, default: Schedule())
        lastRunAt = c.optional(.lastRunAt)
        lastSuccessAt = c.optional(.lastSuccessAt)
        staleAlertedFor = c.optional(.staleAlertedFor)
        announcesFirstBackup = c.value(.announcesFirstBackup, default: false)
        // A duplicate means a hand-edited config and would give the list's
        // rows colliding identities. An always-applied rule is passed anyway.
        excludePatterns = Self.withoutAppliedRules(Self.withoutDuplicates(c.value(.excludePatterns, default: [])))
    }

    /// Every plan passes them, whatever its path: a rule naming nothing
    /// under it matches nothing. Not stored on the plan, so a rule added
    /// here reaches every plan.
    static let appliedExcludes = (ExcludeRule.defaults + ExcludeRule.developer).map(\.pattern)

    /// `--exclude-if-present` file names: restic leaves out the contents of a
    /// folder holding one and keeps the marker itself.
    static let excludeMarkers = ExcludeRule.developerMarkers.map(\.pattern)

    var excludesToPass: [String] {
        Self.withoutDuplicates(Self.appliedExcludes + excludePatterns)
    }

    static func withoutAppliedRules(_ patterns: [String]) -> [String] {
        let passed = Set(appliedExcludes)
        return patterns.filter { !passed.contains($0) }
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

    static let noBackupLocationReason = "No backup location set"

    /// A plan has no name of its own: every surface calls it by its path's
    /// last component. When another of `plans` in the same repository ends
    /// in the same name, each reads as its tilde-abbreviated path.
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

    /// Complete or not, unlike `runsOnSchedule`.
    var isScheduled: Bool {
        schedule.frequency != .manual
    }

    var runsOnSchedule: Bool {
        isScheduled && isConfigurationComplete
    }

    func dueSlot(at now: Date) -> Date? {
        schedule.nextRunDate(after: lastRunAt, now: now).flatMap { $0 <= now ? $0 : nil }
    }

    /// The fields the editor does not edit come from the stored plan: the
    /// run stamps, the quiet-plan alert's mark, and the schedule the plan
    /// page saves while the editor is open. A new field
    /// written outside the editor joins this list, or the next save reverts
    /// it to the draft.
    func merging(draft: BackupPlan) -> BackupPlan {
        var merged = draft
        merged.lastRunAt = lastRunAt
        merged.lastSuccessAt = lastSuccessAt
        merged.staleAlertedFor = staleAlertedFor
        merged.announcesFirstBackup = announcesFirstBackup
        merged.schedule = schedule
        return merged
    }
}
