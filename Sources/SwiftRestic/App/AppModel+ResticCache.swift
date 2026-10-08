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

    /// "Removed 3 folders, 1.2 GB." — or that nothing was old enough.
    nonisolated static func cleanupNote(before: ResticCacheReport, after: ResticCacheReport) -> String {
        let removed = before.count - after.count
        guard removed > 0 else { return "Nothing was unused for \(ResticCacheReport.oldAfterDays) days." }
        return "Removed \(Format.plural(removed, "folder")), \(Format.bytes(before.totalBytes - after.totalBytes))."
    }
}
