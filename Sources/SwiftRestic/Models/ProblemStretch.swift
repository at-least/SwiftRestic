import Foundation

/// A backup problem's stretch: how many of a plan's backups in a row ended
/// the same way for the same cause (`isSameProblem(as:)`). A local
/// notification speaks for the first of them only
/// (`AppModel.wantsNotification(for:)`), and the plan page's problem row
/// counts them ("3 times in a row"). A success ends it — the outcome that
/// heals the row — as does another outcome or cause. A backup skipped or
/// stopped ran nothing, and passes over it (`passesOverProblems`).
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

    /// What a problem is about. A failure for folders gone from this Mac by
    /// their paths (`missingSources`: its message names only each one's
    /// last component), one for network shares that refused by their
    /// volumes (`refusedShares`); any other failure by restic's exit and
    /// first sentence. A warning by its unreadable items, exactly — two files are
    /// two problems — then its other lines (the decoding gap, a skipped
    /// retention) and hook complaints. The sentence, the other lines and the
    /// complaints lose their digits: a lock's PID and age, an address, a
    /// count, a hook's timing change from run to run.
    private var problemCause: String {
        func withoutDigits(_ text: String) -> String { text.filter { !$0.isNumber } }
        if outcome == .failed {
            if let missingSources { return "gone\n" + missingSources.joined(separator: "\n") }
            if let refusedShares { return "refused\n" + refusedShares.joined(separator: "\n") }
            let sentence = failureMessage.map(Format.firstSentence) ?? ""
            return "\(exitCode.map(String.init) ?? "-") " + withoutDigits(sentence)
        }
        let rest = (trailingItemErrors + hookMessages).map(withoutDigits)
        return (Array(unreadableItems) + rest).joined(separator: "\n")
    }

    /// This backup's stretch, `previous` being its plan's backup before it
    /// that did not pass over, or nil when there is none: the runs it stands
    /// for (`skipCount` — a failure merged into a standing one counts them
    /// all), plus `previous`'s stretch when that is the same problem. Nil for
    /// a backup that is not a problem.
    func stretchFollowing(_ previous: RunRecord?) -> Int? {
        guard isBackupProblem else { return nil }
        let own = skipCount ?? 1
        guard let previous, isSameProblem(as: previous) else { return own }
        guard let before = previous.problemStretch else {
            preconditionFailure("backup \(previous.id) has no problem stretch to continue")
        }
        return own + before
    }

    /// The history, newest first as stored, with each backup problem's
    /// stretch filled in from its plan's backup before it — the record just
    /// appended (`AppModel.append(record:)`), and at load any written before
    /// stretches were stored. A stored stretch stands: what it counted may
    /// have been trimmed by the history cap since, so it cannot be counted
    /// again.
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
