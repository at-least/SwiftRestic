import Foundation
import Testing

/// A backup whose every folder is missing — a drive not plugged in — is
/// recorded as skipped: its reason names the drive, it carries no numbers,
/// and when a volume comes back the plan runs again without waiting for
/// its next slot. Online-only cloud files are left out by new plans, with
/// a restic that can.
@Suite("Skipped runs and cloud files")
struct SkippedRunTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("the reason names the drive when every folder is on one, else says the folders are gone")
    func skippedReason() {
        #expect(RunRecord.skippedReason(sources: ["/Volumes/Archive SSD/Documents", "/Volumes/Archive SSD/Photos"])
            == "“Archive SSD” is not connected.")
        #expect(RunRecord.skippedReason(sources: ["/Volumes/Archive SSD/Documents", "/Volumes/Travel/Code"])
            == "“Archive SSD” and “Travel” are not connected.")
        #expect(RunRecord.skippedReason(sources: ["/Volumes/Archive SSD", "/Users/me/gone"])
            == "None of its folders are on this Mac.")
        #expect(RunRecord.skippedReason(sources: ["/Users/me/gone"]) == "None of its folders are on this Mac.")
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
        // The reason leads Activity's Detail even when an after-any hook
        // complained.
        run.hookMessages = ["“unmount” exited with 1"]
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
    func catchUpAfterMount() {
        func plan(_ frequency: Schedule.Frequency = .daily) -> BackupPlan {
            var plan = BackupPlan()
            plan.name = "Archive"
            plan.repositoryID = UUID()
            plan.sources = ["/Volumes/Archive SSD/Documents"]
            plan.schedule.frequency = frequency
            return plan
        }
        let back = plan()
        let stillGone = plan()
        let failedLast = plan()
        let manual = plan(.manual)
        var paused = plan()
        paused.isEnabled = false
        let running = plan()
        let repositoryAway = plan()
        let plans = [back, stillGone, failedLast, manual, paused, running, repositoryAway]
        let newest: [UUID: RunRecord.Outcome] = Dictionary(uniqueKeysWithValues: plans.map {
            ($0.id, $0.id == failedLast.id ? .failed : .skipped)
        })
        let due = Scheduler.catchUpAfterMount(
            plans: plans,
            newestBackupOutcome: newest,
            running: [running.id],
            sourcesExist: { $0.id != stillGone.id },
            repositoryReachable: { $0.id != repositoryAway.id },
            now: now
        )
        #expect(due == [back.id])
    }

    @Test("sources restic skipped are set aside only when each is on a drive that is away and nothing else went unread")
    func awaySourcesSetAside() {
        let photos = "/Volumes/Archive SSD/Photos does not exist, skipping"
        let music = "/Volumes/Archive SSD/Music cannot be accessed, skipping"
        func outcome(_ lines: [String]) -> BackupOutcome {
            var outcome = BackupOutcome(summary: nil, itemErrors: lines, exitCode: 3)
            for line in lines {
                outcome.itemPaths[line] = line.components(separatedBy: " does not exist").first?
                    .components(separatedBy: " cannot be accessed").first
            }
            return outcome
        }
        let away: (String) -> Bool = { $0.hasPrefix("/Volumes/Archive SSD/") }

        var both = outcome([photos, music])
        #expect(both.setAsideAwaySources(isAway: away) == ["/Volumes/Archive SSD/Photos", "/Volumes/Archive SSD/Music"])
        #expect(both.itemErrors.isEmpty)
        #expect(both.itemPaths.isEmpty)

        // Anything else unread keeps every line an unreadable item.
        var mixed = outcome([photos, "/Users/me/Mail: permission denied"])
        mixed.itemPaths["/Users/me/Mail: permission denied"] = "/Users/me/Mail"
        #expect(mixed.setAsideAwaySources(isAway: away).isEmpty)
        #expect(mixed.itemErrors.count == 2)
        // A skipped folder whose drive is here is gone or blocked: unreadable.
        var here = outcome([photos])
        #expect(here.setAsideAwaySources(isAway: { _ in false }).isEmpty)
        #expect(here.itemErrors == [photos])
        // A reporting gap is not explained by a drive.
        var gap = outcome([photos])
        gap.decodingWarning = "1 restic message could not be read"
        #expect(gap.setAsideAwaySources(isAway: away).isEmpty)
        #expect(gap.itemErrors == [photos])
    }

    @Test("a backup that skipped only an away drive's folders says so, and that the rest was backed up")
    @MainActor
    func partlySkippedWords() throws {
        #expect(RunRecord.partlySkippedReason(sources: ["/Volumes/Archive SSD/Photos"])
            == "“Archive SSD” is not connected; the other folders were backed up.")

        var run = RunRecord(kind: .backup, planName: "Documents", startedAt: now)
        run.outcome = .skipped
        run.snapshotID = "6d7f8d20"
        run.filesNew = 2
        run.dataAdded = 120
        run.exitCode = 3
        run.detailText = RunRecord.partlySkippedReason(sources: ["/Volumes/Archive SSD/Photos"])
        #expect(RunRecordPresentation.detail(for: run) == "“Archive SSD” is not connected; the other folders were backed up.")
        // Copy Details carries the reason and the numbers.
        let details = RunRecordPresentation.detailsText(
            for: run, repositoryName: "Home NAS", versionsNow: RunLogVersions.current(resticVersion: "")
        )
        #expect(details.contains("Skipped: “Archive SSD” is not connected; the other folders were backed up."))
        #expect(details.contains("Files: 2 new"))
        // So does the run's log.
        let log = RunLog.render(
            record: run, repositoryName: "Home NAS", repositoryKind: nil,
            versions: RunLogVersions.current(resticVersion: ""), transcript: RunTranscript.Contents(),
            timeZone: try #require(TimeZone(identifier: "UTC"))
        )
        #expect(log.contains("— Skipped\n“Archive SSD” is not connected; the other folders were backed up."))

        // It wrote a snapshot: a backup went through, so it heals an older
        // failure and a dead-man's switch hears it alive. A skip that wrote
        // none does neither.
        var failure = RunRecord(kind: .backup, planID: UUID(), planName: "Documents", startedAt: now.addingTimeInterval(-3600))
        failure.outcome = .failed
        run.planID = failure.planID
        #expect(OverviewMetrics.isHealed(failure, in: [run, failure]))
        var nothing = run
        nothing.snapshotID = nil
        #expect(!OverviewMetrics.isHealed(failure, in: [nothing, failure]))

        var healthchecks = NotificationChannel()
        healthchecks.kind = .healthchecks
        healthchecks.url = "https://hc-ping.com/abc-123"
        let alive = AppModel.notificationEvent(for: run, repositoryName: "Home NAS")
        #expect(try #require(NotificationPayload.request(for: healthchecks, event: alive)).url.absoluteString
            == "https://hc-ping.com/abc-123")
        let skipped = AppModel.notificationEvent(for: nothing, repositoryName: "Home NAS")
        #expect(try #require(NotificationPayload.request(for: healthchecks, event: skipped)).url.absoluteString
            == "https://hc-ping.com/abc-123/fail")
    }

    @Test("a skip that continues the plan's last one — same reason, nothing written — becomes one record that counts the runs")
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
        var wrote = first
        wrote.snapshotID = "b824a66c"
        #expect(skip(60).continuingSkip(of: wrote) == nil)
        var complained = first
        complained.hookMessages = ["“eject” exited with 1"]
        #expect(skip(60).continuingSkip(of: complained) == nil)
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
        #expect(details.contains("Skipped: “Archive SSD” is not connected.\nSkipped since: \(since) (3 runs)"))

        // Older records carry neither field.
        let older = try JSONDecoder().decode(RunRecord.self, from: Data(#"{"outcome":"skipped"}"#.utf8))
        #expect(older.skipCount == nil)
        #expect(older.skippedSince == nil)
        let encoder = JSONEncoder()
        let roundTrip = try JSONDecoder().decode(RunRecord.self, from: encoder.encode(third))
        #expect(roundTrip.skipCount == 3)
        #expect(roundTrip.skippedSince == third.skippedSince)
    }

    @Test("a backup around an away drive continues the plan's last such one, and the earlier snapshots still resolve to the record")
    func partialSkipMerges() throws {
        let planID = UUID()
        func partial(_ minutes: Double, snapshot: String) -> RunRecord {
            var run = RunRecord(kind: .backup, planID: planID, planName: "Archive", startedAt: now.addingTimeInterval(minutes * 60))
            run.outcome = .skipped
            run.snapshotID = snapshot
            run.exitCode = ResticError.backupPartialSuccessCode
            run.detailText = "“Archive SSD” is not connected; the other folders were backed up."
            return run
        }
        let first = partial(0, snapshot: "aaaa1111")
        let second = try #require(partial(60, snapshot: "bbbb2222").continuingSkip(of: first))
        #expect(second.skipCount == 2)
        #expect(second.skippedSince == first.startedAt)
        #expect(second.snapshotID == "bbbb2222", "the newest run's own snapshot")
        #expect(second.continuedSnapshotIDs == ["aaaa1111"])
        let third = try #require(partial(120, snapshot: "cccc3333").continuingSkip(of: second))
        #expect(third.continuedSnapshotIDs == ["bbbb2222", "aaaa1111"])
        // The earlier backups keep their incomplete mark through the record.
        let bySnapshot = RunRecord.backupRunsBySnapshot([third])
        #expect(bySnapshot["aaaa1111"]?.id == third.id)
        #expect(bySnapshot["aaaa1111"]?.snapshotCompleteness == .incomplete)
        #expect(bySnapshot["cccc3333"]?.id == third.id)
        #expect(RunRecordPresentation.detail(for: third)
            == "“Archive SSD” is not connected; the other folders were backed up. Skipped 3 times since \(Format.timestamp(first.startedAt)).")

        // A whole skip after a partial one is its own news, and so is a
        // retention line.
        var whole = partial(60, snapshot: "dddd4444")
        whole.snapshotID = nil
        #expect(whole.continuingSkip(of: first) == nil)
        var retentionSkipped = partial(60, snapshot: "eeee5555")
        retentionSkipped.itemErrors = [RunRecord.retentionSkippedPrefix + "repository is already locked"]
        #expect(retentionSkipped.continuingSkip(of: first) == nil)

        // Older records carry no list; a merged one round-trips.
        let older = try JSONDecoder().decode(RunRecord.self, from: Data(#"{"outcome":"skipped"}"#.utf8))
        #expect(older.continuedSnapshotIDs == nil)
        let roundTrip = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(third))
        #expect(roundTrip.continuedSnapshotIDs == ["bbbb2222", "aaaa1111"])
    }

    @Test("new plans leave online-only cloud files out; a plan saved before the option keeps backing them up")
    func cloudFilesDefault() throws {
        #expect(BackupPlan().excludeCloudFiles)
        let older = try JSONDecoder().decode(BackupPlan.self, from: Data(#"{"name":"Old"}"#.utf8))
        #expect(!older.excludeCloudFiles)
        // restic 0.18 had the flag for Windows only; 0.19 brought it to macOS.
        #expect(ResticVersion(parsing: "restic 0.19.0 compiled with go1.24 on darwin/arm64")?.excludesCloudFilesOnMac == true)
        #expect(ResticVersion(parsing: "restic 0.18.1 compiled with go1.24 on darwin/arm64")?.excludesCloudFilesOnMac == false)
    }
}
