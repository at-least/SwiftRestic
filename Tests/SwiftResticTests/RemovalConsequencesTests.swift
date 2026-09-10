import Foundation
import Testing

/// The removal dialog's wording, tested as the pure sentence-builder it is:
/// its clauses must enumerate exactly what `deleteRepository` cancels, or
/// the dialog understates the interruption it asks to approve.
@Suite("Repository removal consequences")
struct RemovalConsequencesTests {
    @Test("a quiet repository's removal pauses plans and touches nothing in flight")
    func quiet() {
        #expect(
            AppModel.removalConsequences(
                isRestoring: false,
                runningBackupNames: [],
                isMaintaining: false,
                isConsoleRunning: false
            ) == "The backup data itself is not deleted. Plans pointing at it will be paused."
        )
    }

    @Test("every kind of work in flight gets its own clause")
    func clauses() {
        let sentence = AppModel.removalConsequences(
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
