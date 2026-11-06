import Foundation
import Testing

@Suite("Quiet-plan alert")
struct StaleAlertTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 86400

    private func plan(_ frequency: Schedule.Frequency = .daily, lastSuccessDaysAgo: Double?) -> BackupPlan {
        var plan = BackupPlan()
        plan.repositoryID = UUID()
        plan.path = "/Users/someone/Documents"
        plan.schedule.frequency = frequency
        plan.lastSuccessAt = lastSuccessDaysAgo.map { now.addingTimeInterval(-$0 * day) }
        return plan
    }

    private func due(
        _ plans: [BackupPlan], running: Set<UUID> = [], snapshots: [UUID: Date] = [:]
    ) -> [StalePlanAlert] {
        StaleAlert.due(plans: plans, latestSnapshotTimes: snapshots, running: running, now: now)
    }

    @Test("a daily plan past the window is named once, with the days and the moment it counts from")
    func dailyBreach() throws {
        let quiet = plan(lastSuccessDaysAgo: 8.5)
        let alerts = due([quiet, plan(lastSuccessDaysAgo: 6.9)])
        #expect(alerts == [StalePlanAlert(planID: quiet.id, lastBackupAt: try #require(quiet.lastSuccessAt), days: 8)])

        var alerted = quiet
        alerted.staleAlertedFor = quiet.lastSuccessAt
        #expect(due([alerted]).isEmpty)
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
    func window() {
        #expect(StaleAlert.window(schedule: plan(.daily, lastSuccessDaysAgo: nil).schedule) == 7 * day)
        #expect(StaleAlert.window(schedule: plan(.weekly, lastSuccessDaysAgo: nil).schedule) == 8 * day)
    }

    @Test("a scheduled plan is named; manual, incomplete and running plans are not")
    func exemptions() {
        let scheduled = plan(lastSuccessDaysAgo: 20)
        let manual = plan(.manual, lastSuccessDaysAgo: 20)
        var incomplete = plan(lastSuccessDaysAgo: 20)
        incomplete.path = ""
        let running = plan(lastSuccessDaysAgo: 20)
        #expect(due([scheduled, manual, incomplete, running], running: [running.id]).map(\.planID) == [scheduled.id])
    }

    @Test("a config from before the switches went still loads, and a saved Off has no effect")
    func oldSettingsAreIgnored() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"staleAlertDays": 0, "notifyOnFailure": false, "notifyOnSuccess": true}"#.utf8))
        #expect(settings.notifyOnSuccess)
        #expect(due([plan(lastSuccessDaysAgo: 20)]).count == 1)
    }

    @Test("the notification names the plan with its repository, the days, and the last backup")
    func wording() {
        let last = now.addingTimeInterval(-8.5 * day)
        let text = StaleAlert.notification(planTitle: "Documents (Home NAS)", alert: StalePlanAlert(planID: UUID(), lastBackupAt: last, days: 8))
        #expect(text.title == "Documents (Home NAS)")
        #expect(text.body == "No successful backup in 8 days — the last one was \(Format.timestamp(last)).")
    }

    @Test("the alert mark survives an editor save")
    func persistence() throws {
        var stored = plan(lastSuccessDaysAgo: 9)
        stored.staleAlertedFor = stored.lastSuccessAt
        var draft = stored
        draft.staleAlertedFor = nil
        #expect(stored.merging(draft: draft).staleAlertedFor == stored.lastSuccessAt)
    }

    @Test("the mark survives the configuration file against a snapshot time as restic gives it, fraction and all")
    func markSurvivesTheFile() throws {
        var stored = plan(lastSuccessDaysAgo: nil)
        // A snapshot time as restic spells it, read as its times are; some
        // two weeks before `now`.
        let snapshotTime = try #require(ResticDateFormat.parse("2026-09-05T00:53:25.22662+08:00"))
        #expect(snapshotTime.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) > 0.2, "the premise: the time keeps a fraction")
        let alerts = due([stored], snapshots: [stored.id: snapshotTime])
        #expect(alerts.count == 1)
        stored.staleAlertedFor = try #require(alerts.first).lastBackupAt
        var configuration = AppConfiguration()
        configuration.plans = [stored]
        let relaunched = try ConfigStore.decoded(ConfigStore.encoded(configuration)).0.plans[0]
        #expect(relaunched.staleAlertedFor == snapshotTime)
        #expect(due([relaunched], snapshots: [stored.id: snapshotTime]).isEmpty)
        let later = snapshotTime.addingTimeInterval(day)
        #expect(due([relaunched], snapshots: [stored.id: later]).count == 1)
    }
}
