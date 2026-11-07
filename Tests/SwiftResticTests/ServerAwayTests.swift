import Foundation
import Testing

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
        repository.kind = .rest
        // Never dialled: the probe below answers for it.
        repository.restURL = "http://127.0.0.1:9/app"
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
        let store = ConfigStore(directory: root.appendingPathComponent("config"))
        try await store.save(configuration)

        let answer = ProbeAnswer(.unreachable("connection refused"))
        let model = AppModel(
            store: store,
            secrets: .inMemory([repository.id: (password: "test-password", providerSecret: nil)]),
            serverProbe: ServerProbe { _, _ in await answer.current },
            resticExecutable: stub.url
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
            await eventually(within: 20) { model.configuration.runs.count >= count }
        }

        // A failed requirement still stops the model, whose scheduler would
        // otherwise tick on into later tests.
        do {
            let words = "“127.0.0.1” cannot be reached (connection refused)."
            #expect(model.snapshotListingOutcomes[repository.id] == .failed(words))

            await waitForRuns(1)
            let skipped = try #require(model.configuration.runs.first)
            #expect(skipped.outcome == .skipped)
            #expect(skipped.detailText == words)
            #expect(resticCommands().isEmpty, "restic ran: \(resticCommands())")

            await answer.set(.reachable)
            await model.networkPathChanged()
            await waitForRuns(2)
            await model.waitForRun(planID: plan.id)
            let ran = try #require(model.configuration.runs.first)
            #expect(ran.outcome == .succeeded, "outcome \(ran.outcome), \(ran.failureMessage ?? "")")
            #expect(resticCommands().contains { $0.contains(" backup ") || $0.contains("[backup ") }, "restic ran: \(resticCommands())")
            #expect(
                await eventually(within: 10) { model.snapshotListingOutcomes[repository.id] == .loaded }
            )
        } catch {
            await model.shutdown()
            throw error
        }
        await model.shutdown()
    }

    @Test("a location whose listing hangs at launch delays no other location's due plan, and its own plan waits for its listing")
    func hungListingHoldsOnlyItsOwnPlan() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftResticLaunchHang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = try StubRestic.install(in: root)

        func location(_ name: String, stubMode: String) throws -> (Repository, BackupPlan) {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var repository = Repository()
            repository.localPath = folder.path
            repository.extraEnvironment = ["SWIFTRESTIC_STUB": stubMode]
            var plan = BackupPlan()
            plan.repositoryID = repository.id
            plan.path = folder.path
            plan.retention.isEnabled = false
            // Daily and never run: due at the scheduler's first tick.
            plan.schedule.frequency = .daily
            return (repository, plan)
        }
        let (hung, hungPlan) = try location("Hung", stubMode: "hang-listing")
        let (fine, finePlan) = try location("Fine", stubMode: "default")

        var configuration = AppConfiguration()
        configuration.repositories = [hung, fine]
        configuration.plans = [hungPlan, finePlan]
        let store = ConfigStore(directory: root.appendingPathComponent("config"))
        try await store.save(configuration)

        let model = AppModel(store: store, secrets: .inMemory([
            hung.id: (password: "test-password", providerSecret: nil),
            fine.id: (password: "test-password", providerSecret: nil),
        ]), resticExecutable: stub.url)
        model.launchListingGrace = .milliseconds(500)
        let boot = Task { await model.bootstrap() }

        await eventually(within: 15) { model.configuration.runs.contains { $0.planID == finePlan.id } }
        #expect(model.configuration.runs.contains { $0.planID == finePlan.id && $0.kind == .backup })
        #expect(!model.configuration.runs.contains { $0.planID == hungPlan.id })
        #expect(!model.isRunning(planID: hungPlan.id))
        #expect(model.repositoriesAwaitingLaunchListing == [hung.id])

        await model.shutdown()
        await boot.value
    }
}
