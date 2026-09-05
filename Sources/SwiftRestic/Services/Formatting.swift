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
        // Something that just happened must not be described in the future tense,
        // which is what a timestamp a fraction of a second old produces.
        if abs(date.timeIntervalSince(now)) < 45 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    static func timestamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func rate(bytes: Int64, over seconds: TimeInterval) -> String {
        guard seconds > 0.5, bytes > 0 else { return "—" }
        let perSecond = Int64(Double(bytes) / seconds)
        return "\(ByteCountFormatter.string(fromByteCount: perSecond, countStyle: .file))/s"
    }
}
