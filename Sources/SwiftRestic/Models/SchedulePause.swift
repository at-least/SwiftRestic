import Foundation

/// Every pause ends by itself (user decision): none waits for a resume.
enum PauseLength: String, CaseIterable, Identifiable, Sendable {
    case oneHour
    case untilTomorrow

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .oneHour: "For 1 Hour"
        case .untilTomorrow: "Until Tomorrow"
        }
    }

    /// Until Tomorrow ends at the next day's start (01:00 in a zone that
    /// skips midnight), so a nightly 02:00 slot still runs.
    func end(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour:
            return now.addingTimeInterval(3600)
        case .untilTomorrow:
            return calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)
        }
    }
}

/// Persisted: a pause that ended on relaunch would break "until tomorrow".
/// Decoded strictly (synthesized): a missing or unreadable date throws, so
/// the settings' tolerant read gives "not paused" and a note, never a pause
/// without end.
struct SchedulePause: Codable, Sendable, Hashable {
    var until: Date

    func isActive(at now: Date) -> Bool {
        until > now
    }
}
