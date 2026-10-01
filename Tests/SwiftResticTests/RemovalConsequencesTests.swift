import Foundation
import Testing

/// The removal dialog's wording, tested as the pure sentence-builder it is:
/// its clauses must enumerate exactly what `deleteRepository` cancels, or
/// the dialog understates the interruption it asks to approve.
@Suite("Repository removal consequences")
struct RemovalConsequencesTests {
    @Test("a quiet repository's removal names the plans it pauses and touches nothing in flight")
    func quiet() {
        // The repository page no longer lists the plans that use it
        // (b5248e6), so the one moment that needs the names — before they
        // are paused — says them.
        #expect(
            AppModel.removalConsequences(
                pausedPlanNames: ["Documents", "Photos"],
                isRestoring: false,
                runningBackupNames: [],
                isMaintaining: false,
                isConsoleRunning: false
            ) == "The backup data itself is not deleted. Plans pointing at it will be paused (Documents, Photos)."
        )
        // No plan uses it: nothing is paused, so nothing says so.
        #expect(
            AppModel.removalConsequences(
                pausedPlanNames: [],
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
            pausedPlanNames: ["Nightly"],
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
