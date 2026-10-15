import Foundation

/// Network shares reconnected before a backup that needs them
/// (`NetworkShare`): the backup engine asks for the volumes it found away,
/// and each saved share among them is mounted with its saved password.
extension AppModel {
    /// The saved share that mounts as /Volumes/`volumeName`.
    func networkShare(forVolume volumeName: String) -> NetworkShare? {
        configuration.settings.networkShares.first { $0.volumeName == volumeName }
    }

    /// Reconnects the saved shares among `volumes` — volumes a backup needs
    /// that are away. A volume no share is saved for is left to the run's
    /// away checks, as before; it gets no entry.
    func reconnectShares(volumes: [String]) async -> [ShareReconnect] {
        var results: [ShareReconnect] = []
        for volume in volumes {
            guard let share = networkShare(forVolume: volume) else { continue }
            results.append(await reconnect(share))
        }
        return results
    }

    /// One mount of a share at a time: a second run asking while the first
    /// mount is in flight waits for its answer (`shareReconnects`).
    private func reconnect(_ share: NetworkShare) async -> ShareReconnect {
        if let inFlight = shareReconnects[share.volumeName] { return await inFlight.value }
        let task = Task { [secrets, shareMounter] () -> ShareReconnect in
            func result(_ outcome: ShareReconnect.Outcome) -> ShareReconnect {
                ShareReconnect(volumeName: share.volumeName, url: share.url, outcome: outcome)
            }
            guard let url = URL(string: share.url) else {
                return result(.failed("its address “\(share.url)” is not a URL"))
            }
            let password: String?
            do {
                password = try await secrets.loadSharePassword(share.id)
            } catch {
                return result(.failed("the Keychain did not give its password: \(error.localizedDescription)"))
            }
            guard let password else { return result(.failed("no password is saved for it")) }
            switch await shareMounter.mount(url, password) {
            case let .failed(status):
                return result(.failed(ShareMounter.describe(status: status)))
            case let .mounted(mountpoints):
                // A folder of that name left in /Volumes by an unclean
                // disconnect makes macOS mount the share beside it, as
                // "NAS-1", where the plan's and repository's paths still
                // miss it.
                guard VolumePresence.isVolumeRoot("/Volumes/\(share.volumeName)") else {
                    return result(.failed(
                        "macOS mounted it as \(mountpoints.first ?? "another folder") — a folder named “\(share.volumeName)” is in the way in /Volumes"
                    ))
                }
                return result(.reconnected)
            }
        }
        shareReconnects[share.volumeName] = task
        let reconnect = await task.value
        shareReconnects[share.volumeName] = nil
        return reconnect
    }
}
