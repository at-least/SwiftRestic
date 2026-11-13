import Foundation

extension AppModel {
    private func networkShare(forVolume volumeName: String) -> NetworkShare? {
        configuration.settings.networkShares.first { $0.volumeName == volumeName }
    }

    /// Falls back to the saved share, so one away while the sheet is open
    /// keeps its row and its password can still be replaced. A mounted
    /// volume of another name is a stale read of a changed path.
    func shareRow(for path: String, mounted: MountedShare?) -> (share: MountedShare, isSaved: Bool)? {
        guard let volume = VolumePresence.volumeName(of: path) else { return nil }
        let saved = networkShare(forVolume: volume)
        if let mounted, mounted.volumeName == volume { return (mounted, saved != nil) }
        return saved.map { (MountedShare(volumeName: $0.volumeName, url: $0.url), true) }
    }

    /// Keyed by volume name: a repository and a plan on one share keep one
    /// record. The password goes first: a share is never saved without one.
    func saveNetworkShare(_ share: MountedShare, password: String) async throws {
        var saved = networkShare(forVolume: share.volumeName) ?? NetworkShare(volumeName: share.volumeName, url: share.url)
        try await secrets.saveSharePassword(saved.id, password)
        saved.url = share.url
        if let index = configuration.settings.networkShares.firstIndex(where: { $0.id == saved.id }) {
            configuration.settings.networkShares[index] = saved
        } else {
            configuration.settings.networkShares.append(saved)
        }
        let repositoryIDs = Set(
            configuration.repositories.filter { $0.driveVolumeName == share.volumeName }.map(\.id)
                + configuration.plans.filter { VolumePresence.volumeName(of: $0.resolvedPath) == share.volumeName }.compactMap(\.repositoryID)
        )
        for repositoryID in repositoryIDs { rerunFailedBackups(in: repositoryID) }
    }

    /// Password first: a Keychain that refuses keeps both.
    func removeNetworkShare(_ share: NetworkShare) async throws {
        try await secrets.saveSharePassword(share.id, nil)
        configuration.settings.networkShares.removeAll { $0.id == share.id }
    }

    /// The editors save a share's password after the plan or location that
    /// needs it, so a new share is already in use.
    func forgetNetworkShares(unusedSince before: Set<String>) async {
        let inUse = configuration.volumesInUse
        for share in configuration.settings.networkShares
            where before.contains(share.volumeName) && !inUse.contains(share.volumeName)
        {
            do {
                try await removeNetworkShare(share)
            } catch {
                post(Banner(
                    title: "Couldn’t remove the password for “\(share.url)”",
                    message: error.localizedDescription,
                    level: .error
                ))
            }
        }
    }

    /// Still away, it throws in a skipped run's words. A volume with no
    /// saved share is left to the read.
    func reconnectShare(before repository: Repository) async throws {
        guard await isVolumeMissing(repository), let volume = repository.driveVolumeName else { return }
        let failures = await reconnectShares(volumes: [volume]).filter { $0.failureReason != nil }
        guard failures.isEmpty else {
            throw MessageError(message: RunRecord.skippedReason(sources: [repository.resolvedLocalPath], reconnectFailures: failures.reasonsByVolume))
        }
    }

    func isMounted(volumeOf path: String) async -> Bool? {
        await volumeProbe.isMounted(volumeOf: path)
    }

    /// restic's environment: a proxy there means nothing is probed.
    func probeServer(of repository: Repository) async -> ServerProbe.Outcome? {
        guard repository.kind != .local else { return nil }
        let environment = ProcessInfo.processInfo.environment.merging(repository.extraEnvironment) { _, own in own }
        return await serverProbe.check(repository, environment)
    }

    /// A volume with no saved share gets no entry.
    func reconnectShares(volumes: [String]) async -> [ShareReconnect] {
        var results: [ShareReconnect] = []
        for volume in volumes {
            guard let share = networkShare(forVolume: volume) else { continue }
            results.append(await reconnect(share))
        }
        return results
    }

    /// A second caller while a mount is in flight awaits its answer.
    private func reconnect(_ share: NetworkShare) async -> ShareReconnect {
        if let inFlight = shareReconnects[share.volumeName] { return await inFlight.value }
        let task = Task { [secrets, shareMounter, volumeProbe] () -> ShareReconnect in
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
                // A folder left in /Volumes by an unclean disconnect makes
                // macOS mount the share beside it as "NAS-1", where the
                // saved paths miss it.
                guard await volumeProbe.isMounted(volumeOf: "/Volumes/\(share.volumeName)") == true else {
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

extension AppConfiguration {
    var volumesInUse: Set<String> {
        Set(plans.compactMap { VolumePresence.volumeName(of: $0.resolvedPath) }
            + repositories.compactMap(\.driveVolumeName))
    }
}
