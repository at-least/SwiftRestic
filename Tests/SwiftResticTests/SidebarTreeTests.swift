import Foundation
import Testing

/// The sidebar's shape, as the pure rules the view lays out: repositories at
/// the top, each with its plans, the way to its first plan while it has
/// none, and its Restore node.
@Suite("Sidebar tree")
struct SidebarTreeTests {
    private func plan(_ name: String, in repository: UUID?) -> BackupPlan {
        var plan = BackupPlan()
        plan.name = name
        plan.repositoryID = repository
        return plan
    }

    private func repository(_ name: String) -> Repository {
        var repository = Repository()
        repository.name = name
        return repository
    }

    @Test("a repository lists its own plans in configuration order, then Restore")
    func plansThenRestore() {
        let nas = UUID()
        let documents = plan("Documents", in: nas)
        let elsewhere = plan("Elsewhere", in: UUID())
        let photos = plan("Photos", in: nas)
        #expect(SidebarTree.children(of: nas, in: [documents, elsewhere, photos])
            == [.plan(documents.id), .plan(photos.id), .restore])
    }

    @Test("a repository with no plan offers its first one where its plans would be")
    func noPlanOffersOne() {
        // The dead end the user reported: a new repository and nowhere to
        // add a plan to it.
        let test = UUID()
        #expect(SidebarTree.children(of: test, in: [plan("Elsewhere", in: UUID())]) == [.addPlan, .restore])
        #expect(SidebarTree.children(of: test, in: []) == [.addPlan, .restore])
    }

    @Test("the landing pane is the first repository's page, or the welcome when there is none")
    func landing() {
        let nas = repository("NAS")
        let b2 = repository("B2")
        #expect(SidebarTree.landingSelection(repositories: [nas, b2]) == .repository(nas.id))
        #expect(SidebarTree.landingSelection(repositories: []) == nil)
    }

    @Test("a repository needs attention for an unreadable listing or a known-unprotected plan, never for pending or running ones")
    func attention() {
        let repository = UUID()
        func row(_ name: String, isKnown: Bool, isProtected: Bool, didFail: Bool = false, isRunning: Bool = false) -> ProtectionRow {
            ProtectionRow(
                plan: plan(name, in: repository),
                stateText: name,
                isKnown: isKnown,
                isProtected: isProtected,
                didFail: didFail,
                isRunning: isRunning
            )
        }
        let unreadable = row("Unreadable", isKnown: false, isProtected: false, didFail: true)
        let exposed = row("Exposed", isKnown: true, isProtected: false)
        let pending = row("Pending", isKnown: false, isProtected: false)
        let running = row("Running", isKnown: true, isProtected: false, isRunning: true)
        let protected = row("Protected", isKnown: true, isProtected: true)

        #expect(OverviewMetrics.needingAttention([protected, unreadable, pending, exposed, running]).map(\.planName)
            == ["Unreadable", "Exposed"])
        #expect(OverviewMetrics.needingAttention([protected, pending, running]).isEmpty)
    }
}
