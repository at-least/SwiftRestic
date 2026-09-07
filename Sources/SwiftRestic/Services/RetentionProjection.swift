import Foundation

/// Approximates what `restic forget` keeps for a plan running on a schedule.
///
/// The retention editor asks the user to decide what gets deleted; six
/// steppers with overlapping hour/day/week/month/year buckets are impossible
/// to eyeball, so this simulates a cadence of snapshots and applies the
/// policy the way restic documents it: for each non-zero keep rule, the
/// newest snapshot in each of the rule's most recent buckets survives; the
/// newest `keepLast` survive regardless; a snapshot that satisfies several
/// rules still survives once.
enum RetentionProjection {
    struct Outcome: Equatable {
        /// Snapshots the policy would keep.
        var keptSnapshots: Int
        /// Age of the oldest survivor, in whole days, rounded up.
        var historyDays: Int
    }

    /// - Returns: `nil` when there is nothing to project — manual plans have
    ///   no cadence, a disabled policy deletes nothing, and an all-zero
    ///   policy is already flagged by the editor's own warning.
    static func project(
        policy: RetentionPolicy,
        schedule: Schedule,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Outcome? {
        guard policy.isEnabled, policy.isSafeToRun else { return nil }
        let step: TimeInterval
        switch schedule.frequency {
        case .manual:
            return nil
        case .hourly:
            step = TimeInterval(max(1, schedule.intervalHours) * 3600)
        case .daily:
            step = 86_400
        case .weekly:
            step = 7 * 86_400
        }

        // The furthest back any rule can reach. A rule with count C on period
        // P spans C buckets; at cadence `step` the snapshots covering that
        // many buckets start C × max(step, P) ago. Bounded so extreme configs
        // (yearly 50 on an hourly plan) cannot stall the editor: the result
        // is then an honest "what survives within the simulated window".
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86_400
        let spans: [TimeInterval] = [
            TimeInterval(policy.keepLast) * step,
            TimeInterval(policy.keepHourly) * max(step, hour),
            TimeInterval(policy.keepDaily) * max(step, day),
            TimeInterval(policy.keepWeekly) * max(step, 7 * day),
            TimeInterval(policy.keepMonthly) * max(step, 30 * day),
            TimeInterval(policy.keepYearly) * max(step, 365 * day),
        ]
        let span = spans.max() ?? 0
        guard span > 0 else { return nil }
        let runCount = min(Int(span / step) + 1, 30_000)

        // Newest first, so an index doubles as recency rank.
        var runs: [Date] = []
        runs.reserveCapacity(runCount)
        for i in 0..<runCount {
            runs.append(now.addingTimeInterval(-Double(i) * step))
        }

        var survivors = Set<Int>()
        for i in 0..<min(policy.keepLast, runs.count) { survivors.insert(i) }

        func keepNewestPerBucket(_ count: Int, component: (Date) -> DateComponents) {
            guard count > 0 else { return }
            var seen = Set<DateComponents>()
            for (index, date) in runs.enumerated() {
                if seen.insert(component(date)).inserted {
                    survivors.insert(index)
                    if seen.count == count { break }
                }
            }
        }
        keepNewestPerBucket(policy.keepHourly) {
            calendar.dateComponents([.year, .month, .day, .hour], from: $0)
        }
        keepNewestPerBucket(policy.keepDaily) {
            calendar.dateComponents([.year, .month, .day], from: $0)
        }
        keepNewestPerBucket(policy.keepWeekly) {
            calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: $0)
        }
        keepNewestPerBucket(policy.keepMonthly) {
            calendar.dateComponents([.year, .month], from: $0)
        }
        keepNewestPerBucket(policy.keepYearly) {
            calendar.dateComponents([.year], from: $0)
        }

        guard let oldestIndex = survivors.max() else { return nil }
        let historyDays = Int((now.timeIntervalSince(runs[oldestIndex]) / 86_400).rounded(.up))
        return Outcome(
            keptSnapshots: survivors.count,
            historyDays: max(1, historyDays)
        )
    }
}
