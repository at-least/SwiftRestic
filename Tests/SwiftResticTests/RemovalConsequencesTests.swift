import Foundation
import Testing

/// The removal dialog's wording, tested as the pure sentence-builder it is:
/// its clauses must enumerate exactly what `deleteRepository` cancels, or
/// the dialog understates the interruption it asks to approve.
@Suite("Repository removal consequences")
struct RemovalConsequencesTests {
    @Test("a quiet repository's removal names the plans it removes and touches nothing in flight")
    func quiet() {
        // A plan follows its repository out, so the dialog that approves the
        // removal names every plan that goes with it.
        #expect(
            AppModel.removalConsequences(
                removedPlanNames: ["Documents", "Photos"],
                isRestoring: false,
                runningBackupNames: [],
                isMaintaining: false,
                isConsoleRunning: false
            ) == "The backup data itself is not deleted. Its plans will be removed too (Documents, Photos)."
        )
        // No plan uses it: nothing is removed with it, so nothing says so.
        #expect(
            AppModel.removalConsequences(
                removedPlanNames: [],
                isRestoring: false,
                runningBackupNames: [],
                isMaintaining: false,
                isConsoleRunning: false
            ) == "The backup data itself is not deleted."
        )
    }

    @Test("every kind of work in flight gets its own clause")
    func clauses() {
        let sentence = AppModel.removalConsequences(
            removedPlanNames: ["Nightly"],
            isRestoring: true,
            runningBackupNames: ["Nightly", "Untitled Plan"],
            isMaintaining: true,
            isConsoleRunning: true
        )
        #expect(sentence.contains("A restore from this repository is running and will be cancelled."))
        #expect(sentence.contains("A backup (Nightly, Untitled Plan) is running and will be cancelled."))
        #expect(sentence.contains("Repository maintenance is running and will be cancelled."))
        #expect(sentence.contains("A console command is running and will be cancelled."))
    }
}
