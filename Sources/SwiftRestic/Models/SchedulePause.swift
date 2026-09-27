import Foundation

/// How long a pause lasts — the three choices every pause menu offers, the
/// tray's app-wide Pause Backups and a plan's own Pause Schedule alike.
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

    /// When a pause started at `now` ends by itself; `nil` for one that
    /// waits for the user. Until Tomorrow ends at the first moment of the
    /// next calendar day — midnight, or 01:00 in a zone that skips midnight
    /// that day — so a nightly 02:00 slot still runs.
    func end(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .oneHour:
            return now.addingTimeInterval(3600)
        case .untilTomorrow:
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
            return calendar.startOfDay(for: tomorrow)
        case .untilResumed:
            return nil
        }
    }
}

/// The app-wide pause of scheduled work, persisted so it survives a
/// relaunch — a pause that quietly ended on restart would break the user's
/// own "until tomorrow".
struct SchedulePause: Codable, Sendable, Hashable {
    /// When the pause ends by itself; `nil` for Until I Resume.
    var until: Date?

    init(until: Date?) {
        self.until = until
    }

    /// Strict, unlike the rest of the configuration: a date that is there
    /// but does not read throws, so the settings' tolerant read of the whole
    /// pause gives "not paused" and a decode note. Tolerated here, it would
    /// read as no end — an open-ended pause, every scheduled backup stopped
    /// without a word. Absent or null is Until I Resume's own stored form
    /// (`{}`: the synthesized encoding omits a nil end).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        until = try c.decodeIfPresent(Date.self, forKey: .until)
    }

    func isActive(at now: Date) -> Bool {
        until.map { $0 > now } ?? true
    }
}
