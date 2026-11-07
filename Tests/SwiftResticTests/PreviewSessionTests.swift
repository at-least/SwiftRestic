import Foundation
import Testing

@Suite("preview session", .serialized)
@MainActor
struct PreviewSessionTests {
    private struct Scene {
        var root: URL
        var model: AppModel
        var repository: Repository
        var snapshotID: String
        var fileNode: SnapshotNode
    }

    private func makeScene() async throws -> Scene {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticPreviewSession-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()
        let data = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let file = data.appendingPathComponent("note.txt")
        try "preview me".write(to: file, atomically: true, encoding: .utf8)

        var repository = Repository()
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        let password = "preview-session-test"
        _ = try await PinnedRestic.service().initializeRepository(RepositoryContext(repository: repository, password: password))
        var plan = BackupPlan()
        plan.repositoryID = repository.id
        plan.path = data.path
        plan.skipNothing()
        plan.schedule.frequency = .manual

        var configuration = AppConfiguration()
        configuration.repositories = [repository]
        configuration.plans = [plan]
        let store = ConfigStore(directory: root.appendingPathComponent("config"))
        try await store.save(configuration)
        let model = AppModel(store: store, secrets: .inMemory([repository.id: (password: password, providerSecret: nil)]), resticExecutable: try PinnedRestic.binary().url)
        await model.bootstrap()
        await model.tasks.drain()

        let service = try PinnedRestic.service()
        let context = try await model.context(for: repository)
        _ = try await service.backup(context, plan: plan)
        let listing = try await service.snapshots(context, planID: nil, timeout: 60)
        let snapshot = try #require(listing.first)
        let node = SnapshotNode(name: file.lastPathComponent, type: .file, path: file.path, size: Int64("preview me".utf8.count))
        return Scene(root: root, model: model, repository: repository, snapshotID: snapshot.id, fileNode: node)
    }

    private func previewFolders(in model: AppModel) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: model.stagingDirectory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.lastPathComponent.hasPrefix(AppModel.previewPrefix) }
    }

    private struct NodeGone: LocalizedError {
        var errorDescription: String? { "the node is gone" }
    }

    @Test("starting copies the file out and shows it; ending twice deletes the copy once and fails nothing")
    func startShowsAndEndDeletesOnce() async throws {
        let scene = try await makeScene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let session = PreviewSession()
        session.start(scene.model, repositoryID: scene.repository.id, snapshotID: scene.snapshotID, node: { scene.fileNode })
        try #require(await eventually(within: 30) { session.url != nil })
        let url = try #require(session.url)
        #expect(session.failure == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(previewFolders(in: scene.model).count == 1)

        // Safe to call any number of times: the second is a no-op, not a
        // second delete dressed as a failure.
        session.end()
        session.end()
        #expect(session.url == nil)
        #expect(session.failure == nil)
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        #expect(previewFolders(in: scene.model).isEmpty)
    }

    @Test("starting again keeps the first preview up until the second lands, then its copy is gone")
    func startingAgainReplacesTheCopy() async throws {
        let scene = try await makeScene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let session = PreviewSession()
        session.start(scene.model, repositoryID: scene.repository.id, snapshotID: scene.snapshotID, node: { scene.fileNode })
        try #require(await eventually(within: 30) { session.url != nil })
        let first = try #require(session.url)

        session.start(scene.model, repositoryID: scene.repository.id, snapshotID: scene.snapshotID, node: { scene.fileNode })
        // `previewSession(_:)` ends the session when url turns nil — the
        // panel closing — so a nil here would end the copy just started.
        #expect(session.url == first)
        #expect(FileManager.default.fileExists(atPath: first.path), "the copy the panel shows was deleted under it")
        try #require(await eventually(within: 30) { session.url != nil && session.url != first })
        #expect(session.failure == nil)
        // The cancelled first task winds down beside the second: once its
        // copy is gone, only the second's folder is left.
        try #require(await eventually(within: 30) { self.previewFolders(in: scene.model).count == 1 })
        #expect(!FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        session.end()
        #expect(previewFolders(in: scene.model).isEmpty)
    }

    @Test("a node that fails names the failure Couldn’t preview, with the error's own words, and copies nothing")
    func failedNodeFailsThePreview() async throws {
        let scene = try await makeScene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let session = PreviewSession()
        session.start(scene.model, repositoryID: scene.repository.id, snapshotID: scene.snapshotID, node: { throw NodeGone() })
        try #require(await eventually(within: 30) { session.failure != nil })
        #expect(session.failure == PreviewSession.Failure(title: "Couldn’t preview", message: "the node is gone"))
        #expect(session.url == nil)
        #expect(previewFolders(in: scene.model).isEmpty)
    }

    @Test("a version too large to look at is refused before any copy, by the refusal's own line")
    func oversizedNodeIsRefusedBeforeCopying() async throws {
        let scene = try await makeScene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let big = SnapshotNode(name: "big.bin", type: .file, path: "/Projects/big.bin", size: VersionPreview.sizeLimit + 1)
        let session = PreviewSession()
        session.start(scene.model, repositoryID: scene.repository.id, snapshotID: scene.snapshotID, node: { big })
        try #require(await eventually(within: 30) { session.failure != nil })
        #expect(session.failure == PreviewSession.Failure(
            title: VersionPreview.unavailableReason(size: big.size, isReading: false)!, message: ""))
        #expect(session.url == nil)
        #expect(previewFolders(in: scene.model).isEmpty)
    }

    @Test("ending a copy parked on its node cancels it: no failure and no folder")
    func endingAParkedCopyLeavesNothing() async throws {
        let scene = try await makeScene()
        defer { try? FileManager.default.removeItem(at: scene.root) }
        let session = PreviewSession()
        // The stream parks the node read until the task is cancelled, which
        // ends the stream — the closure then throws, the way a read that
        // lost its source would.
        let flag = Flag()
        let (stream, continuation) = AsyncStream<SnapshotNode>.makeStream()
        let node: @MainActor () async throws -> SnapshotNode = {
            for await offered in stream { return offered }
            flag.set()
            throw NodeGone()
        }
        session.start(scene.model, repositoryID: scene.repository.id, snapshotID: scene.snapshotID, node: node)
        session.end()
        #expect(await eventually(within: 30) { flag.isSet })
        #expect(session.failure == nil)
        #expect(previewFolders(in: scene.model).isEmpty)
        continuation.finish()
    }
}
