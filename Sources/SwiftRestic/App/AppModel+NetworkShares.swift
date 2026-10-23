import Foundation

/// Network shares reconnected before a backup that needs them
/// (`NetworkShare`): the backup engine asks for the volumes it found away,
/// and each saved share among them is mounted with its saved password.
extension AppModel {
    /// The saved share that mounts as /Volumes/`volumeName`.
    func networkShare(forVolume volumeName: String) -> NetworkShare? {
        configuration.settings.networkShares.first { $0.volumeName == volumeName }
    }

    /// Saves a share's password and, the first time, the share itself, by
    /// volume name — a repository and a plan on one share keep one record,
    /// its URL as last read from the mounted volume. The password goes
    /// first: a share is never saved without one.
    func saveNetworkShare(_ share: MountedShare, password: String) async throws {
        var saved = networkShare(forVolume: share.volumeName) ?? NetworkShare(volumeName: share.volumeName, url: share.url)
        try await secrets.saveSharePassword(saved.id, password)
        saved.url = share.url
        if let index = configuration.settings.networkShares.firstIndex(where: { $0.id == saved.id }) {
            configuration.settings.networkShares[index] = saved
        } else {
            configuration.settings.networkShares.append(saved)
        }
    }

    /// Forgets a share: its password first, then the share — a Keychain
    /// that refuses keeps both.
    func removeNetworkShare(_ share: NetworkShare) async throws {
        try await secrets.saveSharePassword(share.id, nil)
        configuration.settings.networkShares.removeAll { $0.id == share.id }
    }

    /// A read that needs a local repository on a network share — the
    /// retention preview — reconnects its saved share first when it is
    /// away, as a run does; still away, it throws in the run's words
    /// (`ShareNotReconnected`). A volume with no saved share is left to the
    /// read, as before.
    func reconnectShare(before repository: Repository) async throws {
        let path = repository.resolvedLocalPath
        guard repository.kind == .local, VolumePresence.isMounted(volumeOf: path) == false,
              let volume = VolumePresence.volumeName(of: path)
        else { return }
        let failures = await reconnectShares(volumes: [volume]).filter { $0.failureReason != nil }
        guard failures.isEmpty else {
            throw ShareNotReconnected(message: RunRecord.skippedReason(sources: [path], reconnectFailures: failures.reasonsByVolume))
        }
    }

    /// One connection attempt to a network repository's server
    /// (`ServerProbe`), with the environment restic would run with — a proxy
    /// there means nothing is probed.
    func probeServer(of repository: Repository) async -> ServerProbe.Outcome? {
        guard repository.kind != .local else { return nil }
        let environment = ProcessInfo.processInfo.environment.merging(repository.extraEnvironment) { _, own in own }
        return await serverProbe.check(repository, environment)
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
                return result(.refused("its address “\(share.url)” is not a URL"))
            }
            let password: String?
            do {
                password = try await secrets.loadSharePassword(share.id)
            } catch {
                return result(.refused("the Keychain did not give its password: \(error.localizedDescription)"))
            }
            guard let password else { return result(.refused("no password is saved for it")) }
            switch await shareMounter.mount(url, password) {
            case let .failed(status):
                return result(ShareMounter.failure(status: status))
            case let .mounted(mountpoints):
                // A folder of that name left in /Volumes by an unclean
                // disconnect makes macOS mount the share beside it, as
                // "NAS-1", where the plan's and repository's paths still
                // miss it.
                guard VolumePresence.isVolumeRoot("/Volumes/\(share.volumeName)") else {
                    return result(.refused(
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

/// A local repository's network share that stayed away when a read needed
/// it, in a skipped run's words.
struct ShareNotReconnected: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
