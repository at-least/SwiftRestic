import Foundation

/// A backup problem's stretch: how many of a plan's backups in a row ended
/// the same way for the same cause. A local notification speaks for the
/// first only (`AppModel.wantsNotification(for:)`); the plan page's problem
/// row counts them ("3 times in a row"). Any other outcome or cause ends it;
/// a backup skipped or stopped ran nothing and passes over it.
extension RunRecord {
    private var isBackupProblem: Bool {
        kind == .backup && outcome.isProblem
    }

    private var passesOverProblems: Bool {
        kind == .backup && (outcome == .cancelled || outcome == .skipped)
    }

    func isSameProblem(as other: RunRecord) -> Bool {
        isBackupProblem && other.isBackupProblem && outcome == other.outcome && problemCause == other.problemCause
    }

    /// Missing sources by their paths (the message names only each last
    /// component); refused shares by their volumes; any other failure by
    /// restic's exit and first sentence. A warning by its unreadable items
    /// exactly, then its other lines. Sentences and other lines lose their
    /// digits: a lock's PID and age, an address, a count change between runs.
    private var problemCause: String {
        func withoutDigits(_ text: String) -> String { text.filter { !$0.isNumber } }
        if outcome == .failed {
            if let missingSources { return "gone\n" + missingSources.joined(separator: "\n") }
            if let refusedShares { return "refused\n" + refusedShares.joined(separator: "\n") }
            let sentence = failureMessage.map(Format.firstSentence) ?? ""
            return "\(exitCode.map(String.init) ?? "-") " + withoutDigits(sentence)
        }
        let rest = trailingItemErrors.map(withoutDigits)
        return (Array(unreadableItems) + rest).joined(separator: "\n")
    }

    /// `previous`: the plan's backup before this one that did not pass over.
    /// A failure merged into a standing one counts all it stands for
    /// (`skipCount`).
    func stretchFollowing(_ previous: RunRecord?) -> Int? {
        guard isBackupProblem else { return nil }
        let own = skipCount ?? 1
        guard let previous, isSameProblem(as: previous) else { return own }
        guard let before = previous.problemStretch else {
            preconditionFailure("backup \(previous.id) has no problem stretch to continue")
        }
        return own + before
    }

    /// `runs` newest first, as stored. A stored stretch stands: what it
    /// counted may have been trimmed by the history cap since.
    static func fillingProblemStretches(_ runs: [RunRecord]) -> [RunRecord] {
        var runs = runs
        var previous: [UUID: RunRecord] = [:]
        for index in runs.indices.reversed() {
            let run = runs[index]
            guard run.kind == .backup, let planID = run.planID, !run.passesOverProblems else { continue }
            if run.isBackupProblem, run.problemStretch == nil {
                runs[index].problemStretch = run.stretchFollowing(previous[planID])
            }
            previous[planID] = runs[index]
        }
        return runs
    }
}
