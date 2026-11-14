import Foundation
import Testing

/// What `ResticService` asks restic for, read from the run's transcript. A
/// stub answers every command with success, so only the command line is
/// under test; what restic does with it is the end-to-end suites' subject.
@Suite("restic command lines")
struct ResticCommandLineTests {
    private func commandLines(
        of work: (ResticService, RepositoryContext) async throws -> Void
    ) async throws -> [String] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticCommandLine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = try StubRestic.install(in: root)

        var repository = Repository()
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        repository.extraEnvironment = ["SWIFTRESTIC_STUB": "default"]
        let context = RepositoryContext(repository: repository, password: "stub")
        let service = ResticService(runner: ResticRunner(), binary: stub.url)

        let transcript = RunTranscript()
        try await RunTranscript.$current.withValue(transcript) {
            try await work(service, context)
        }
        return transcript.contents.entries.filter { $0.kind == .command }.map(\.text)
    }

    @Test("a repair's first step rebuilds the index")
    func repairIndexRebuildsTheIndex() async throws {
        let lines = try await commandLines { service, context in try await service.repairIndex(context) }
        #expect(lines == ["restic repair index"], "Repair's index step ran \(lines)")
    }

    /// Without `--forget` the damaged backup stays beside its repaired copy
    /// and the verification after the repair still fails (restic 0.19.1).
    @Test("a repair removes each damaged backup it replaced")
    func repairSnapshotsForgetsTheDamagedOriginals() async throws {
        let lines = try await commandLines { service, context in try await service.repairSnapshots(context) }
        #expect(
            lines == ["restic repair snapshots --forget"],
            "Repair left the damaged backups in place, so the location still fails verification: \(lines)"
        )
    }

    @Test("a backup carries its plan's tag")
    func backupCarriesItsPlansTag() async throws {
        var plan = BackupPlan()
        plan.path = "/Users/someone/Documents"
        let lines = try await commandLines { service, context in _ = try await service.backup(context, plan: plan) }
        #expect(lines.count == 1, "one backup ran \(lines.count) restic commands")
        // Compared by its ends: the command line between them is the
        // plan's whole exclude list, which would bury the failure.
        let words = try #require(lines.first).split(separator: " ")
        #expect(words.prefix(4).joined(separator: " ") == "restic backup --json /Users/someone/Documents")
        #expect(
            words.suffix(2).joined(separator: " ") == "--tag \(ResticService.planTag(plan.id))",
            "a backup without its plan's tag belongs to no plan: the plan's history and its old-backup removal never find it"
        )
    }
}
