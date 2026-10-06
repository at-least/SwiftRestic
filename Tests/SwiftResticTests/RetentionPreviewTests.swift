import Foundation
import Testing

/// Apply Retention Now…'s preview: restic's `forget --dry-run --json` answer
/// read into what would go and what would stay, and the sheet's and the
/// record's words for it. The fixtures are trimmed from restic 0.19.1's own
/// output (design-probes/13-main-menu, r4.out and r1.out).
@Suite("retention preview")
struct RetentionPreviewTests {
    private static let tag = "swiftrestic-plan-11111111-2222-3333-4444-555555555555"

    private static func snapshotJSON(_ id: String, _ time: String, folder: String = "src") -> String {
        """
        {"time":"\(time)","paths":["/probe/\(folder)"],"hostname":"probe-mac","tags":["\(tag)"],\
        "id":"\(id)","short_id":"\(id.prefix(8))"}
        """
    }

    private static func snapshot(_ id: String, _ time: String) throws -> Snapshot {
        try ResticMessageDecoder.jsonDecoder.decode(Snapshot.self, from: Data(snapshotJSON(id, time).utf8))
    }

    /// Two path lineages under one tag, the probe's `--keep-last 1`: restic
    /// groups by host and paths, so each keeps its own newest.
    private static let twoGroups = """
    [{"tags":null,"host":"probe-mac","paths":["/probe/src2"],\
    "keep":[\(snapshotJSON("c924460006e441cee9c4590122ae070aa70be5dc913a8166a4672e47e5647ce4", "2026-09-20T09:30:00+08:00", folder: "src2"))],\
    "remove":[\(snapshotJSON("6015bf66f76feea53998697093f4a6b251f72566ad2ed2e726ac63bb35471e92", "2026-09-20T09:00:00+08:00", folder: "src2"))],\
    "reasons":[]},\
    {"tags":null,"host":"probe-mac","paths":["/probe/src"],\
    "keep":[\(snapshotJSON("d218b44e3ad6d83f9ac06f3f4b027bdc8a72ba0e327e3c3fc2d0b931e4f683db", "2026-09-25T10:00:00+08:00"))],\
    "remove":[\(snapshotJSON("b3476cf415f037ed00b465b77752b416d8bbbda003decdb4055147c465013487", "2026-09-24T10:00:00+08:00")),\
    \(snapshotJSON("9dd41ac5d250e93ab5a7cacc1b324d1911f76c611f13b227b281800dcbf06043", "2026-09-23T10:00:00+08:00")),\
    \(snapshotJSON("8b3371a1565446c882ec9c7468d9346d90112c77f5433f28ffa1608988999b29", "2026-09-22T10:00:00+08:00")),\
    \(snapshotJSON("8ae0a324386bfa6091b8d046117370df52ee276dbad1223b3cf78e1028000ac1", "2026-09-21T10:00:00+08:00"))],\
    "reasons":[]}]
    """

    @Test("keep and remove are read across every group, removals newest first")
    func parsesKeepAndRemoveAcrossGroups() throws {
        let preview = try RetentionPreview(forgetOutput: Self.twoGroups)

        #expect(preview.removed.map(\.shortID) == ["b3476cf4", "9dd41ac5", "8b3371a1", "8ae0a324", "6015bf66"])
        #expect(preview.removed.count == 5)
        #expect(preview.kept.count == 2)
        #expect(Set(preview.kept.map(\.shortID)) == ["c9244600", "d218b44e"])
        #expect(zip(preview.removed, preview.removed.dropFirst()).allSatisfy { $0.time > $1.time })
    }

    @Test("a null or absent list reads as empty, and so does no output at all")
    func nullOrAbsentListsAndEmptyOutputReadAsEmpty() throws {
        // The probe's --keep-last 10: nothing to remove came back as null.
        let keeps = (1 ... 5).map {
            Self.snapshotJSON(String(repeating: "\($0)", count: 64), "2026-09-2\($0)T10:00:00+08:00")
        }
        let nullRemove = """
        [{"tags":null,"host":"probe-mac","paths":["/probe/src"],"keep":[\(keeps.joined(separator: ","))],\
        "remove":null,"reasons":[]}]
        """
        let kept = try RetentionPreview(forgetOutput: nullRemove)
        #expect(kept.removed.isEmpty)
        #expect(kept.kept.count == 5)

        // Never seen from restic; read defensively rather than failing the
        // whole preview.
        for keep in [#""keep":null,"#, ""] {
            let output = """
            [{"host":"probe-mac","paths":["/probe/src"],\(keep)\
            "remove":[\(Self.snapshotJSON(String(repeating: "a", count: 64), "2026-09-21T10:00:00+08:00"))]}]
            """
            let preview = try RetentionPreview(forgetOutput: output)
            #expect(preview.kept.isEmpty)
            #expect(preview.removed.count == 1)
        }

        // A tag that matches nothing: restic 0.19.1 printed nothing at all.
        #expect(try RetentionPreview(forgetOutput: "") == RetentionPreview(kept: [], removed: []))
        #expect(try RetentionPreview(forgetOutput: "  \n") == RetentionPreview(kept: [], removed: []))

        #expect {
            try RetentionPreview(forgetOutput: "not json")
        } throws: { error in
            if case .malformedOutput = error as? ResticError { return true }
            return false
        }
    }

    @Test("the sheet's summary and the record's detail say what retention did")
    func summaryAndAppliedWording() throws {
        let oldest = try Self.snapshot(String(repeating: "1", count: 64), "2026-09-21T10:00:00+08:00")
        let middle = try Self.snapshot(String(repeating: "2", count: 64), "2026-09-22T10:00:00+08:00")
        let newest = try Self.snapshot(String(repeating: "3", count: 64), "2026-09-23T10:00:00+08:00")

        #expect(RetentionPreview(kept: [], removed: []).summary
            == "This plan has no snapshots in the repository yet.")
        #expect(RetentionPreview(kept: [newest], removed: []).summary
            == "Nothing to remove — this plan's only snapshot is within its rules.")
        #expect(RetentionPreview(kept: [newest, middle, oldest], removed: []).summary
            == "Nothing to remove — all 3 of this plan's snapshots are within its rules.")
        #expect(RetentionPreview(kept: [newest], removed: [oldest]).summary
            == "1 of this plan's 2 snapshots would be removed: the one from \(Format.timestamp(oldest.time)). 1 will stay.")
        #expect(RetentionPreview(kept: [newest], removed: [middle, oldest]).summary
            == "2 of this plan's 3 snapshots would be removed, from \(Format.timestamp(oldest.time)) to \(Format.timestamp(middle.time)). 1 will stay.")

        #expect(RetentionPreview.appliedSummary(removed: 0, pruned: false) == "No snapshots needed removing.")
        #expect(RetentionPreview.appliedSummary(removed: 0, pruned: true) == "No snapshots needed removing.")
        #expect(RetentionPreview.appliedSummary(removed: 2, pruned: false)
            == "Removed 2 snapshots. Their data stays until the next prune.")
        #expect(RetentionPreview.appliedSummary(removed: 1, pruned: true)
            == "Removed 1 snapshot and pruned their data.")
    }

    @Test("the preview's command differs from the real forget only by its dry-run flags")
    func previewArgumentsDifferFromForgetOnlyByDryRunFlags() {
        var plan = BackupPlan()
        plan.retention.runPrune = true

        let preview = ResticService.forgetArguments(plan: plan, dryRun: true)
        let apply = ResticService.forgetArguments(plan: plan, dryRun: false)

        #expect(preview.contains("--dry-run"))
        #expect(preview.contains("--no-lock"))
        // A dry run must never prune: restic would prune for real.
        #expect(!preview.contains("--prune"))
        #expect(apply.contains("--prune"))
        // restic refuses --no-lock on a real forget (exit 1, probed).
        #expect(!apply.contains("--no-lock"))
        #expect(!apply.contains("--dry-run"))

        let flags: Set<String> = ["--dry-run", "--no-lock", "--prune"]
        let common = ["forget", "--json", "--tag", ResticService.planTag(plan.id)] + plan.retention.forgetArguments
        #expect(preview.filter { !flags.contains($0) } == common)
        #expect(apply.filter { !flags.contains($0) } == common)
    }
}
