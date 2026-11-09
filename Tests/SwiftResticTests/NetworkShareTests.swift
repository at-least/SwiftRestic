import Foundation
import Testing

/// Network shares reconnected before a backup: the saved share for an
/// away volume is mounted with its saved password through an injected
/// mounter — nothing here mounts anything — and the answers read as the
/// skip's words. The real mount is the live check's job.
@MainActor
@Suite("network shares")
struct NetworkShareTests {
    private actor Mounts {
        var calls: [(url: String, password: String?)] = []
        func add(_ url: URL, _ password: String?) { calls.append((url.absoluteString, password)) }
    }

    private actor Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func open() {
            isOpen = true
            for continuation in waiting { continuation.resume() }
            waiting = []
        }
    }

    private func makeModel(
        answer: ShareMounter.Result,
        password: String? = "share-pass",
        gate: Gate? = nil
    ) async throws -> (model: AppModel, mounts: Mounts, volume: String) {
        let volume = "SwiftResticAbsentShare-\(UUID().uuidString)"
        let mounts = Mounts()
        let mounter = ShareMounter { url, password in
            await mounts.add(url, password)
            await gate?.wait()
            return answer
        }
        let secrets = SecretStore.inMemory()
        let model = AppModel(
            store: ConfigStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("SwiftResticShares-\(UUID().uuidString)")),
            secrets: secrets,
            shareMounter: mounter
        )
        let share = NetworkShare(volumeName: volume, url: "smb://me@nas.local/\(volume)")
        model.configuration.settings.networkShares = [share]
        try await secrets.saveSharePassword(share.id, password)
        return (model, mounts, volume)
    }

    @Test("an away share is mounted with its saved password; a volume no share is saved for is left alone")
    func mountsWithTheSavedPassword() async throws {
        let (model, mounts, volume) = try await makeModel(answer: .failed(EAUTH))
        let results = await model.reconnectShares(volumes: [volume, "NoShareSavedForThis"])
        #expect(await mounts.calls.map(\.url) == ["smb://me@nas.local/\(volume)"])
        #expect(await mounts.calls.map(\.password) == ["share-pass"])
        #expect(results == [ShareReconnect(
            volumeName: volume, url: "smb://me@nas.local/\(volume)",
            outcome: .refused("the share did not accept the user name and password")
        )])
    }

    @Test("a mount that does not land at /Volumes/<name> is no reconnect, and says where it landed")
    func landedBesideAStaleFolder() async throws {
        let (model, _, volume) = try await makeModel(answer: .mounted(["/Volumes/X-1"]))
        let results = await model.reconnectShares(volumes: [volume])
        #expect(results.map(\.outcome) == [
            .refused("macOS mounted it as /Volumes/X-1 — a folder named “\(volume)” is in the way in /Volumes"),
        ])
    }

    @Test("with no password saved nothing is mounted, and the answer says so")
    func noPasswordNoMount() async throws {
        let (model, mounts, volume) = try await makeModel(answer: .mounted([]), password: nil)
        let results = await model.reconnectShares(volumes: [volume])
        #expect(await mounts.calls.isEmpty)
        #expect(results.map(\.outcome) == [.refused("no password is saved for it")])
    }

    @Test("two runs needing the same share at once mount it once and read the same answer")
    func oneMountPerShare() async throws {
        let gate = Gate()
        let (model, mounts, volume) = try await makeModel(answer: .failed(EAUTH), gate: gate)
        let first = Task { await model.reconnectShares(volumes: [volume]) }
        // The first is mounting (and held there) before the second asks;
        // bounded, so a first that never mounts fails rather than hangs.
        var reached = false
        for _ in 0 ..< 10_000 {
            if await !mounts.calls.isEmpty {
                reached = true
                break
            }
            await Task.yield()
        }
        guard reached else {
            await gate.open()
            Issue.record("the first reconnect never reached the mounter")
            return
        }
        let second = Task { await model.reconnectShares(volumes: [volume]) }
        for _ in 0 ..< 10 { await Task.yield() }
        await gate.open()
        let (a, b) = (await first.value, await second.value)
        #expect(await mounts.calls.count == 1)
        #expect(a == b)
        #expect(a.map(\.outcome) == [.refused("the share did not accept the user name and password")])
    }

    private func makeEditorModel(secrets: SecretStore) -> AppModel {
        AppModel(
            store: ConfigStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("SwiftResticShareEdits-\(UUID().uuidString)")),
            secrets: secrets,
            shareMounter: ShareMounter { _, _ in .failed(EAUTH) }
        )
    }

    /// A store whose share-password writes all fail, as a locked Keychain's.
    private func refusingStore() -> SecretStore {
        SecretStore(
            load: { _ in (nil, nil) },
            save: { _, _, _ in },
            remove: { _ in },
            loadSharePassword: { _ in nil },
            saveSharePassword: { _, _ in throw KeychainStore.KeychainError.unexpectedStatus(errSecInteractionNotAllowed) }
        )
    }

    @Test("saving a share's password saves the share once, by volume name; saving again replaces the password and the URL")
    func savedOncePerVolume() async throws {
        let secrets = SecretStore.inMemory()
        let model = makeEditorModel(secrets: secrets)
        try await model.saveNetworkShare(MountedShare(volumeName: "NAS", url: "smb://me@old.local/NAS"), password: "one")
        let first = try #require(model.configuration.settings.networkShares.first)
        #expect(model.configuration.settings.networkShares.count == 1)
        #expect(try await secrets.loadSharePassword(first.id) == "one")
        try await model.saveNetworkShare(MountedShare(volumeName: "NAS", url: "smb://me@new.local/NAS"), password: "two")
        #expect(model.configuration.settings.networkShares == [NetworkShare(id: first.id, volumeName: "NAS", url: "smb://me@new.local/NAS")])
        #expect(try await secrets.loadSharePassword(first.id) == "two")
    }

    @Test("a Keychain that refuses the password leaves no share saved")
    func refusedPasswordNoRecord() async {
        let model = makeEditorModel(secrets: refusingStore())
        await #expect(throws: KeychainStore.KeychainError.self) {
            try await model.saveNetworkShare(MountedShare(volumeName: "NAS", url: "smb://me@nas.local/NAS"), password: "pw")
        }
        #expect(model.configuration.settings.networkShares.isEmpty)
    }

    @Test("removing a share forgets its password and the share; a Keychain that refuses keeps both")
    func removeForgetsBoth() async throws {
        let secrets = SecretStore.inMemory()
        let model = makeEditorModel(secrets: secrets)
        try await model.saveNetworkShare(MountedShare(volumeName: "NAS", url: "smb://me@nas.local/NAS"), password: "pw")
        let share = try #require(model.configuration.settings.networkShares.first)
        try await model.removeNetworkShare(share)
        #expect(model.configuration.settings.networkShares.isEmpty)
        #expect(try await secrets.loadSharePassword(share.id) == nil)

        let refusing = makeEditorModel(secrets: refusingStore())
        refusing.configuration.settings.networkShares = [share]
        await #expect(throws: KeychainStore.KeychainError.self) { try await refusing.removeNetworkShare(share) }
        #expect(refusing.configuration.settings.networkShares == [share])
    }

    @Test("a share is forgotten once the last plan or location on it goes; one still in use, or never in use, stays")
    func forgottenWhenUnused() async throws {
        let secrets = SecretStore.inMemory()
        let model = makeEditorModel(secrets: secrets)
        model.isLoaded = true
        var repository = Repository()
        repository.localPath = "/Volumes/Backups/restic"
        var plan = BackupPlan()
        plan.path = "/Volumes/NAS/Documents"
        var other = plan
        other.id = UUID()
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan, other]
        try await model.saveNetworkShare(MountedShare(volumeName: "NAS", url: "smb://me@nas.local/NAS"), password: "pw")
        try await model.saveNetworkShare(MountedShare(volumeName: "Backups", url: "smb://me@nas.local/Backups"), password: "pw")
        try await model.saveNetworkShare(MountedShare(volumeName: "Spare", url: "smb://me@nas.local/Spare"), password: "pw")
        let nas = try #require(model.configuration.settings.networkShares.first { $0.volumeName == "NAS" })
        #expect(model.configuration.volumesInUse == ["NAS", "Backups"])

        model.configuration.plans = [other]
        #expect(model.configuration.settings.networkShares.map(\.volumeName) == ["NAS", "Backups", "Spare"])

        model.configuration.plans = []
        model.configuration.repositories = []
        try #require(
            await eventually(within: 10) { model.configuration.settings.networkShares.map(\.volumeName) == ["Spare"] },
            "the unused shares were never forgotten"
        )
        #expect(try await secrets.loadSharePassword(nas.id) == nil)
    }

    @Test("the retention preview reconnects the repository's share first, and says why when it stays away")
    func previewReconnects() async throws {
        let (model, mounts, volume) = try await makeModel(answer: .failed(EAUTH))
        var repository = Repository()
        repository.kind = .local
        repository.localPath = "/Volumes/\(volume)/restic"
        model.configuration.repositories = [repository]
        var plan = BackupPlan()
        plan.repositoryID = repository.id
        plan.path = "/tmp/share-plan-source"
        await #expect {
            _ = try await model.previewRetention(plan: plan)
        } throws: { error in
            error.localizedDescription
                == "“\(volume)” is not connected. Reconnecting “\(volume)” failed: the share did not accept the user name and password."
        }
        #expect(await mounts.calls.map(\.url) == ["smb://me@nas.local/\(volume)"])
    }

    @Test("an editor's share row: as mounted now, else as saved, matched by volume")
    func editorShareRow() async throws {
        let (model, _, volume) = try await makeModel(answer: .failed(EAUTH))
        let saved = MountedShare(volumeName: volume, url: "smb://me@nas.local/\(volume)")
        let mounted = MountedShare(volumeName: volume, url: "smb://me@nas.local/\(volume)")
        var row = try #require(model.shareRow(for: "/Volumes/\(volume)/docs", mounted: nil))
        #expect(row.share == saved)
        #expect(row.isSaved)
        row = try #require(model.shareRow(for: "/Volumes/\(volume)/docs", mounted: mounted))
        #expect(row.share == mounted)
        #expect(row.isSaved)
        // A mounted volume of another name is the stale read of a path
        // since changed: ignored.
        let other = MountedShare(volumeName: "Other", url: "smb://me@other.local/Other")
        row = try #require(model.shareRow(for: "/Volumes/\(volume)/docs", mounted: other))
        #expect(row.share == saved)
        #expect(row.isSaved)
        #expect(model.shareRow(for: "/Users/me/Documents", mounted: mounted) == nil)
        model.configuration.settings.networkShares = []
        row = try #require(model.shareRow(for: "/Volumes/\(volume)/docs", mounted: mounted))
        #expect(row.share == mounted)
        #expect(!row.isSaved)
    }

    @Test("a refusal only the user clears is told from a server out of reach, which may come back by itself")
    func refusalOrUnreachable() {
        for refused in [EAUTH, ENOENT, EACCES, EPERM] {
            #expect(ShareMounter.failure(status: refused) == .refused(ShareMounter.describe(status: refused)), "status \(refused)")
        }
        for passing in [ETIMEDOUT, ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH, ENETUNREACH, ENETDOWN, -6600, EIO] {
            #expect(ShareMounter.failure(status: passing) == .unreachable(ShareMounter.describe(status: passing)), "status \(passing)")
        }
    }

    @Test("NetFS's status reads as the reason a reconnect failed")
    func statusWords() {
        #expect(ShareMounter.describe(status: EAUTH) == "the share did not accept the user name and password")
        #expect(ShareMounter.describe(status: ENOENT) == "the server has no share by that name")
        for unreachable in [ETIMEDOUT, ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH] {
            #expect(ShareMounter.describe(status: unreachable) == "the server couldn’t be reached")
        }
        #expect(ShareMounter.describe(status: -6600) == "macOS answered with error -6600")
        #expect(ShareMounter.describe(status: EIO) == "input/output error")
    }

    @Test("the skip names each share that couldn’t be reconnected, in the order its folders come")
    func skipWords() {
        let sources = ["/Volumes/Photos/2026", "/Volumes/NAS/Projects", "/Volumes/Photos/2025"]
        #expect(RunRecord.skippedReason(sources: sources) == "“Photos” and “NAS” are not connected.")
        #expect(RunRecord.skippedReason(sources: sources, reconnectFailures: [
            "NAS": "the server couldn’t be reached", "Photos": "no password is saved for it",
        ]) == "“Photos” and “NAS” are not connected. Reconnecting “Photos” failed: no password is saved for it."
            + " Reconnecting “NAS” failed: the server couldn’t be reached.")
    }

    @Test("saved shares round-trip in the configuration, and an older file without them reads as none")
    func persisted() throws {
        var settings = AppSettings()
        let share = NetworkShare(volumeName: "NAS", url: "smb://me@nas.local/NAS")
        settings.networkShares = [share]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.networkShares == [share])
        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"showMenuBarExtra": true}"#.utf8))
        #expect(older.networkShares.isEmpty)
    }

    @Test("a share's line in the run log says what happened")
    func logLines() {
        let reconnected = ShareReconnect(volumeName: "NAS", url: "smb://me@nas.local/NAS", outcome: .reconnected)
        #expect(reconnected.logLine == "Reconnected the network share smb://me@nas.local/NAS at /Volumes/NAS.")
        let failed = ShareReconnect(volumeName: "NAS", url: "smb://me@nas.local/NAS", outcome: .unreachable("the server couldn’t be reached"))
        #expect(failed.logLine == "Couldn’t reconnect the network share smb://me@nas.local/NAS: the server couldn’t be reached.")
    }
}
