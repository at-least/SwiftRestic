import Foundation
import Testing

/// The quiet-plan alert: a scheduled plan with no successful backup for
/// longer than its window is named once per stretch — never per tick — and
/// its next success re-arms it. Paused, manual, incomplete and running
/// plans are never named, and a weekly plan is not named for the week its
/// schedule itself waits.
@Suite("Quiet-plan alert")
struct StaleAlertTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 86400

    private func plan(_ frequency: Schedule.Frequency = .daily, lastSuccessDaysAgo: Double?) -> BackupPlan {
        var plan = BackupPlan()
        plan.name = "Documents"
        plan.repositoryID = UUID()
        plan.sources = ["/Users/someone/Documents"]
        plan.schedule.frequency = frequency
        plan.lastSuccessAt = lastSuccessDaysAgo.map { now.addingTimeInterval(-$0 * day) }
        return plan
    }

    private func due(
        _ plans: [BackupPlan], days: Int = 7, running: Set<UUID> = [], snapshots: [UUID: Date] = [:],
        awayDrives: (BackupPlan) -> [String] = { _ in [] }
    ) -> [StalePlanAlert] {
        StaleAlert.due(plans: plans, latestSnapshotTimes: snapshots, thresholdDays: days, running: running, now: now, awayDrives: awayDrives)
    }

    @Test("a daily plan past the window is named once, with the days and the moment it counts from")
    func dailyBreach() throws {
        let quiet = plan(lastSuccessDaysAgo: 8.5)
        let alerts = due([quiet, plan(lastSuccessDaysAgo: 6.9)])
        #expect(alerts == [StalePlanAlert(planID: quiet.id, lastBackupAt: try #require(quiet.lastSuccessAt), days: 8)])

        // Alerted for this stretch: not again, however many ticks pass.
        var alerted = quiet
        alerted.staleAlertedFor = quiet.lastSuccessAt
        #expect(due([alerted]).isEmpty)
        // A newer success re-arms it: the next stretch is named in its turn.
        alerted.lastSuccessAt = now.addingTimeInterval(-7.5 * day)
        #expect(due([alerted]).map(\.days) == [7])
    }

    @Test("a plan's history counts when the plan has no run of its own; a plan with neither is not named")
    func lastBackupMoment() throws {
        let adopted = plan(lastSuccessDaysAgo: nil)
        let snapshot = now.addingTimeInterval(-9 * day)
        #expect(due([adopted], snapshots: [adopted.id: snapshot])
            == [StalePlanAlert(planID: adopted.id, lastBackupAt: snapshot, days: 9)])
        #expect(due([adopted]).isEmpty)
    }

    @Test("the window is the threshold, or one schedule interval and a day when that is longer")
    func scheduleWindow() {
        // Weekly: due again exactly seven days after its last success, so
        // a bare seven-day threshold would name it before every run.
        #expect(due([plan(.weekly, lastSuccessDaysAgo: 7.5)]).isEmpty)
        #expect(due([plan(.weekly, lastSuccessDaysAgo: 8.1)]).map(\.days) == [8])
        #expect(due([plan(.weekly, lastSuccessDaysAgo: 4)], days: 3).isEmpty)
        // Hourly and daily: the threshold is the longer of the two.
        #expect(due([plan(.hourly, lastSuccessDaysAgo: 3.2)], days: 3).map(\.days) == [3])
        #expect(StaleAlert.window(thresholdDays: 3, schedule: plan(.daily, lastSuccessDaysAgo: nil).schedule) == 3 * day)
        #expect(StaleAlert.window(thresholdDays: 3, schedule: plan(.weekly, lastSuccessDaysAgo: nil).schedule) == 8 * day)
    }

    @Test("paused, manual, incomplete and running plans are never named, and Off names none")
    func exemptions() {
        var off = plan(lastSuccessDaysAgo: 20)
        off.isEnabled = false
        var timed = plan(lastSuccessDaysAgo: 20)
        timed.pausedUntil = now.addingTimeInterval(3600)
        let manual = plan(.manual, lastSuccessDaysAgo: 20)
        var incomplete = plan(lastSuccessDaysAgo: 20)
        incomplete.sources = []
        let running = plan(lastSuccessDaysAgo: 20)
        #expect(due([off, timed, manual, incomplete, running], running: [running.id]).isEmpty)
        #expect(due([plan(lastSuccessDaysAgo: 20)], days: 0).isEmpty)
    }

    @Test("the notification names the plan with its repository, the days, and the last backup")
    func wording() {
        let last = now.addingTimeInterval(-8.5 * day)
        let text = StaleAlert.notification(planTitle: "Documents (Home NAS)", alert: StalePlanAlert(planID: UUID(), lastBackupAt: last, days: 8))
        #expect(text.title == "Documents (Home NAS)")
        #expect(text.body == "No successful backup in 8 days — the last one was \(Format.timestamp(last)).")
    }

    @Test("a plan backing up around an away drive is named from its last whole backup, for the drive, and re-armed by the next whole one")
    func partialBackups() throws {
        var partial = plan(lastSuccessDaysAgo: 0.5)
        partial.sources = ["/Users/someone/Documents", "/Volumes/Archive SSD/Photos", "/Volumes/Archive SSD/Music"]
        let whole = now.addingTimeInterval(-9 * day)
        partial.lastCompleteBackupAt = whole
        let alert = try #require(due([partial], awayDrives: { _ in ["Archive SSD"] }).first)
        #expect(alert == StalePlanAlert(planID: partial.id, lastBackupAt: whole, days: 9, isPartial: true, awayDrives: ["Archive SSD"]))
        let text = StaleAlert.notification(planTitle: "Documents (Home NAS)", alert: alert)
        #expect(text.body == "“Archive SSD” has not been backed up in 9 days — the last backup that included it was \(Format.timestamp(whole)); the plan's other folders are still backed up.")
        // Two drives; and none known to be away now.
        let two = StalePlanAlert(planID: partial.id, lastBackupAt: whole, days: 9, isPartial: true, awayDrives: ["Archive SSD", "Photos"])
        #expect(StaleAlert.notification(planTitle: "Documents", alert: two).body.hasPrefix("“Archive SSD” and “Photos” have not been backed up in 9 days — the last backup that included them was"))
        let unnamed = StalePlanAlert(planID: partial.id, lastBackupAt: whole, days: 9, isPartial: true)
        #expect(StaleAlert.notification(planTitle: "Documents", alert: unnamed).body
            == "Some folders have not been backed up in 9 days — the last backup that included every folder was \(Format.timestamp(whole)); the others are still backed up.")

        // Named once per stretch; a newer whole backup re-arms it; a whole
        // backup inside the window names nothing.
        var alerted = partial
        alerted.staleAlertedFor = whole
        #expect(due([alerted], awayDrives: { _ in ["Archive SSD"] }).isEmpty)
        alerted.lastCompleteBackupAt = now.addingTimeInterval(-8 * day)
        #expect(due([alerted]).map(\.days) == [8])
        alerted.lastCompleteBackupAt = now.addingTimeInterval(-2 * day)
        #expect(due([alerted]).isEmpty)
        // A plan stamped before the field existed counts from its last success.
        #expect(due([plan(lastSuccessDaysAgo: 0.5)]).isEmpty)
        // The drives: the plan's folders on volumes not mounted now, each named once.
        #expect(StaleAlert.awayDrives(of: partial, isMounted: { $0.hasPrefix("/Volumes/") ? false : nil }) == ["Archive SSD"])
        #expect(StaleAlert.awayDrives(of: partial, isMounted: { _ in true }).isEmpty)
        // The stamp survives an editor save, as the others do.
        var draft = partial
        draft.lastCompleteBackupAt = nil
        #expect(partial.merging(draft: draft).lastCompleteBackupAt == whole)
    }

    @Test("the setting is on at seven days unless the file says otherwise, and the alert mark survives an editor save")
    func persistence() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.staleAlertDays == 7)
        var stored = plan(lastSuccessDaysAgo: 9)
        stored.staleAlertedFor = stored.lastSuccessAt
        var draft = stored
        draft.staleAlertedFor = nil
        #expect(stored.merging(draft: draft).staleAlertedFor == stored.lastSuccessAt)
    }
}
