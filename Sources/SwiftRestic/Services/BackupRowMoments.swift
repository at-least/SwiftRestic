import Foundation

/// What a Backups tab's list rows say. Under "October 2026" section headers
/// a row drops the year its header says; a flat single-month list keeps
/// the full stamp. Two neighbouring backups that would read the same minute
/// show their seconds — those rows only, so the rest stay short.
enum BackupRowMoments {
    private static let sectionedSeconds = Date.FormatStyle().month(.abbreviated).day().hour().minute().second()
    private static let flatSeconds = Date.FormatStyle(date: .abbreviated, time: .standard)

    /// By the moment, for `times` in the list's order, newest first.
    static func labels(for times: [Date], sectioned: Bool) -> [Date: String] {
        let minutes = times.map { sectioned ? Format.dayTime($0) : Format.timestamp($0) }
        var labels: [Date: String] = [:]
        for (index, time) in times.enumerated() {
            let sameAsNeighbour = (index > 0 && minutes[index - 1] == minutes[index])
                || (index + 1 < times.count && minutes[index + 1] == minutes[index])
            labels[time] = sameAsNeighbour
                ? time.formatted(sectioned ? sectionedSeconds : flatSeconds)
                : minutes[index]
        }
        return labels
    }
}
