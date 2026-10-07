import Foundation

/// The diff sheet's picker grouping — and the months the Files pane's
/// picker and the sidebar's backup fold read — as pure functions the test
/// bundle can pin: the tests compile no views, so the bucketing the views
/// render lives here with the model.
///
/// Built for thousands of snapshots: each function touches the candidate
/// list once and the date formatters run once per distinct bucket, not once
/// per candidate — the sheet rebuilds this on every keystroke in its filter
/// field.
enum DiffCandidateGrouping {
    struct Month<Item> {
        let label: String
        let items: [Item]
    }

    /// Candidates bucketed by calendar month, newest bucket first. The input
    /// is sorted newest first, so first sight of a month names the group and
    /// the label formats once per month rather than once per snapshot.
    static func months(in candidates: [Snapshot], calendar: Calendar = .current) -> [Month<Snapshot>] {
        months(in: candidates, time: \.time, calendar: calendar)
    }

    /// The same bucketing for anything with a moment — a folder's backups
    /// in the Files pane's "As backed up" picker, a plan's in the sidebar's
    /// fold, which share the Compare sheet's months.
    static func months<Item>(in items: [Item], time: (Item) -> Date, calendar: Calendar = .current) -> [Month<Item>] {
        var order: [DateComponents] = []
        var labels: [DateComponents: String] = [:]
        var grouped: [DateComponents: [Item]] = [:]
        for item in items {
            let moment = time(item)
            let key = calendar.dateComponents([.year, .month], from: moment)
            if grouped[key] == nil {
                order.append(key)
                // The label uses the same calendar that bucketed the
                // item — a fixed-zone calendar (the tests) must get labels
                // cut along its month boundaries.
                labels[key] = moment.formatted(
                    Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
                        .month(.wide).year()
                )
            }
            grouped[key, default: []].append(item)
        }
        return order.map { Month(label: labels[$0] ?? "", items: grouped[$0] ?? []) }
    }

    /// The months of a long list, as landmarks to park the eye on — nil
    /// when it spans one month, where a heading would only repeat every
    /// row's date.
    static func landmarks<Item>(in items: [Item], time: (Item) -> Date, calendar: Calendar = .current) -> [Month<Item>]? {
        let grouped = months(in: items, time: time, calendar: calendar)
        return grouped.count > 1 ? grouped : nil
    }

    /// The minute string a picker row displays. The rows and the shared set
    /// below must spell minutes the same way, so both come through here.
    static func displayedMinute(_ time: Date) -> String {
        Format.timestamp(time)
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
