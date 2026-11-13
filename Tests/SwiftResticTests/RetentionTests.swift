import Foundation
import Testing

@Suite("retention")
struct RetentionTests {
    private static let tag = "swiftrestic-plan-11111111-2222-3333-4444-555555555555"

    private static func snapshotJSON(_ id: String, _ time: String, folder: String = "src") -> String {
        """
        {"time":"\(time)","paths":["/probe/\(folder)"],"hostname":"probe-mac","tags":["\(tag)"],\
        "id":"\(id)","short_id":"\(id.prefix(8))"}
        """
    }

    @Test("a forget that couldn’t remove some backups counts the ones that went, and an output it cannot read claims no count")
    func partialRemovalCountsOrStaysRestics() throws {
        let stderr = """
        Remove(<snapshot/860f8ac74b>) failed: unexpected HTTP response (403): 403 Forbidden
        unable to remove snapshot/860f8ac74b from the repository
        """
        let two = """
        [{"host":"probe-mac","paths":["/probe/src"],"keep":[],"remove":[\(Self.snapshotJSON(String(repeating: "a", count: 64), "2026-09-21T10:00:00+08:00")),\(Self.snapshotJSON(String(repeating: "b", count: 64), "2026-09-22T10:00:00+08:00"))]}]
        """
        let counted = ResticService.removalFailure(ResticRunResult(exitCode: 3, messages: [], stdout: two, stderr: stderr))
        #expect(counted == .snapshotsNotRemoved(removed: 1, refused: 1, reason: "403 Forbidden"))

        let unread = ResticService.removalFailure(ResticRunResult(exitCode: 3, messages: [], stdout: "not json", stderr: stderr))
        guard case .commandFailed(exitCode: 3, _) = unread else {
            Issue.record("an unreadable forget output became \(unread)")
            return
        }
    }

    @Test("every plan's forget passes the Recommended rules on the plan's tag, and never prunes")
    func forgetArgumentsAreRecommended() {
        let plan = BackupPlan()
        let args = ResticService.forgetArguments(plan: plan)
        #expect(args == [
            "forget", "--json", "--tag", ResticService.planTag(plan.id),
            "--keep-hourly", "24", "--keep-daily", "7", "--keep-weekly", "4",
            "--keep-monthly", "12", "--keep-yearly", "3",
        ])
    }
}
