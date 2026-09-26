import Foundation
import Testing
import UniformTypeIdentifiers

/// The Restore pane's drag-to-Finder restore when the drop can never land:
/// the provider must promise nothing — Finder then refuses the drop — and
/// the reason is named at drag start, since a refused drop explains nothing.
/// No restic needed: both failures happen before anything would run.
@MainActor
@Suite("drag restore provider")
struct DragRestoreProviderTests {
    @Test("a drag that can never land registers nothing and says why at drag start")
    func impossibleDragRegistersNothing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticDrag-\(UUID().uuidString)")
        // Never bootstrapped: no restic has been resolved.
        let model = AppModel(store: ConfigStore(directory: root), secrets: .inMemory())
        let node = SnapshotNode(name: "a.txt", type: .file, path: "/Data/a.txt")

        // A record picked from a repository that is gone.
        let orphan = model.dragRestoreProvider(repositoryID: UUID(), snapshotID: "s1", node: node)
        #expect(orphan.registeredTypeIdentifiers.isEmpty)
        let gone = try #require(model.banners.first)
        #expect(gone.title == "Cannot drag to restore")
        #expect(gone.message.contains("no longer exists"))
        #expect(gone.isError)

        // The repository exists, but no restic binary does.
        var repository = Repository()
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        model.configuration.repositories = [repository]
        let unresolved = model.dragRestoreProvider(repositoryID: repository.id, snapshotID: "s1", node: node)
        #expect(unresolved.registeredTypeIdentifiers.isEmpty)
        #expect(model.banners.contains {
            $0.title == "Cannot drag to restore" && $0.message == (model.binaryProblem ?? "restic could not be found.")
        })
    }
}
