import Foundation

extension AppModel {
    // MARK: - Banners

    /// A maintenance job or retention asked for while the repository is in use.
    func postBusyBanner(for repository: Repository) {
        post(Banner(
            title: "“\(label(of: repository))” is busy",
            message: "A backup or another maintenance job is already using this repository.",
            isError: false,
            symbolName: "clock"
        ))
    }

    /// Shows a transient message. Successes and news dismiss themselves
    /// after a few seconds — success that outlives its moment reads as
    /// stale — while errors and warnings stay until the user dismisses
    /// them. Banners carrying a Show in Finder action stay too: a restore finishing
    /// behind an open sheet would otherwise expire its button before anyone
    /// could click it. The cap keeps a pathological stream from stacking
    /// banners without end.
    ///
    /// An identical error or warning already on screen is not posted
    /// again: they do not expire on their own, and a repeatable action
    /// would stack copies until they evict unrelated successes.
    func post(_ banner: Banner) {
        if banner.staysUntilDismissed,
           banners.contains(where: { $0.staysUntilDismissed && $0.title == banner.title && $0.message == banner.message })
        {
            return
        }
        banners.insert(banner, at: 0)
        if banners.count > Self.bannerLimit {
            // Evict the oldest passing banner first: an unread error is
            // exactly what the queue exists to protect. The just-posted
            // banner (index 0) is exempt; only a queue of errors and
            // warnings gives up its oldest.
            let oldestPassing = banners.lastIndex(where: { !$0.staysUntilDismissed }).flatMap { $0 > 0 ? $0 : nil }
            banners.remove(at: oldestPassing ?? banners.count - 1)
        }
        guard !banner.staysUntilDismissed, banner.revealPaths.isEmpty else { return }
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
