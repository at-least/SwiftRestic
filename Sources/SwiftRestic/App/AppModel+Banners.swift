import Foundation

extension AppModel {
    // MARK: - Banners

    /// Shows a transient message. Non-errors dismiss themselves after a few
    /// seconds — success that outlives its moment reads as stale — while
    /// errors stay until the user dismisses them. Banners carrying a Reveal
    /// action stay too: a restore finishing behind an open sheet would
    /// otherwise expire its button before anyone could click it. The cap
    /// keeps a pathological stream (a refresh loop over many unreachable
    /// repositories) from stacking banners without end.
    func post(_ banner: Banner) {
        banners.insert(banner, at: 0)
        if banners.count > Self.bannerLimit {
            // Evict the oldest success first: an unread error is exactly what
            // the queue exists to protect. The just-posted banner (index 0) is
            // exempt; only an all-error queue gives up its oldest error.
            let oldestSuccess = banners.lastIndex(where: { !$0.isError }).flatMap { $0 > 0 ? $0 : nil }
            banners.remove(at: oldestSuccess ?? banners.count - 1)
        }
        guard !banner.isError, banner.revealPath == nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self else { return }
            self.banners.removeAll { $0.id == banner.id }
        }
    }

    func dismiss(_ banner: Banner) {
        banners.removeAll { $0.id == banner.id }
    }

    private static let bannerLimit = 4
}
