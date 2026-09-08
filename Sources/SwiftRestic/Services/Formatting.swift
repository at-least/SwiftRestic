import Foundation

/// Shared number and date formatting so every view reads the same way.
enum Format {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        // ByteCountFormatter spells zero as "Zero KB" by default, which reads as a
        // glitch on an axis label or a stat tile.
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }

    static func count(_ value: Int?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number)
    }

    /// A count and its noun, spelled for the actual count — the "2 pattern(s)"
    /// style leaks programmer syntax into the interface.
    static func plural(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        let noun = count == 1 ? singular : plural ?? "\(singular)s"
        return "\(count.formatted(.number)) \(noun)"
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 1 { return "<1s" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds < 3600 ? [.minute, .second] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "—"
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let now = Date.now
        // Something that just happened must not be described in the future
        // tense, which is what a timestamp a fraction of a second old
        // produces. Beyond that window the formatter gets the real date in
        // whichever direction it lies: clamping a future timestamp down to
        // now fed it a zero delta, and a run an hour ahead rendered as the
        // nonsense "in 0 seconds".
        if abs(date.timeIntervalSince(now)) < 45 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func timestamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// A next-run moment, spelled to fit a stat tile. `timestamp`'s full
    /// "Sep 9, 2026 at 3:00 AM" is exactly what a tile truncates its AM/PM
    /// off — the one part that says morning or evening — so near days lead
    /// with the day name and the tile's tooltip carries `timestamp` for the
    /// full form. A moment at or before now reads "Due now", matching the
    /// Next runs card.
    static func tileTimestamp(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        guard date > now else { return "Due now" }
        // The calendar owns the time zone: a date the calendar placed at 9 PM
        // must not be re-expressed in the machine's zone (tests pass a fixed
        // one; users simply get their own).
        let zone = calendar.timeZone
        func style() -> Date.FormatStyle {
            Date.FormatStyle(calendar: calendar, timeZone: zone)
        }
        let time = date.formatted(style().hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow)
        { return "Tomorrow \(time)" }
        if date.timeIntervalSince(now) < 7 * 86_400 {
            return "\(date.formatted(style().weekday(.abbreviated))) \(time)"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(style().month(.abbreviated).day().hour().minute())
        }
        return date.formatted(style().year().month().day().hour().minute())
    }

    static func rate(bytes: Int64, over seconds: TimeInterval) -> String {
        guard seconds > 0.5, bytes > 0 else { return "—" }
        let perSecond = Int64(Double(bytes) / seconds)
        return "\(ByteCountFormatter.string(fromByteCount: perSecond, countStyle: .file))/s"
    }
}
