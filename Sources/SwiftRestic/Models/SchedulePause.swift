import Foundation

enum PauseLength: String, CaseIterable, Identifiable, Sendable {
    case oneHour
    case untilTomorrow
    case untilResumed

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .oneHour: "For 1 Hour"
        case .untilTomorrow: "Until Tomorrow"
        case .untilResumed: "Until I Resume"
        }
    }

    /// `nil` waits for the user. Until Tomorrow ends at the next day's
    /// start (01:00 in a zone that skips midnight), so a nightly 02:00 slot
    /// still runs.
    func end(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .oneHour:
            return now.addingTimeInterval(3600)
        case .untilTomorrow:
            // Not a nil on failure: nil is Until I Resume, a pause that never
            // ends by itself.
            return calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)
        case .untilResumed:
            return nil
        }
    }
}

/// Persisted: a pause that ended on relaunch would break "until tomorrow".
struct SchedulePause: Codable, Sendable, Hashable {
    var until: Date?

    init(until: Date?) {
        self.until = until
    }

    /// Strict, unlike the rest of the configuration: an unreadable date
    /// throws, so the settings' tolerant read gives "not paused" and a note.
    /// Tolerated, it would read as no end, every scheduled backup stopped
    /// silently. Absent is Until I Resume's stored form (`{}`).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        until = try c.decodeIfPresent(Date.self, forKey: .until)
    }

    func isActive(at now: Date) -> Bool {
        until.map { $0 > now } ?? true
    }
}
