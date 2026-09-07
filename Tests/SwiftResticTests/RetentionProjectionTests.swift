import Foundation
import Testing

/// The projection's contract: for each non-zero rule the newest snapshot in
/// each of the rule's most recent buckets survives, the newest `keepLast`
/// always survive, and a snapshot that satisfies several rules survives once.
@Suite("Retention projection")
struct RetentionProjectionTests {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 2026-09-08 12:00 UTC, so hourly runs at :00 land on clean buckets.
    private var noon: Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 12))!
    }

    private var hourlySchedule: Schedule {
        var schedule = Schedule()
        schedule.frequency = .hourly
        schedule.intervalHours = 1
        return schedule
    }

    private func policy(
        last: Int = 0, hourly: Int = 0, daily: Int = 0,
        weekly: Int = 0, monthly: Int = 0, yearly: Int = 0
    ) -> RetentionPolicy {
        var policy = RetentionPolicy()
        policy.isEnabled = true
        policy.keepLast = last
        policy.keepHourly = hourly
        policy.keepDaily = daily
        policy.keepWeekly = weekly
        policy.keepMonthly = monthly
        policy.keepYearly = yearly
        return policy
    }

    @Test("keepLast keeps exactly the newest runs")
    func keepLastOnly() throws {
        let outcome = try #require(RetentionProjection.project(
            policy: policy(last: 3),
            schedule: hourlySchedule,
            now: noon,
            calendar: utcCalendar
        ))
        #expect(outcome.keptSnapshots == 3)
        // The oldest survivor is the run from two hours ago.
        #expect(outcome.historyDays == 1)
    }

    @Test("hourly and daily rules overlap; a snapshot survives once")
    func overlappingRules() throws {
        // Hourly 3 keeps the runs at 12:00, 11:00, 10:00. Daily 2 keeps the
        // newest run of Sep 8 (12:00 — already kept) and of Sep 7 (12:00).
        // Four distinct snapshots, not five.
        let outcome = try #require(RetentionProjection.project(
            policy: policy(hourly: 3, daily: 2),
            schedule: hourlySchedule,
            now: noon,
            calendar: utcCalendar
        ))
        #expect(outcome.keptSnapshots == 4)
        #expect(outcome.historyDays == 1)
    }

    @Test("a daily rule reaches further than an hourly one")
    func dailyReachesBack() throws {
        let outcome = try #require(RetentionProjection.project(
            policy: policy(daily: 7),
            schedule: hourlySchedule,
            now: noon,
            calendar: utcCalendar
        ))
        #expect(outcome.keptSnapshots == 7)
        // The 7th daily bucket back is six days before today.
        #expect(outcome.historyDays == 6)
    }

    @Test("the default policy spans years")
    func defaultPolicy() throws {
        var policy = RetentionPolicy()
        let outcome = try #require(RetentionProjection.project(
            policy: policy,
            schedule: hourlySchedule,
            now: noon,
            calendar: utcCalendar
        ))
        // 24 hourly + 7 daily + 4 weekly + 12 monthly + 3 yearly, minus
        // overlaps — bounded between the largest single rule and their sum.
        #expect(outcome.keptSnapshots >= 12)
        #expect(outcome.keptSnapshots <= 70)
        // The yearly rule reaches into the third year back: its newest
        // survivor is the New Year's Eve run of 2024, ~616 days before now.
        #expect(outcome.historyDays >= 600)
        #expect(outcome.historyDays <= 630)
    }

    @Test("nothing to project: manual, disabled, all-zero")
    func nothingToProject() {
        var manual = Schedule()
        manual.frequency = .manual
        #expect(RetentionProjection.project(policy: policy(hourly: 3), schedule: manual) == nil)

        var disabled = policy(hourly: 3)
        disabled.isEnabled = false
        #expect(RetentionProjection.project(policy: disabled, schedule: hourlySchedule) == nil)

        #expect(RetentionProjection.project(policy: policy(), schedule: hourlySchedule) == nil)
    }

    @Test("daily plans project against daily buckets")
    func dailyCadence() throws {
        var schedule = Schedule()
        schedule.frequency = .daily
        schedule.hour = 3
        schedule.minute = 30
        // keepLast 5 on a daily plan keeps today's and the four previous
        // days' runs; the oldest survivor is four days back.
        let outcome = try #require(RetentionProjection.project(
            policy: policy(last: 5),
            schedule: schedule,
            now: noon,
            calendar: utcCalendar
        ))
        #expect(outcome.keptSnapshots == 5)
        #expect(outcome.historyDays == 4)
    }
}
