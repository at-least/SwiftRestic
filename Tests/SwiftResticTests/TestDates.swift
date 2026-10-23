import Foundation

/// "2026-10-23 09:00:00", read in UTC whatever the Mac's zone, calendar
/// and 12/24-hour setting.
func utcDate(_ string: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: string)!
}

/// New York's zone in en_US: the pins read "9:00 PM" whatever the Mac's own
/// zone, region and 12/24-hour setting.
func newYorkCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}

/// The narrow no-break space a formatter puts before AM and PM, flattened so
/// a pin compares what it appears to compare.
func flatSpaces(_ value: String) -> String {
    value.replacingOccurrences(of: "\u{202F}", with: " ")
}
