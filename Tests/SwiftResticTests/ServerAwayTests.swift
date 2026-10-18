import Foundation
import Testing

/// A probe answer the test changes mid-run: the server going and coming.
private actor ProbeAnswer {
    var current: ServerProbe.Outcome
    init(_ current: ServerProbe.Outcome) { self.current = current }
    func set(_ outcome: ServerProbe.Outcome) { current = outcome }
}

@MainActor
@Suite("a network repository's server out of reach", .serialized)
struct ServerAwayTests {
    @Test("the listing answers in the probe's words without restic, the due backup skips, and a network change reads it again and runs the plan")
    func serverAwayThenBack() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftResticServerAway-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = try StubRestic.install(in: root)
        let traceFile = root.appendingPathComponent("stub-trace.log")

        var repository = Repository()
        repository.name = "Home Server"
        repository.kind = .rest
        // Never dialled: the probe below answers for it.
        repository.restURL = "http://127.0.0.1:9/app"
        repository.maintenance.checkEnabled = false
        repository.extraEnvironment = ["SWIFTRESTIC_STUB": "default", "SWIFTRESTIC_TRACE": traceFile.path]

        var plan = BackupPlan()
        plan.repositoryID = repository.id
        plan.path = root.path
        plan.retention.isEnabled = false
        // Daily and never run: due at the scheduler's first tick.
        plan.schedule.frequency = .daily

        var configuration = AppConfiguration()
        configuration.repositories = [repository]
        configuration.plans = [plan]
        configuration.settings.resticPathOverride = stub.url.path
        let store = ConfigStore(directory: root.appendingPathComponent("config"))
        try await store.save(configuration)

        let answer = ProbeAnswer(.unreachable("connection refused"))
        let model = AppModel(
            store: store,
            secrets: .inMemory([repository.id: (password: "test-password", providerSecret: nil)]),
            serverProbe: ServerProbe { _, _ in await answer.current }
        )
        await model.bootstrap()

        func resticCommands() -> [String] {
            let trace = (try? String(contentsOf: traceFile, encoding: .utf8)) ?? ""
            // The launch's `restic version` aside: it asks no repository.
            return trace.split(separator: "\n")
                .filter { $0.hasPrefix("start args=[") && !$0.hasPrefix("start args=[version") }
                .map(String.init)
        }
        func waitForRuns(_ count: Int) async {
            let deadline = Date.now.addingTimeInterval(20)
            while model.configuration.runs.count < count, Date.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        let words = "“Home Server” cannot be reached (connection refused)."
        #expect(model.snapshotListingOutcomes[repository.id] == .failed(words))

        // The scheduler's first tick starts the due backup, which skips.
        await waitForRuns(1)
        let skipped = try #require(model.configuration.runs.first)
        #expect(skipped.outcome == .skipped)
        #expect(skipped.detailText == words)
        #expect(resticCommands().isEmpty, "restic ran: \(resticCommands())")

        // The server back: the network's change reads the listing again and
        // runs the plan whose backup it skipped.
        await answer.set(.reachable)
        model.networkPathChanged()
        await waitForRuns(2)
        await model.waitForRun(planID: plan.id)
        let ran = try #require(model.configuration.runs.first)
        #expect(ran.outcome == .succeeded, "outcome \(ran.outcome), \(ran.failureMessage ?? "")")
        #expect(resticCommands().contains { $0.contains(" backup ") || $0.contains("[backup ") }, "restic ran: \(resticCommands())")
        let deadline = Date.now.addingTimeInterval(10)
        while model.snapshotListingOutcomes[repository.id] != .loaded, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.snapshotListingOutcomes[repository.id] == .loaded)

        await model.shutdown()
    }
}
