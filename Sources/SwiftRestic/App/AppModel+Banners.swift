import Foundation

extension AppModel {
    func postBusyBanner(for repository: Repository) {
        post(Banner(
            title: "“\(label(of: repository))” is busy",
            message: "A backup or other work is already using this location.",
            level: .notice
        ))
    }

    /// Banners with a Show in Finder action stay: a restore finishing behind
    /// an open sheet would expire its button before anyone could click it.
    /// An identical staying banner is not posted again, or a repeated action
    /// stacks copies.
    func post(_ banner: Banner) {
        if banner.staysUntilDismissed,
           banners.contains(where: { $0.staysUntilDismissed && $0.title == banner.title && $0.message == banner.message })
        {
            return
        }
        banners.insert(banner, at: 0)
        if banners.count > Self.bannerLimit {
            // The oldest passing banner goes first, never the just-posted
            // one at index 0; errors go only when nothing else can.
            let oldestPassing = banners.lastIndex(where: { !$0.staysUntilDismissed }).flatMap { $0 > 0 ? $0 : nil }
            banners.remove(at: oldestPassing ?? banners.count - 1)
        }
        guard !banner.staysUntilDismissed, banner.revealPaths.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.passingBannerLifetime)
            guard let self else { return }
            self.banners.removeAll { $0.id == banner.id }
        }
    }

    func dismiss(_ banner: Banner) {
        banners.removeAll { $0.id == banner.id }
    }

    private static let bannerLimit = 4
    private static let passingBannerLifetime: Duration = .seconds(8)
}
