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
