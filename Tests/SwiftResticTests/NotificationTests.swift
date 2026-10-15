import Foundation
import Testing

@Suite("Notification payloads")
struct NotificationTests {
    private func channel(_ kind: NotificationChannel.Kind, url: String) -> NotificationChannel {
        var channel = NotificationChannel()
        channel.name = "Test"
        channel.kind = kind
        channel.url = url
        return channel
    }

    private func event(_ stage: NotificationEvent.Stage) -> NotificationEvent {
        NotificationEvent(
            stage: stage,
            planName: "Documents",
            repositoryName: "NAS",
            snapshotID: "abc12345",
            errorMessage: stage == .failed ? "repository is locked" : nil,
            warnings: stage == .warned ? ["/etc/x: permission denied"] : [],
            filesNew: 3,
            bytesProcessed: 2048,
            dataAdded: 1024,
            duration: 30
        )
    }

    @Test("healthchecks uses the bare URL, /start and /fail — and nothing else")
    func healthchecksProtocol() throws {
        // These three endpoints are the whole protocol; getting them wrong turns
        // the dead-man's switch into something that never fires.
        let channel = channel(.healthchecks, url: "https://hc-ping.com/abc-123")

        let start = try #require(NotificationPayload.request(for: channel, event: event(.started)))
        #expect(start.url.absoluteString == "https://hc-ping.com/abc-123/start")

        let success = try #require(NotificationPayload.request(for: channel, event: event(.succeeded)))
        #expect(success.url.absoluteString == "https://hc-ping.com/abc-123")

        let failed = try #require(NotificationPayload.request(for: channel, event: event(.failed)))
        #expect(failed.url.absoluteString == "https://hc-ping.com/abc-123/fail")

        // A run with warnings still completed, so it must ping success rather
        // than raising the alarm.
        let warned = try #require(NotificationPayload.request(for: channel, event: event(.warned)))
        #expect(warned.url.absoluteString == "https://hc-ping.com/abc-123")

        #expect(success.bodyString?.contains("Documents") == true)
        #expect(success.contentType?.hasPrefix("text/plain") == true)
    }

    @Test("slack and discord each use their own field name")
    func chatPayloads() throws {
        let slack = try #require(NotificationPayload.request(
            for: channel(.slack, url: "https://hooks.slack.com/services/x"),
            event: event(.failed)
        ))
        let slackData = try #require(slack.body)
        let slackBody = try JSONSerialization.jsonObject(with: slackData) as? [String: Any]
        #expect(slackBody?["text"] as? String != nil)
        #expect((slackBody?["text"] as? String)?.contains("FAILED") == true)

        let discord = try #require(NotificationPayload.request(
            for: channel(.discord, url: "https://discord.com/api/webhooks/x"),
            event: event(.failed)
        ))
        let discordData = try #require(discord.body)
        let discordBody = try JSONSerialization.jsonObject(with: discordData) as? [String: Any]
        #expect(discordBody?["content"] as? String != nil)
        #expect(discordBody?["text"] == nil)
    }

    @Test("the generic webhook carries the structured event")
    func webhookPayload() throws {
        let request = try #require(NotificationPayload.request(
            for: channel(.webhook, url: "https://example.com/hook"),
            event: event(.warned)
        ))
        let data = try #require(request.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["stage"] as? String == "warned")
        #expect(body["plan"] as? String == "Documents")
        #expect(body["repository"] as? String == "NAS")
        #expect(body["snapshot_id"] as? String == "abc12345")
        #expect(body["data_added"] as? Int64 == 1024)
        #expect((body["warnings"] as? [String])?.count == 1)
        // Absent rather than null, so a consumer can test for presence.
        #expect(body["error"] == nil)
        #expect(request.contentType == "application/json")
    }

    @Test("a channel with no usable URL produces no request")
    func rejectsUnusableChannels() {
        #expect(NotificationPayload.request(
            for: channel(.slack, url: ""),
            event: event(.succeeded)
        ) == nil)
        // Not http(s): nothing should be posted to a file or custom scheme.
        #expect(NotificationPayload.request(
            for: channel(.webhook, url: "file:///etc/passwd"),
            event: event(.succeeded)
        ) == nil)

        var disabled = channel(.webhook, url: "https://example.com")
        disabled.isEnabled = false
        #expect(NotificationPayload.request(for: disabled, event: event(.succeeded)) == nil)
    }

    @Test("per-stage opt-outs are respected, and only healthchecks wants a start ping")
    func stageFiltering() {
        var quiet = channel(.slack, url: "https://hooks.slack.com/x")
        quiet.notifyOnSuccess = false
        #expect(!quiet.wants(.succeeded))
        #expect(quiet.wants(.failed))
        // A "backup started" chat message is noise; a Healthchecks start ping is
        // load-bearing.
        #expect(!quiet.wants(.started))
        #expect(channel(.healthchecks, url: "https://hc-ping.com/x").wants(.started))
    }

    @Test("the summary line names the plan and what happened")
    func summaries() {
        #expect(event(.succeeded).summary.contains("Documents"))
        #expect(event(.succeeded).summary.contains("succeeded"))
        #expect(event(.failed).summary.contains("repository is locked"))
        #expect(event(.warned).summary.contains("1 warning"))
        #expect(event(.started).summary.contains("started"))
    }

    @Test("the summary's subject names the plan with its repository, and never says a repository twice")
    func summarySubjectNamesTheRepository() {
        // The app's one run-naming rule: a chat line about "Documents" says
        // which Documents.
        #expect(event(.succeeded).summary.contains("Documents (NAS)"))
        // A check or prune reports the repository in planName as well; the
        // rule's same-name guard leaves it said once. (The hand-built event
        // keeps the struct's "Backup" default for `operation`, which is not
        // what is being pinned here.)
        let check = NotificationEvent(stage: .failed, planName: "NAS", repositoryName: "NAS", errorMessage: "locked")
        #expect(check.summary == "Backup FAILED: NAS — locked", "summary was \(check.summary)")
        #expect(!check.summary.contains("NAS (NAS)"))
        // An event with no plan names the repository alone.
        let bare = NotificationEvent(stage: .failed, planName: "", repositoryName: "NAS", errorMessage: "locked")
        #expect(bare.summary == "Backup FAILED: NAS — locked", "summary was \(bare.summary)")
    }

    @MainActor
    @Test("the local notification's title is the run's display name")
    func notificationTitleNamesPlanAndRepository() {
        var home = Repository()
        home.name = "Home Disk"
        var documents = BackupPlan()
        documents.name = "Documents"
        documents.repositoryID = home.id

        func title(for record: RunRecord) -> String {
            AppModel.notificationTitle(for: record, plans: [documents], repositories: [home])
        }

        #expect(
            title(for: RunRecord(kind: .backup, planID: documents.id, planName: "Documents", repositoryID: home.id))
                == "Documents (Home Disk)"
        )
        // A record that names nothing falls back to the app's name.
        #expect(title(for: RunRecord(kind: .backup)) == "SwiftRestic")
    }

    @MainActor
    @Test("a warned run's hint reaches chat summaries and the webhook")
    func hintReachesChannels() throws {
        let hint = "macOS blocked 1 item: SwiftRestic needs Full Disk Access."
        let warned = NotificationEvent(
            stage: .warned,
            planName: "Documents",
            repositoryName: "NAS",
            warnings: ["/Users/u/Library/Mail: open /Users/u/Library/Mail: operation not permitted"],
            hint: hint
        )
        #expect(warned.summary.contains(hint), "summary was: \(warned.summary)")

        let slack = try #require(NotificationPayload.request(for: channel(.slack, url: "https://hooks.slack.com/x"), event: warned))
        let slackData = try #require(slack.body)
        let slackBody = try #require(JSONSerialization.jsonObject(with: slackData) as? [String: Any])
        #expect((slackBody["text"] as? String)?.contains(hint) == true)

        let webhook = try #require(NotificationPayload.request(for: channel(.webhook, url: "https://example.com/hook"), event: warned))
        let webhookData = try #require(webhook.body)
        let webhookBody = try #require(JSONSerialization.jsonObject(with: webhookData) as? [String: Any])
        #expect(webhookBody["hint"] as? String == hint)
        // Absent rather than null when there is nothing to say.
        let plain = try #require(NotificationPayload.request(for: channel(.webhook, url: "https://example.com/hook"), event: event(.warned)))
        let plainData = try #require(plain.body)
        let plainBody = try #require(JSONSerialization.jsonObject(with: plainData) as? [String: Any])
        #expect(plainBody["hint"] == nil)

        var record = RunRecord(kind: .backup, planName: "Documents")
        record.outcome = .completedWithErrors
        record.itemErrors = ["/Users/u/Library/Mail: open /Users/u/Library/Mail: operation not permitted"]
        record.itemErrorCount = 1
        record.itemErrorTally = ItemErrorDiagnosis.Tally(blockedByMacOS: 1, deniedByFilePermissions: 0)
        record.fullDiskAccessAtRun = .notGranted
        let event = AppModel.notificationEvent(for: record, repositoryName: "NAS")
        #expect(event.hint?.contains("Full Disk Access") == true, "hint was \(event.hint ?? "nil")")
        record.fullDiskAccessAtRun = .granted
        #expect(AppModel.notificationEvent(for: record, repositoryName: "NAS").hint
            == "macOS blocked 1 item even with Full Disk Access on.")
        // A run with nothing to diagnose sends no hint.
        #expect(AppModel.notificationEvent(for: RunRecord(kind: .backup, planName: "Documents"), repositoryName: "NAS").hint == nil)
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
            == "Finished with 2 unreadable items. macOS blocked 1 item: SwiftRestic needs Full Disk Access.")
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
        #expect(AppModel.notificationBody(for: record).hasPrefix("Finished with 1 unreadable item."))

        // A retention skip alone is not an unreadable item — not one, not zero.
        var retentionOnly = RunRecord(kind: .backup, planName: "Documents")
        retentionOnly.outcome = .completedWithErrors
        retentionOnly.itemErrors = [RunRecord.retentionSkippedPrefix + "locked"]
        retentionOnly.itemErrorCount = 0
        let body = AppModel.notificationBody(for: retentionOnly)
        #expect(!body.contains("unreadable"), "body was \(body)")
        #expect(body == "Finished with warnings: Retention skipped.")
    }

    @MainActor
    @Test("a failed run's notification says the first sentence, not restic's whole tail")
    func failedNotificationBodyIsOneSentence() {
        var record = RunRecord(kind: .backup, planName: "Code")
        record.outcome = .failed
        record.failureMessage = "restic reported a fatal error — Fatal: unable to open config file: stat /Volumes/T/config: no such file or directory\nIs there a repository at the following location?"
        #expect(AppModel.notificationBody(for: record)
            == "restic reported a fatal error — Fatal: unable to open config file: stat /Volumes/T/config: no such file or directory")
        record.failureMessage = nil
        #expect(AppModel.notificationBody(for: record) == "The backup failed.")
    }
}

@Suite("Notification safety")
struct NotificationSafetyTests {
    @Test("a cancelled run trips a dead-man's switch but stays out of chat")
    func cancelledRunPingsFailOnly() throws {
        // Cancelling is a backup that did not happen. Healthchecks has to hear
        // about it or a Mac shut down mid-backup looks like a healthy one; a
        // Slack channel does not, because the person who cancelled already knows.
        var healthchecks = NotificationChannel()
        healthchecks.kind = .healthchecks
        healthchecks.url = "https://hc-ping.com/abc-123"
        var slack = NotificationChannel()
        slack.kind = .slack
        slack.url = "https://hooks.slack.com/services/x"

        #expect(healthchecks.wants(.cancelled))
        #expect(!slack.wants(.cancelled))

        let event = NotificationEvent(stage: .cancelled, planName: "Docs", repositoryName: "NAS")
        let request = try #require(NotificationPayload.request(for: healthchecks, event: event))
        #expect(request.url.absoluteString == "https://hc-ping.com/abc-123/fail")
    }

    @Test("the webhook payload carries only what the event holds")
    func webhookCarriesOnlyTheEvent() throws {
        // Payload-level half of the hook-privacy guarantee: whatever the event
        // does not hold cannot reach the wire. The other half — that AppModel
        // builds run events from `itemErrors` alone, never `hookMessages` — is
        // pinned end to end by AppModelStubTests' broadcast test.
        var record = RunRecord(kind: .backup, planName: "Docs")
        record.itemErrors = ["/etc/secrets: permission denied"]
        record.hookMessages = ["Hook “upload” exited 1 — Authorization: Bearer sk-live-abcdef"]

        let event = NotificationEvent(
            stage: .warned,
            planName: record.planName,
            repositoryName: "NAS",
            warnings: Array(record.itemErrors.prefix(5))
        )
        var webhook = NotificationChannel()
        webhook.kind = .webhook
        webhook.url = "https://example.com/hook"

        let request = try #require(NotificationPayload.request(for: webhook, event: event))
        let body = try #require(request.bodyString)
        #expect(body.contains("permission denied"))
        #expect(!body.contains("Bearer"))
        #expect(!body.contains("upload"))
    }

    @Test("a failing hook's summary keeps only its first line")
    func hookSummaryIsTruncated() {
        // Later lines are where a verbose HTTP client prints headers, and this
        // string is written to config.json.
        let outcome = HookRunner.Outcome(
            hookName: "upload",
            exitCode: 4,
            output: "connecting…\nAuthorization: Bearer sk-live-abcdef\ndone",
            timedOut: false
        )
        #expect(outcome.summary.contains("exited 4"))
        #expect(outcome.summary.contains("connecting"))
        #expect(!outcome.summary.contains("Bearer"))
    }
}

/// The chat-facing summary must count every warning restic reported, not the
/// five-item sample the event carries for excerpts.
@Suite("warning counts")
struct WarningCountTests {
    @Test("the warned summary counts all warnings, with or without an explicit count")
    func warnedSummaryCountsAll() {
        var event = NotificationEvent(
            stage: .warned,
            planName: "Documents",
            repositoryName: "NAS"
        )
        event.warnings = ["warning 1", "warning 2", "warning 3", "warning 4", "warning 5"]
        event.warningCount = 500
        #expect(event.summary.contains("500 warnings"), "summary was: \(event.summary)")
        #expect(!event.summary.contains("5 warnings"), "summary was: \(event.summary)")

        // Without a count (hand-built events, or a run with none), the
        // sample's own length is the answer.
        var bare = event
        bare.warningCount = nil
        #expect(bare.summary.contains("5 warnings"), "summary was: \(bare.summary)")

        var two = event
        two.warnings = ["one", "two"]
        two.warningCount = nil
        #expect(two.summary.contains("2 warnings"), "summary was: \(two.summary)")
    }
}

/// A backup that fails the same way again notifies once: the first of a
/// stretch posts, a repeat stays quiet until a success, a skip or another
/// cause re-arms it. The menu bar, the caption and Activity still show
/// every run; the channels' per-run pings are not this rule's.
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

    @Test("the same outcome for the same cause repeats the problem; anything else is news")
    func sameCauseRepeats() {
        #expect(AppModel.repeatsProblem(failed(60), previous: failed(0)))
        #expect(!AppModel.repeatsProblem(failed(60), previous: nil))
        #expect(!AppModel.repeatsProblem(failed(60, exit: 11), previous: failed(0)))
        #expect(!AppModel.repeatsProblem(failed(60, message: "Fatal: wrong password or no key found"), previous: failed(0)))
        // Numbers in restic's words change from run to run: a lock's PID and age.
        #expect(AppModel.repeatsProblem(
            failed(60, exit: 11, message: "Fatal: unable to create lock in backend: repository is already locked by PID 4242 on nas by u (UID 501, GID 20)"),
            previous: failed(0, exit: 11, message: "Fatal: unable to create lock in backend: repository is already locked by PID 517 on nas by u (UID 501, GID 20)")
        ))
        #expect(AppModel.repeatsProblem(warned(60), previous: warned(0)))
        #expect(!AppModel.repeatsProblem(warned(60, items: ["/b: open /b: permission denied"]), previous: warned(0)))
        #expect(!AppModel.repeatsProblem(warned(60), previous: failed(0)))
        var success = failed(0)
        success.outcome = .succeeded
        success.failureMessage = nil
        #expect(!AppModel.repeatsProblem(failed(60), previous: success))
        // A merged repeat (a standing failure for the same folders gone)
        // carries its own count.
        var standing = failed(60)
        standing.skipCount = 2
        #expect(AppModel.repeatsProblem(standing, previous: nil))
        // A success is never a repeat.
        #expect(!AppModel.repeatsProblem(success, previous: success))
    }

    private func ended(_ minutes: Double, _ outcome: RunRecord.Outcome) -> RunRecord {
        var run = RunRecord(kind: .backup, planID: planID, planName: "Documents", startedAt: now.addingTimeInterval(minutes * 60))
        run.outcome = outcome
        return run
    }

    @Test("the plan page's card counts the problem's stretch — the backups in a row the notification rule calls one problem")
    func stretch() {
        func count(_ newestFirst: [RunRecord], of problem: RunRecord? = nil) -> Int {
            AppModel.problemStretch(of: problem ?? newestFirst[0], in: newestFirst)
        }
        // Three warnings for the same file since a success, two before it.
        #expect(count([warned(600), warned(540), warned(480), ended(420, .succeeded), warned(360), warned(300)]) == 3)
        // A skip or a cancel in between ends it too, as it re-arms the notification.
        #expect(count([warned(600), ended(540, .skipped), warned(480)]) == 1)
        #expect(count([warned(600), ended(540, .cancelled), warned(480)]) == 1)
        // Another cause, or another outcome, is another problem.
        #expect(count([warned(600, items: ["/b: open /b: permission denied"]), warned(540)]) == 1)
        #expect(count([failed(600), warned(540)]) == 1)
        // The numbers in restic's words change from run to run; the cause does not.
        #expect(count([
            failed(600, exit: 11, message: "Fatal: unable to create lock in backend: repository is already locked by PID 4242 on nas by u (UID 501, GID 20)"),
            failed(540, exit: 11, message: "Fatal: unable to create lock in backend: repository is already locked by PID 517 on nas by u (UID 501, GID 20)"),
        ]) == 2)
        // Another plan's runs neither end it nor add to it.
        var otherSuccess = ended(570, .succeeded)
        otherSuccess.planID = UUID()
        var otherWarning = warned(560)
        otherWarning.planID = UUID()
        #expect(count([warned(600), otherSuccess, otherWarning, warned(540)]) == 2)
        // A failure merged into a standing one for the same folders gone
        // counts the runs it stands for.
        var standing = failed(600)
        standing.skipCount = 3
        #expect(count([standing, ended(300, .succeeded)]) == 3)
        // The card's problem need not be the newest record: a plain skip
        // after it heals nothing, and the count starts from the problem.
        let problem = warned(540)
        #expect(count([ended(600, .skipped), problem, warned(480), ended(420, .succeeded)], of: problem) == 2)
    }

    @MainActor
    @Test("a run's notification follows the setting, and a problem's only the first time in a stretch")
    func wantsNotification() {
        let suite = "SwiftResticRepeatedProblemTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel(
            store: ConfigStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("SwiftResticRepeated-\(UUID().uuidString)")),
            secrets: .inMemory(),
            defaults: defaults
        )
        let first = failed(0)
        model.append(record: first)
        #expect(model.wantsNotification(for: first))
        let again = failed(60)
        model.append(record: again)
        #expect(!model.wantsNotification(for: again))

        var success = failed(120)
        success.outcome = .succeeded
        success.failureMessage = nil
        model.append(record: success)
        #expect(!model.wantsNotification(for: success), "successes notify only when asked")
        let afterSuccess = failed(180)
        model.append(record: afterSuccess)
        #expect(model.wantsNotification(for: afterSuccess))

        // A run merged into a standing failure for the same folders gone:
        // the run it continued is gone from the history, its count is not.
        func gone(_ minutes: Double) -> RunRecord {
            var run = failed(minutes, message: RunRecord.folderGoneMessage(sources: ["/Users/me/Projects"]))
            run.missingSources = ["/Users/me/Projects"]
            return run
        }
        let goneFirst = gone(240)
        model.append(record: goneFirst)
        #expect(model.wantsNotification(for: goneFirst))
        let goneAgain = gone(300)
        model.append(record: goneAgain)
        #expect(model.configuration.runs.first?.skipCount == 2)
        #expect(!model.wantsNotification(for: goneAgain))

        model.configuration.settings.notifyOnFailure = false
        let silenced = failed(360, exit: 12, message: "Fatal: wrong password or no key found")
        model.append(record: silenced)
        #expect(!model.wantsNotification(for: silenced))
    }
}
