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
                applyingRetentionNames: [],
                isMaintaining: false,
                isConsoleRunning: false
            ) == "Its plans “Documents” and “Photos” are removed too. The backups in it are kept."
        )
        #expect(
            AppModel.removalConsequences(
                removedPlanNames: ["Documents"],
                isRestoring: false,
                runningBackupNames: [],
                applyingRetentionNames: [],
                isMaintaining: false,
                isConsoleRunning: false
            ) == "Its plan “Documents” is removed too. The backups in it are kept."
        )
        // Three, joined as every list in the app is (`Format.list`), not
        // by the Mac's locale.
        #expect(
            AppModel.removalConsequences(
                removedPlanNames: ["Documents", "Photos", "Music"],
                isRestoring: false,
                runningBackupNames: [],
                applyingRetentionNames: [],
                isMaintaining: false,
                isConsoleRunning: false
            ) == "Its plans “Documents”, “Photos” and “Music” are removed too. The backups in it are kept."
        )
        // No plan uses it: nothing is removed with it, so nothing says so.
        #expect(
            AppModel.removalConsequences(
                removedPlanNames: [],
                isRestoring: false,
                runningBackupNames: [],
                applyingRetentionNames: [],
                isMaintaining: false,
                isConsoleRunning: false
            ) == "The backups in it are kept."
        )
    }

    @Test("every kind of work in flight gets its own clause")
    func clauses() {
        let sentence = AppModel.removalConsequences(
            removedPlanNames: ["Nightly"],
            isRestoring: true,
            runningBackupNames: ["Nightly", "Untitled Plan"],
            applyingRetentionNames: ["Weekly"],
            isMaintaining: true,
            isConsoleRunning: true
        )
        #expect(sentence.contains("A restore from this repository is running and will be cancelled."))
        #expect(sentence.contains("Backups of “Nightly” and “Untitled Plan” are running and will be cancelled."))
        #expect(sentence.contains("Retention is being applied to “Weekly” and will be cancelled."))
        #expect(sentence.contains("Repository maintenance is running and will be cancelled."))
        #expect(sentence.contains("A console command is running and will be cancelled."))
    }
}
