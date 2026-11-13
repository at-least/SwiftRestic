import Foundation
import Testing

@Suite("Skipped runs and cloud files")
struct SkippedRunTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("the reason names the drive every folder is on, each drive once")
    func skippedReason() {
        #expect(RunRecord.skippedReason(sources: ["/Volumes/Archive SSD/Documents", "/Volumes/Archive SSD/Photos"])
            == "“Archive SSD” is not connected.")
        #expect(RunRecord.skippedReason(sources: ["/Volumes/Archive SSD/Documents", "/Volumes/Travel/Code"])
            == "“Archive SSD” and “Travel” are not connected.")
    }

    @Test("a folder on this Mac's own disk is never one that is not connected, even beside a drive that is away")
    func notConnectedNeedsEveryFolderOnADrive() {
        #expect(RunRecord.notConnected(["/Volumes/Archive SSD/Documents"]) == "“Archive SSD” is not connected")
        #expect(RunRecord.notConnected(["/Volumes/Archive SSD/Documents", "/Users/me/Documents"]) == nil)
        #expect(RunRecord.notConnected(["/Users/me/Documents"]) == nil)
    }

    @Test("a rewrite of a rewrite listed ahead of the one it names still joins the backup's run, in one listing")
    func rewriteChainJoinsTheRunInOneListing() throws {
        func snapshot(_ id: String, original: String?) throws -> Snapshot {
            let originalField = original.map { #","original":"\#($0)""# } ?? ""
            let json = #"{"id":"\#(id)","time":"2026-09-25T02:00:00Z","paths":["/src"]\#(originalField)}"#
            return try ResticMessageDecoder.jsonDecoder.decode(Snapshot.self, from: Data(json.utf8))
        }
        var run = RunRecord(kind: .backup, planID: UUID(), planName: "src", startedAt: now)
        run.snapshotID = "first"
        // Newest first, as restic lists them: the second rewrite comes before
        // the first rewrite it names.
        let listing = [try snapshot("second", original: "first-rewrite"), try snapshot("first-rewrite", original: "first")]

        let adopted = try #require(RunRecord.adoptingRewrites([run], listing: listing))
        #expect(adopted[0].rewrittenSnapshotIDs == ["first-rewrite", "second"])
        #expect(RunRecord.backupRunsBySnapshot(adopted)["second"]?.id == run.id)
        #expect(RunRecord.adoptingRewrites(adopted, listing: listing) == nil, "a listing already adopted changes nothing")
    }

    @Test("a failure for the same shares refused continues the plan's last one, as one for folders gone does; another cause stands alone")
    func refusedShareRepeatsMerge() throws {
        let planID = UUID()
        func refused(_ minutes: Double, _ volumes: [String] = ["NAS"]) -> RunRecord {
            var run = RunRecord(kind: .backup, planID: planID, planName: "Documents", startedAt: now.addingTimeInterval(minutes * 60))
            run.outcome = .failed
            run.refusedShares = volumes
            run.failureMessage = "“NAS” is not connected. Reconnecting “NAS” failed: the share did not accept the user name and password."
            return run
        }
        let first = refused(0)
        let second = try #require(refused(60).continuingStandingFailure(of: first))
        #expect(second.skipCount == 2)
        #expect(second.skippedSince == first.startedAt)
        #expect(refused(60, ["Photos"]).continuingStandingFailure(of: first) == nil)
        var gone = first
        gone.refusedShares = nil
        gone.missingSources = ["/Users/me/Documents"]
        #expect(refused(60).continuingStandingFailure(of: gone) == nil)
        #expect(gone.continuingStandingFailure(of: first) == nil)
    }

    @Test("a failure for the same folders gone continues the plan's last one; any other failure stands alone")
    func folderGoneRepeatsMerge() throws {
        let planID = UUID()
        func gone(_ minutes: Double, _ sources: [String] = ["/Users/me/Projects"]) -> RunRecord {
            var run = RunRecord(kind: .backup, planID: planID, planName: "Projects", startedAt: now.addingTimeInterval(minutes * 60))
            run.outcome = .failed
            run.missingSources = sources
            run.failureMessage = RunRecord.folderGoneMessage(path: sources[0])
            return run
        }
        let first = gone(0)
        let second = try #require(gone(60).continuingStandingFailure(of: first))
        #expect(second.skipCount == 2)
        #expect(second.skippedSince == first.startedAt)
        let third = try #require(gone(120).continuingStandingFailure(of: second))
        #expect(third.skipCount == 3)
        #expect(third.skippedSince == first.startedAt)

        #expect(gone(60, ["/Users/me/Elsewhere"]).continuingStandingFailure(of: first) == nil)
        var otherFailure = first
        otherFailure.missingSources = nil
        otherFailure.failureMessage = "Fatal: unable to open config file"
        #expect(gone(60).continuingStandingFailure(of: otherFailure) == nil)
        #expect(otherFailure.continuingStandingFailure(of: first) == nil)
        var otherPlan = first
        otherPlan.planID = UUID()
        #expect(gone(60).continuingStandingFailure(of: otherPlan) == nil)

        // Read once, with how long it has stood, as a standing skip is.
        let since = Format.timestamp(first.startedAt)
        #expect(RunRecordPresentation.detail(for: third)
            == "“Projects” is not on this Mac — it was moved, renamed or deleted. Failed 3 times since \(since).")
        let details = RunRecordPresentation.detailsText(
            for: third, repositoryName: "Home NAS", versionsNow: RunLogVersions.current(resticVersion: "")
        )
        #expect(details.contains("Failing since: \(since) (3 times)"))
        #expect(!details.contains("Skipped since"))
        let roundTrip = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(third))
        #expect(roundTrip.missingSources == ["/Users/me/Projects"])
    }

    @Test("a skipped run reads quietly: its own name, no alarm glyph, no numbers")
    func presentation() {
        #expect(RunRecord.Outcome.skipped.displayName == "Skipped")
        #expect(RunRecord.Outcome.skipped.symbolName == "minus.circle")
        var run = RunRecord(kind: .backup, startedAt: now)
        run.outcome = .skipped
        #expect(!RunRecordPresentation.hasBackupNumbers(run))
        // Copy Details says why, where a backup's numbers would be.
        run.detailText = "“Archive SSD” is not connected."
        let details = RunRecordPresentation.detailsText(
            for: run, repositoryName: "Home NAS", versionsNow: RunLogVersions.current(resticVersion: "")
        )
        #expect(details.contains("Skipped: “Archive SSD” is not connected."))
        #expect(!details.contains("Files:"))
        #expect(RunRecordPresentation.detail(for: run) == "“Archive SSD” is not connected.")
    }

    @Test("a path's drive is named by its folder under /Volumes, and is here only while a volume is mounted there")
    func volumePresence() throws {
        #expect(VolumePresence.volumeName(of: "/Volumes/Archive SSD/restic") == "Archive SSD")
        #expect(VolumePresence.volumeName(of: "/Volumes/Archive SSD") == "Archive SSD")
        #expect(VolumePresence.volumeName(of: "/Users/me/restic") == nil)
        #expect(VolumePresence.volumeName(of: "/Volumes") == nil)

        // The startup disk is always here.
        #expect(VolumePresence.isMounted(volumeOf: "/Users/me/restic") == nil)
        #expect(VolumePresence.isMounted(volumeOf: "/Volumes/SwiftRestic Absent Drive/restic") == false)
        // /Volumes also lists the startup disk, as a link to /.
        let startup = try #require(
            FileManager.default.contentsOfDirectory(atPath: "/Volumes").first {
                (try? FileManager.default.destinationOfSymbolicLink(atPath: "/Volumes/\($0)")) == "/"
            }
        )
        #expect(VolumePresence.isMounted(volumeOf: "/Volumes/\(startup)/Users") == true)
        // A folder left behind under /Volumes by a drive that went away
        // uncleanly sits on the startup disk: not a volume.
        #expect(VolumePresence.isVolumeRoot("/"))
        #expect(!VolumePresence.isVolumeRoot(FileManager.default.temporaryDirectory.path))
    }

    @Test("a mounted volume runs again each scheduled plan whose last run was skipped and whose folders are back")
    func catchUpAfterMount() async {
        func plan(_ frequency: Schedule.Frequency = .daily) -> BackupPlan {
            var plan = BackupPlan()
            plan.repositoryID = UUID()
            plan.path = "/Volumes/Archive SSD/Documents"
            plan.schedule.frequency = frequency
            return plan
        }
        let back = plan()
        let stillGone = plan()
        let failedLast = plan()
        let manual = plan(.manual)
        let running = plan()
        let repositoryAway = plan()
        let plans = [back, stillGone, failedLast, manual, running, repositoryAway]
        let newest: [UUID: RunRecord.Outcome] = Dictionary(uniqueKeysWithValues: plans.map {
            ($0.id, $0.id == failedLast.id ? .failed : .skipped)
        })
        let due = await Scheduler.catchUpAfterMount(
            plans: plans,
            newestBackupOutcome: newest,
            running: [running.id],
            sourcesExist: { $0.id != stillGone.id },
            repositoryReachable: { $0.id != repositoryAway.id }
        )
        #expect(due == [back.id])
    }

    @Test("a fix that worked runs again each scheduled plan whose newest backup failed, and nothing else")
    func rerunAfterFix() {
        func plan(_ frequency: Schedule.Frequency = .daily) -> BackupPlan {
            var plan = BackupPlan()
            plan.repositoryID = UUID()
            plan.path = "/Users/me/Documents"
            plan.schedule.frequency = frequency
            return plan
        }
        let failed = plan()
        let skipped = plan()
        let succeeded = plan()
        let neverRan = plan()
        let manual = plan(.manual)
        let running = plan()
        let plans = [failed, skipped, succeeded, neverRan, manual, running]
        let newest: [UUID: RunRecord.Outcome] = [
            failed.id: .failed, skipped.id: .skipped, succeeded.id: .succeeded,
            manual.id: .failed, running.id: .failed,
        ]
        #expect(Scheduler.rerunAfterFix(plans: plans, newestBackupOutcome: newest, running: [running.id]) == [failed.id])
    }

    @Test("a backup an earlier build skipped around an away drive's folders still reads so, and that the rest was backed up")
    @MainActor
    func partlySkippedWords() throws {
        // Recorded by a build whose plans held several folders; the history
        // keeps it.
        var run = RunRecord(kind: .backup, planName: "Documents", startedAt: now)
        run.outcome = .skipped
        run.snapshotID = "6d7f8d20"
        run.filesNew = 2
        run.dataAdded = 120
        run.exitCode = 3
        run.detailText = "“Archive SSD” is not connected; the other folders were backed up."
        #expect(RunRecordPresentation.detail(for: run) == "“Archive SSD” is not connected; the other folders were backed up.")
        let details = RunRecordPresentation.detailsText(
            for: run, repositoryName: "Home NAS", versionsNow: RunLogVersions.current(resticVersion: "")
        )
        #expect(details.contains("Skipped: “Archive SSD” is not connected; the other folders were backed up."))
        #expect(details.contains("Files: 2 new"))
        let log = RunLog.render(
            record: run, repositoryName: "Home NAS", repositoryKind: nil,
            versions: RunLogVersions.current(resticVersion: ""), transcript: RunTranscript.Contents(),
            timeZone: try #require(TimeZone(identifier: "UTC"))
        )
        #expect(log.contains("— Skipped\n“Archive SSD” is not connected; the other folders were backed up."))

        // It wrote a snapshot: a dead-man's switch hears it alive. A skip
        // that wrote none does not.
        var nothing = run
        nothing.snapshotID = nil

        var healthchecks = NotificationChannel()
        healthchecks.url = "https://hc-ping.com/abc-123"
        let alive = AppModel.notificationEvent(for: run, repositoryName: "Home NAS")
        #expect(
            alive.summary
                == "Backup skipped: Documents (Home NAS) — “Archive SSD” is not connected; the other folders were backed up."
        )
        #expect(try #require(NotificationPayload.request(for: healthchecks, event: alive)).url.absoluteString
            == "https://hc-ping.com/abc-123")
        let skipped = AppModel.notificationEvent(for: nothing, repositoryName: "Home NAS")
        #expect(try #require(NotificationPayload.request(for: healthchecks, event: skipped)).url.absoluteString
            == "https://hc-ping.com/abc-123/fail")
    }

    @Test("a skip that continues the plan's last one — same reason — becomes one record that counts the runs")
    func standingSkipMerges() throws {
        let planID = UUID()
        func skip(_ minutes: Double, reason: String = "“Archive SSD” is not connected.") -> RunRecord {
            var run = RunRecord(kind: .backup, planID: planID, planName: "Archive", startedAt: now.addingTimeInterval(minutes * 60))
            run.outcome = .skipped
            run.detailText = reason
            return run
        }
        let first = skip(0)
        let second = try #require(skip(60).continuingSkip(of: first))
        #expect(second.skipCount == 2)
        #expect(second.skippedSince == first.startedAt)
        #expect(second.startedAt == now.addingTimeInterval(3600), "the newest run's own times")
        let third = try #require(skip(120).continuingSkip(of: second))
        #expect(third.skipCount == 3)
        #expect(third.skippedSince == first.startedAt)

        // Anything that makes the earlier record its own news keeps it.
        #expect(skip(60, reason: "“Travel” is not connected.").continuingSkip(of: first) == nil)
        var failed = first
        failed.outcome = .failed
        #expect(skip(60).continuingSkip(of: failed) == nil)
        var otherPlan = first
        otherPlan.planID = UUID()
        #expect(skip(60).continuingSkip(of: otherPlan) == nil)

        // Read once, with how long it has stood.
        let since = Format.timestamp(first.startedAt)
        #expect(RunRecordPresentation.detail(for: third) == "“Archive SSD” is not connected. Skipped 3 times since \(since).")
        let details = RunRecordPresentation.detailsText(
            for: third, repositoryName: "Home NAS", versionsNow: RunLogVersions.current(resticVersion: "")
        )
        #expect(details.contains("Skipped: “Archive SSD” is not connected.\nSkipped since: \(since) (3 times)"))

        // Older records carry neither field.
        let older = try JSONDecoder().decode(RunRecord.self, from: Data(#"{"outcome":"skipped"}"#.utf8))
        #expect(older.skipCount == nil)
        #expect(older.skippedSince == nil)
        let encoder = JSONEncoder()
        let roundTrip = try JSONDecoder().decode(RunRecord.self, from: encoder.encode(third))
        #expect(roundTrip.skipCount == 3)
        #expect(roundTrip.skippedSince == third.skippedSince)
    }

    @Test("a merged skip an earlier build wrote around an away drive keeps its record: its snapshots resolve to it")
    func partialSkipRecordsStand() throws {
        let planID = UUID()
        var stored = RunRecord(kind: .backup, planID: planID, planName: "Archive", startedAt: now.addingTimeInterval(7200))
        stored.outcome = .skipped
        stored.snapshotID = "cccc3333"
        stored.exitCode = ResticError.backupPartialSuccessCode
        stored.detailText = "“Archive SSD” is not connected; the other folders were backed up."
        stored.skipCount = 3
        stored.skippedSince = now
        stored.continuedSnapshotIDs = ["bbbb2222", "aaaa1111"]

        // The earlier backups keep their incomplete mark through the record.
        let bySnapshot = RunRecord.backupRunsBySnapshot([stored])
        #expect(bySnapshot["aaaa1111"]?.id == stored.id)
        #expect(bySnapshot["aaaa1111"]?.snapshotCompleteness == .incomplete)
        #expect(bySnapshot["cccc3333"]?.id == stored.id)
        #expect(RunRecordPresentation.detail(for: stored)
            == "“Archive SSD” is not connected; the other folders were backed up. Skipped 3 times since \(Format.timestamp(now)).")

        // Older records carry no list; a merged one round-trips.
        let older = try JSONDecoder().decode(RunRecord.self, from: Data(#"{"outcome":"skipped"}"#.utf8))
        #expect(older.continuedSnapshotIDs == nil)
        let roundTrip = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(stored))
        #expect(roundTrip.continuedSnapshotIDs == ["bbbb2222", "aaaa1111"])
    }
}
