import SwiftUI

/// The window's "now": the current minute, from the one
/// `TimelineView(.everyMinute)` around the root view. Every surface that
/// says how long ago something happened, or whether a run is due, reads it
/// — so an idle window moves on with the minute instead of keeping the
/// words it was first drawn with (two captures 2.5 minutes apart were
/// identical, 2026-10-02), and surfaces drawn at different moments cannot
/// call the same run "48 seconds ago" and "56 seconds ago" side by side.
private struct MinuteClockKey: EnvironmentKey {
    /// Computed, never stored: where no timeline sets it — a preview, a
    /// scene outside the main window — now is now, not the launch time.
    static var defaultValue: Date { .now }
}

extension EnvironmentValues {
    var now: Date {
        get { self[MinuteClockKey.self] }
        set { self[MinuteClockKey.self] = newValue }
    }
}
