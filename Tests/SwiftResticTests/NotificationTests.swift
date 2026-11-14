import Foundation
import Testing

@Suite("local notifications")
struct NotificationTests {
    @MainActor
    @Test("the local notification's title is the run's display name")
    func notificationTitleNamesPlanAndRepository() {
        var home = Repository()
        home.localPath = "/Users/someone/Home Disk"
        var documents = BackupPlan()
        documents.repositoryID = home.id
        documents.path = "/Users/someone/Documents"

        func title(for record: RunRecord) -> String {
            AppModel.notificationTitle(for: record, plans: [documents], repositories: [home])
        }

        #expect(
            title(for: RunRecord(kind: .backup, planID: documents.id, planName: "Documents", repositoryID: home.id))
                == "Documents (Home Disk)"
        )
        #expect(title(for: RunRecord(kind: .backup)) == "SwiftRestic")
    }

    @MainActor
    @Test("the local notification body names the fix")
    func notificationBodyNamesTheFix() {
        var record = RunRecord(kind: .backup, planName: "Documents")
        record.outcome = .completedWithErrors
        record.itemErrors = [
            "/Users/u/Library/Mail: open /Users/u/Library/Mail: operation not permitted",
            "/Users/u/locked.txt: open /Users/u/locked.txt: permission denied",
        ]
        record.itemErrorCount = 2
        record.itemErrorTally = ItemErrorDiagnosis.Tally(blockedByMacOS: 1, deniedByFilePermissions: 1)
        record.fullDiskAccessAtRun = .notGranted
        #expect(AppModel.notificationBody(for: record)
            == "Some files skipped: 2 couldn’t be read. macOS blocked 1 item: SwiftRestic needs Full Disk Access.")
    }

    @MainActor
    @Test("the local notification counts restic's unreadable items, never the stored lines")
    func notificationBodyCountsItemErrorCount() {
        // One unreadable item, then the retention line stored after it:
        // restic's count is 1, the stored lines are 2.
        var record = RunRecord(kind: .backup, planName: "Documents")
        record.outcome = .completedWithErrors
        record.itemErrors = ["/a: open /a: permission denied", RunRecord.retentionSkippedPrefix + "locked"]
        record.itemErrorCount = 1
        #expect(AppModel.notificationBody(for: record).hasPrefix("Some files skipped: 1 couldn’t be read."))

        // A retention skip alone is not an unreadable item — not one, not zero.
        var retentionOnly = RunRecord(kind: .backup, planName: "Documents")
        retentionOnly.outcome = .completedWithErrors
        retentionOnly.itemErrors = [RunRecord.retentionSkippedPrefix + "locked"]
        retentionOnly.itemErrorCount = 0
        let body = AppModel.notificationBody(for: retentionOnly)
        #expect(!body.contains("unreadable"), "body was \(body)")
        #expect(body == "Old backups not removed.")
    }

    @MainActor
    @Test("a failed run's notification says the first sentence, not restic's whole tail")
    func failedNotificationBodyIsOneSentence() {
        var record = RunRecord(kind: .backup, planName: "Code")
        record.outcome = .failed
        record.failureMessage = "restic stopped with an error — Fatal: unable to open config file: stat /Volumes/T/config: no such file or directory\nIs there a repository at the following location?"
        #expect(AppModel.notificationBody(for: record)
            == "Failed: restic stopped with an error — Fatal: unable to open config file: stat /Volumes/T/config: no such file or directory")
        record.failureMessage = nil
        #expect(AppModel.notificationBody(for: record) == "Failed.")
    }
}

/// A backup that fails the same way again notifies once: the first of a
/// stretch posts, a repeat stays quiet until a success or another cause
/// re-arms it — a backup skipped whole or stopped passes over it. The menu
/// bar, the caption and Activity still show every run.
@Suite("Repeated problems notify once")
struct RepeatedProblemNotificationTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let planID = UUID()

    private func failed(_ minutes: Double, exit: Int32 = 1, message: String = "Fatal: unable to open config file: Stat: no such file or directory") -> RunRecord {
        var run = RunRecord(kind: .backup, planID: planID, planName: "Documents", startedAt: now.addingTimeInterval(minutes * 60))
        run.outcome = .failed
        run.exitCode = exit
        run.failureMessage = message
        return run
    }

    private func warned(_ minutes: Double, items: [String] = ["/a: open /a: permission denied"]) -> RunRecord {
        var run = RunRecord(kind: .backup, planID: planID, planName: "Documents", startedAt: now.addingTimeInterval(minutes * 60))
        run.outcome = .completedWithErrors
        run.exitCode = 3
        run.itemErrors = items
        run.itemErrorCount = items.count
        return run
    }

    private func ended(_ minutes: Double, _ outcome: RunRecord.Outcome, plan: UUID? = nil) -> RunRecord {
        var run = RunRecord(kind: .backup, planID: plan ?? planID, planName: "Documents", startedAt: now.addingTimeInterval(minutes * 60))
        run.outcome = outcome
        return run
    }

    @MainActor
    private func makeModel(keepingRuns limit: Int? = nil) -> AppModel {
        let suite = "SwiftResticRepeatedProblemTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel(
            store: ConfigStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("SwiftResticRepeated-\(UUID().uuidString)")),
            secrets: .inMemory(),
            defaults: defaults
        )
        if let limit { model.activityHistoryLimit = limit }
        return model
    }

    @MainActor
    private func stored(_ run: RunRecord, in model: AppModel) -> RunRecord? {
        model.configuration.runs.first { $0.id == run.id }
    }

    @Test("the same outcome for the same cause is the same problem; anything else is news")
    func sameCause() {
        #expect(failed(60).isSameProblem(as: failed(0)))
        #expect(!failed(60, exit: 11).isSameProblem(as: failed(0)))
        #expect(!failed(60, message: "Fatal: wrong password or no key found").isSameProblem(as: failed(0)))
        // Numbers in restic's words change from run to run: a lock's PID and age.
        #expect(failed(60, exit: 11, message: "Fatal: unable to create lock in backend: repository is already locked by PID 4242 on nas by u (UID 501, GID 20)")
            .isSameProblem(as: failed(0, exit: 11, message: "Fatal: unable to create lock in backend: repository is already locked by PID 517 on nas by u (UID 501, GID 20)")))
        #expect(warned(60).isSameProblem(as: warned(0)))
        #expect(!warned(60, items: ["/b: open /b: permission denied"]).isSameProblem(as: warned(0)))
        #expect(!warned(60).isSameProblem(as: failed(0)))
        #expect(!failed(60).isSameProblem(as: ended(0, .succeeded)))
        #expect(!ended(60, .succeeded).isSameProblem(as: ended(0, .succeeded)))
        // Folders gone from this Mac, by their paths: the message names only
        // each one's last component, and loses its digits.
        func gone(_ path: String) -> RunRecord {
            var run = failed(0, message: RunRecord.folderGoneMessage(path: path))
            run.missingSources = [path]
            return run
        }
        #expect(!gone("/Users/me/Photos 2024").isSameProblem(as: gone("/Users/me/Photos 2023")))
        #expect(!gone("/Users/me/New/Photos").isSameProblem(as: gone("/Users/me/Old/Photos")))
        #expect(gone("/Users/me/Photos 2023").isSameProblem(as: gone("/Users/me/Photos 2023")))
        // Shares that refused, by their volumes: the message names them, and
        // would lose its digits.
        func refused(_ volume: String) -> RunRecord {
            var run = failed(0, message: "“\(volume)” is not connected. Reconnecting “\(volume)” failed: the share did not accept the user name and password.")
            run.refusedShares = [volume]
            return run
        }
        #expect(!refused("Photos 2024").isSameProblem(as: refused("Photos 2023")))
        #expect(refused("NAS").isSameProblem(as: refused("NAS")))
        // A warning's other lines with their numbers aside; its unreadable
        // items exactly — two files are two problems.
        var gap = warned(60)
        gap.itemErrors.append("3 restic messages could not be decoded — a restic update may have changed its output; the run’s numbers may be incomplete.")
        var gapBefore = warned(0)
        gapBefore.itemErrors.append("5 restic messages could not be decoded — a restic update may have changed its output; the run’s numbers may be incomplete.")
        #expect(gap.isSameProblem(as: gapBefore))
        var retentionSkipped = warned(60)
        retentionSkipped.itemErrors.append(RunRecord.retentionSkippedPrefix + "repository is already locked by PID 4242")
        #expect(!retentionSkipped.isSameProblem(as: warned(0)),
                "the same unreadable items with old backups not removed this time read as the same problem")
        #expect(!warned(60, items: ["/a/IMG_0002.jpg: open /a/IMG_0002.jpg: permission denied"])
            .isSameProblem(as: warned(0, items: ["/a/IMG_0001.jpg: open /a/IMG_0001.jpg: permission denied"])))
        // A merged repeat (a standing failure for the same folders gone)
        // counts the runs it stands for, and continues its predecessor's.
        var standing = failed(60)
        standing.skipCount = 3
        #expect(standing.stretchFollowing(nil) == 3)
        var before = failed(0)
        before.problemStretch = 2
        #expect(standing.stretchFollowing(before) == 5)
        #expect(ended(60, .succeeded).stretchFollowing(before) == nil)
    }

    @Test("a stretch counts the plan's backups in a row that ended the same way; a skip or a stop passes over it")
    func stretch() {
        func counts(_ newestFirst: [RunRecord]) -> [Int?] {
            RunRecord.fillingProblemStretches(newestFirst).map(\.problemStretch)
        }
        #expect(counts([warned(600), warned(540), warned(480), ended(420, .succeeded), warned(360), warned(300)])
            == [3, 2, 1, nil, 2, 1])
        // A backup skipped whole or stopped ran nothing: the stretch goes on.
        #expect(counts([warned(600), ended(540, .skipped), warned(480)]) == [2, nil, 1])
        #expect(counts([warned(600), ended(540, .cancelled), warned(480)]) == [2, nil, 1])
        #expect(counts([warned(600, items: ["/b: open /b: permission denied"]), warned(540)]) == [1, 1])
        #expect(counts([failed(600), warned(540)]) == [1, 1])
        // Another plan's runs neither end it nor add to it.
        #expect(counts([warned(600), ended(570, .succeeded, plan: UUID()), warned(560, items: ["/z"]).withPlan(UUID()), warned(540)])
            == [2, nil, 1, 1])
        // A failure merged into a standing one counts the runs it stands for,
        // on top of an earlier failure for the same cause it did not merge
        // into.
        var merged = failed(600)
        merged.skipCount = 3
        #expect(counts([merged, failed(300), failed(200)]) == [5, 2, 1])
        // A stored stretch stands — the backups it counted may be trimmed
        // since — and the next one continues it.
        var kept = warned(300)
        kept.problemStretch = 7
        #expect(counts([warned(600), kept]) == [8, 7])
    }

    @MainActor
    @Test("a success stays quiet, and a problem notifies only the first time in a stretch")
    func wantsNotification() {
        let model = makeModel()
        let first = failed(0)
        model.append(record: first)
        #expect(model.wantsNotification(for: first))
        let again = failed(60)
        model.append(record: again)
        #expect(!model.wantsNotification(for: again))

        // A backup skipped whole, or stopped, between two runs of the same
        // problem leaves it standing: still one notification.
        model.append(record: ended(90, .skipped))
        let afterSkip = failed(100)
        model.append(record: afterSkip)
        #expect(!model.wantsNotification(for: afterSkip))
        model.append(record: ended(105, .cancelled))
        let afterStop = failed(110)
        model.append(record: afterStop)
        #expect(!model.wantsNotification(for: afterStop))
        #expect(stored(afterStop, in: model)?.problemStretch == 4)

        var success = failed(120)
        success.outcome = .succeeded
        success.failureMessage = nil
        model.append(record: success)
        #expect(!model.wantsNotification(for: success), "a success that is not a plan's first stays quiet")
        let afterSuccess = failed(180)
        model.append(record: afterSuccess)
        #expect(model.wantsNotification(for: afterSuccess))

        // A run merged into a standing failure for the same folders gone:
        // the run it continued is gone from the history, its count is not.
        func gone(_ minutes: Double) -> RunRecord {
            var run = failed(minutes, message: RunRecord.folderGoneMessage(path: "/Users/me/Projects"))
            run.missingSources = ["/Users/me/Projects"]
            return run
        }
        let goneFirst = gone(240)
        model.append(record: goneFirst)
        #expect(model.wantsNotification(for: goneFirst))
        let goneAgain = gone(300)
        model.append(record: goneAgain)
        #expect(model.configuration.runs.first?.skipCount == 2)
        #expect(stored(goneAgain, in: model)?.problemStretch == 2)
        #expect(!model.wantsNotification(for: goneAgain))
    }

    @MainActor
    @Test("the history cap trims what a stretch counted, never the count")
    func capKeepsTheCount() {
        let other = UUID()
        // The cap's floor, 20: another plan's backups push this plan's
        // earlier warnings out; the newest, standing, is kept.
        let model = makeModel(keepingRuns: 20)
        for minute in [0.0, 60, 120] { model.append(record: warned(minute)) }
        for minute in 0 ..< 25 { model.append(record: ended(130 + Double(minute), .succeeded, plan: other)) }
        #expect(model.configuration.runs.count { $0.planID == planID } == 1)
        let fourth = warned(200)
        model.append(record: fourth)
        #expect(stored(fourth, in: model)?.problemStretch == 4)
        #expect(!model.wantsNotification(for: fourth))

        // The warning before is trimmed by this very append: the count was
        // taken first, so the notification stays quiet.
        let edge = makeModel(keepingRuns: 20)
        edge.append(record: warned(0))
        for minute in 0 ..< 19 { edge.append(record: ended(10 + Double(minute), .succeeded, plan: other)) }
        let second = warned(100)
        edge.append(record: second)
        #expect(edge.configuration.runs.count { $0.planID == planID } == 1)
        #expect(stored(second, in: edge)?.problemStretch == 2)
        #expect(!edge.wantsNotification(for: second))

        // A success trimmed with the warning before it ends the stretch all
        // the same: the warning, healed, goes first.
        let healed = makeModel(keepingRuns: 20)
        healed.append(record: warned(0))
        healed.append(record: ended(10, .succeeded))
        for minute in 0 ..< 30 { healed.append(record: ended(20 + Double(minute), .succeeded, plan: other)) }
        #expect(healed.configuration.runs.count { $0.planID == planID } == 0)
        let after = warned(100)
        healed.append(record: after)
        #expect(stored(after, in: healed)?.problemStretch == 1)
        #expect(healed.wantsNotification(for: after))
    }
}

private extension RunRecord {
    func withPlan(_ id: UUID) -> RunRecord {
        var run = self
        run.planID = id
        return run
    }
}

/// Where a clicked notification's identifier sends the click — the routing
/// `AppDelegate.openNotification` reads (`NotificationRoute`, written
/// beside the identifiers' writers).
@Suite("notification routes")
struct NotificationRouteTests {
    @Test("a quiet-plan identifier routes to its plan, a run's to the run, anything else nowhere")
    func routing() {
        let planID = UUID()
        #expect(
            NotificationRoute.route(forIdentifier: AppModel.quietPlanNotificationPrefix + planID.uuidString)
                == .plan(planID)
        )
        let runID = UUID()
        #expect(NotificationRoute.route(forIdentifier: runID.uuidString) == .run(runID))
        // The prefix over something that is not a plan ID is not a run's
        // identifier either: it routes nowhere, opening no window.
        #expect(NotificationRoute.route(forIdentifier: AppModel.quietPlanNotificationPrefix + "not-a-uuid") == nil)
        #expect(NotificationRoute.route(forIdentifier: "restic note") == nil)
    }

    @Test("every route's identifier reads back as that route")
    func identifierRoundTrip() {
        for route in [NotificationRoute.plan(UUID()), .run(UUID())] {
            #expect(NotificationRoute.route(forIdentifier: route.identifier) == route)
        }
    }
}
