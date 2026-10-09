import Foundation

/// restic's cache as the Settings tab reports it.
enum ResticCacheState: Equatable {
    case measured(ResticCacheReport)
    case failed(String)
}

extension AppModel {
    /// Measures restic's cache (`restic cache`) for Settings › restic. The
    /// tab shows "Measuring…" meanwhile; a failure is the error's own words.
    func measureResticCache() async {
        guard !isWorkingOnResticCache else { return }
        isWorkingOnResticCache = true
        defer { isWorkingOnResticCache = false }
        do {
            resticCache = .measured(try await service().cacheReport())
        } catch {
            resticCache = .failed(error.localizedDescription)
        }
    }

    /// Removes the directories restic marks old, then measures again: the
    /// note says what went, counted from the two reports rather than
    /// restic's own wording.
    func cleanupResticCache() async {
        guard case let .measured(before) = resticCache, !isWorkingOnResticCache else { return }
        isWorkingOnResticCache = true
        defer { isWorkingOnResticCache = false }
        do {
            try await service().cleanupCache()
            let after = try await service().cacheReport()
            resticCache = .measured(after)
            resticCacheNote = Self.cleanupNote(before: before, after: after)
        } catch {
            resticCache = .failed(error.localizedDescription)
        }
    }

    /// The Settings caption's closing sentence: how many of the folders have
    /// gone unused long enough for Remove to take them — or, for a cache
    /// restic has not filled, that it is empty, where "none has gone unused"
    /// would speak of folders that are not there.
    nonisolated static func unusedLine(_ report: ResticCacheReport) -> String {
        let days = ResticCacheReport.oldAfterDays
        if report.count == 0 { return "Nothing is cached yet." }
        if report.oldCount == 0 { return "None has gone unused for \(days) days." }
        return "\(Format.count(report.oldCount)) \(report.oldCount == 1 ? "has" : "have") not been used for \(days) days."
    }

    /// "Removed 3 folders, 1.2 GB." — or that nothing was old enough.
    nonisolated static func cleanupNote(before: ResticCacheReport, after: ResticCacheReport) -> String {
        let removed = before.count - after.count
        guard removed > 0 else { return "Nothing was unused for \(ResticCacheReport.oldAfterDays) days." }
        return "Removed \(Format.plural(removed, "folder")), \(Format.bytes(before.totalBytes - after.totalBytes))."
    }
}
