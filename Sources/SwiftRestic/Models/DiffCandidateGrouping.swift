import Foundation

/// The diff sheet's picker grouping, as pure functions the test bundle can
/// pin — the tests compile no views, so the bucketing the picker renders
/// lives here with the model.
///
/// Built for repositories with thousands of snapshots: each function touches
/// the candidate list once, and the date formatters run once per distinct
/// bucket, not once per candidate per render — the sheet rebuilds this on
/// every keystroke in its filter field.
enum DiffCandidateGrouping {
    struct Month: Equatable {
        let label: String
        let snapshots: [Snapshot]
    }

    /// Candidates bucketed by calendar month, newest bucket first. The input
    /// is sorted newest first, so first sight of a month names the group and
    /// the label formats once per month rather than once per snapshot.
    static func months(in candidates: [Snapshot], calendar: Calendar = .current) -> [Month] {
        var order: [DateComponents] = []
        var labels: [DateComponents: String] = [:]
        var grouped: [DateComponents: [Snapshot]] = [:]
        for snapshot in candidates {
            let key = calendar.dateComponents([.year, .month], from: snapshot.time)
            if grouped[key] == nil {
                order.append(key)
                // The label answers to the same calendar that bucketed the
                // snapshot — a caller handing in a fixed-zone calendar (the
                // tests) must get labels cut along its month boundaries.
                labels[key] = snapshot.time.formatted(
                    Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
                        .month(.wide).year()
                )
            }
            grouped[key, default: []].append(snapshot)
        }
        return order.map { Month(label: labels[$0] ?? "", snapshots: grouped[$0] ?? []) }
    }

    /// The minute string a picker row displays. The rows and the shared set
    /// below must spell minutes the same way, so both come through here.
    static func displayedMinute(_ time: Date) -> String {
        time.formatted(date: .abbreviated, time: .shortened)
    }

    /// The minute strings two or more candidates display alike. Two
    /// candidates share a displayed minute exactly when they fall in the same
    /// calendar minute, so the shared strings are formatted from one
    /// representative per shared minute — a set lookup for the rows, instead
    /// of a formatter call apiece.
    static func sharedDisplayedMinutes(
        in candidates: [Snapshot],
        calendar: Calendar = .current
    ) -> Set<String> {
        var counts: [DateComponents: Int] = [:]
        var representatives: [DateComponents: Date] = [:]
        for snapshot in candidates {
            let key = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: snapshot.time
            )
            counts[key, default: 0] += 1
            if representatives[key] == nil { representatives[key] = snapshot.time }
        }
        var shared: Set<String> = []
        for (key, count) in counts where count > 1 {
            guard let time = representatives[key] else { continue }
            shared.insert(displayedMinute(time))
        }
        return shared
    }
}
