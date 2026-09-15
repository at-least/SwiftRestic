import Foundation
import Testing

/// The per-repository resolved-context cache: a restic call no longer
/// re-reads the secret store every time, and every input a context actually
/// depends on invalidates by comparison — no save-site hooks to keep honest.
@MainActor
@Suite("resolved context cache")
struct ContextCacheTests {
    /// A counting wrapper around an in-memory store, so the tests can assert
    /// how many times the Keychain would have been read.
    private final class LoadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private func makeHarness() -> (model: AppModel, loads: LoadCounter, repository: Repository) {
        var repository = Repository()
        repository.name = "Cache Test"
        repository.kind = .local
        repository.localPath = "/tmp/swiftrestic-cache-test-repo"

        let counter = LoadCounter()
        let backing = SecretStore.inMemory([repository.id: ("stored-password", nil)])
        let counting = SecretStore(
            load: { id in
                await counter.increment()
                return await backing.load(id)
            },
            save: backing.save,
            remove: backing.remove
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticContextCache-\(UUID().uuidString)")
        let model = AppModel(store: ConfigStore(directory: root), secrets: counting)
        return (model, counter, repository)
    }

    @Test("a second context for the same repository costs no secret read")
    func cacheHitsWithinConfig() async throws {
        let (model, loads, repository) = makeHarness()
        let first = try await model.context(for: repository)
        let second = try await model.context(for: repository)
        #expect(loads.value == 1)
        #expect(first.password == second.password)
    }

    @Test("editing the repository invalidates the cache by comparison")
    func repositoryEditInvalidates() async throws {
        let (model, loads, repository) = makeHarness()
        _ = try await model.context(for: repository)
        var moved = repository
        moved.localPath = "/tmp/elsewhere"
        _ = try await model.context(for: moved)
        #expect(loads.value == 2)
    }

    @Test("changing a rate limit invalidates; changing other settings does not")
    func settingsChanges() async throws {
        let (model, loads, repository) = makeHarness()
        _ = try await model.context(for: repository)

        model.configuration.settings.uploadLimitKiBps = 512
        _ = try await model.context(for: repository)
        #expect(loads.value == 2, "a limit a context carries must invalidate it")

        model.configuration.settings.consoleHistory = ["snapshots --json"]
        _ = try await model.context(for: repository)
        #expect(loads.value == 2, "a setting no context reads must not invalidate it")
    }

    @Test("an auth-class failure drops the entry; other failures do not")
    func authFailureInvalidates() async throws {
        let (model, loads, repository) = makeHarness()
        _ = try await model.context(for: repository)

        model.noteAuthFailure(
            ResticError.commandFailed(exitCode: 12, message: "wrong password", command: "restic backup"),
            repositoryID: repository.id
        )
        _ = try await model.context(for: repository)
        #expect(loads.value == 2, "exit 12 must force a fresh secret read")

        model.noteAuthFailure(
            ResticError.commandFailed(exitCode: 11, message: "locked", command: "restic backup"),
            repositoryID: repository.id
        )
        _ = try await model.context(for: repository)
        #expect(loads.value == 2, "a lock failure says nothing about the credentials")
    }

    @Test("changing only the password invalidates the cache")
    func secretEditInvalidates() async throws {
        let (model, loads, repository) = makeHarness()
        _ = try await model.context(for: repository)
        // A password-only edit: the Repository value is unchanged, so the
        // key cannot notice — upsert must drop the entry explicitly, or the
        // next run would use the old password until an exit-12 cleared it.
        await model.upsert(repository: repository, password: "rotated", providerSecret: nil)
        let context = try await model.context(for: repository)
        #expect(context.password == "rotated")
        #expect(loads.value == 2)
    }

    @Test("a missing password is never cached as success")
    func failuresAreNotCached() async throws {
        let repository = Repository()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticContextCache-\(UUID().uuidString)")
        let model = AppModel(store: ConfigStore(directory: root), secrets: .inMemory())

        await #expect(throws: ResticError.self) { try await model.context(for: repository) }
        // The store gains the password afterwards; without a cached failure
        // in the way, the very next call succeeds.
        try? await model.secrets.save(repository.id, "late-password", nil)
        let context = try await model.context(for: repository)
        #expect(context.password == "late-password")
    }
}
