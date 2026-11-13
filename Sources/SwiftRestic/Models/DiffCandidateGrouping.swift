import Foundation

/// Month headings for the backups and file-versions lists. Here with the
/// model because the tests compile no views. Built for thousands of
/// snapshots: one pass, and the date formatter runs once per month.
enum DiffCandidateGrouping {
    struct Month<Item> {
        let label: String
        let items: [Item]
    }

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
                // The bucketing calendar: a fixed-zone calendar (the tests)
                // gets labels cut along its own month boundaries.
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

    /// nil for one month, where a heading would only repeat every row's date.
    static func landmarks<Item>(in items: [Item], time: (Item) -> Date, calendar: Calendar = .current) -> [Month<Item>]? {
        let grouped = months(in: items, time: time, calendar: calendar)
        return grouped.count > 1 ? grouped : nil
    }
}
