import Foundation

/// The months the Files pane's picker and the Backups tab's list read, as pure
/// functions the test bundle can pin: the tests compile no views, so the
/// bucketing the views render lives here with the model.
///
/// Built for thousands of snapshots: each function touches the candidate
/// list once and the date formatters run once per distinct bucket, not once
/// per candidate.
enum DiffCandidateGrouping {
    struct Month<Item> {
        let label: String
        let items: [Item]
    }

    /// Items bucketed by calendar month, newest bucket first. The input is
    /// sorted newest first, so first sight of a month names the group and
    /// the label formats once per month rather than once per item.
    static func months<Item>(in items: [Item], time: (Item) -> Date, calendar: Calendar = .current) -> [Month<Item>] {
        assert(zip(items, items.dropFirst()).allSatisfy { time($0) >= time($1) }, "months(in:) needs its items newest first")
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
        // Every key in `order` was labelled and grouped above.
        return order.map { Month(label: labels[$0]!, items: grouped[$0]!) }
    }

    /// The months of a long list, as landmarks to park the eye on — nil
    /// when it spans one month, where a heading would only repeat every
    /// row's date.
    static func landmarks<Item>(in items: [Item], time: (Item) -> Date, calendar: Calendar = .current) -> [Month<Item>]? {
        let grouped = months(in: items, time: time, calendar: calendar)
        return grouped.count > 1 ? grouped : nil
    }
}
