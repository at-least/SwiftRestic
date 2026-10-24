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
            kind: .backup,
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
        #expect((slackBody?["text"] as? String)?.contains("Backup failed") == true)

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

    @Test("the webhook's operation keeps restic's word while the screen says Cleanup")
    @MainActor
    func payloadOperationIsStable() throws {
        var prune = RunRecord(kind: .prune, planName: "")
        prune.outcome = .failed
        #expect(prune.kind.displayName == "Cleanup")
        let event = AppModel.notificationEvent(for: prune, repositoryName: "NAS")
        #expect(event.kind.payloadOperation == "Prune")
        #expect(event.summary.hasPrefix("Cleanup failed: "), "summary was \(event.summary)")
        let request = try #require(NotificationPayload.request(for: channel(.webhook, url: "https://example.com/hook"), event: event))
        let data = try #require(request.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["operation"] as? String == "Prune")
        #expect(AppModel.notificationEvent(for: RunRecord(kind: .forget, planName: "Docs"), repositoryName: "NAS").kind.payloadOperation == "Retention")
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
        // rule's same-name guard leaves it said once.
        let check = NotificationEvent(stage: .failed, planName: "NAS", repositoryName: "NAS", kind: .check, errorMessage: "locked")
        #expect(check.summary == "Check failed: NAS — locked", "summary was \(check.summary)")
        #expect(!check.summary.contains("NAS (NAS)"))
        // An event with no plan names the repository alone.
        let bare = NotificationEvent(stage: .failed, planName: "", repositoryName: "NAS", kind: .prune, errorMessage: "locked")
        #expect(bare.summary == "Cleanup failed: NAS — locked", "summary was \(bare.summary)")
    }

    @MainActor
    @Test("only a backup's success says how much data it added")
    func onlyABackupSaysDataAdded() {
        var check = RunRecord(kind: .check, planName: "NAS")
        check.outcome = .succeeded
        check.finishedAt = check.startedAt.addingTimeInterval(4)
        let checkSummary = AppModel.notificationEvent(for: check, repositoryName: "NAS").summary
        #expect(checkSummary == "Check succeeded: NAS in \(Format.duration(4))", "summary was \(checkSummary)")
        var backup = RunRecord(kind: .backup, planName: "Docs")
        backup.outcome = .succeeded
        backup.dataAdded = 0
        #expect(AppModel.notificationEvent(for: backup, repositoryName: "NAS").summary.contains("— \(Format.bytes(0)) added"))
    }

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
            kind: .backup,
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
            == "Completed with 2 unreadable items. macOS blocked 1 item: SwiftRestic needs Full Disk Access.")
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
        #expect(AppModel.notificationBody(for: record).hasPrefix("Completed with 1 unreadable item."))

        // A retention skip alone is not an unreadable item — not one, not zero.
        var retentionOnly = RunRecord(kind: .backup, planName: "Documents")
        retentionOnly.outcome = .completedWithErrors
        retentionOnly.itemErrors = [RunRecord.retentionSkippedPrefix + "locked"]
        retentionOnly.itemErrorCount = 0
        let body = AppModel.notificationBody(for: retentionOnly)
        #expect(!body.contains("unreadable"), "body was \(body)")
        #expect(body == "Completed with warnings: Retention skipped.")
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

        let event = NotificationEvent(stage: .cancelled, planName: "Docs", repositoryName: "NAS", kind: .backup)
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
            kind: .backup,
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

/// The poster's own failure words, reported verbatim beside Settings' Send
/// Test Notification button and in the channels' banners.
@Suite("NotificationPoster")
struct NotificationPosterTests {
    @Test("a cancelled send reads as the app's sentence, not URLSession's bare word")
    func cancelledSend() async throws {
        // A listener that completes the handshake and never answers parks the
        // request mid-flight: accept() returning proves URLSession is
        // connected and waiting, so the cancel hits the running request —
        // the state a stalled endpoint puts the test button in. A cancel
        // that landed before the request started would not take URLSession's
        // own cancellation path, which is the branch this pins.
        let listening = try LocalPort.listening()
        _ = fcntl(listening.socket, F_SETFL, fcntl(listening.socket, F_GETFL) | O_NONBLOCK)
        defer { close(listening.socket) }

        let payload = NotificationPayload.Request(
            url: URL(string: "http://127.0.0.1:\(listening.port)/ping")!,
            body: Data("test".utf8),
            contentType: "text/plain"
        )
        let send = Task { await NotificationPoster.send(payload) }
        var connection: Int32 = -1
        for _ in 0 ..< 500 where connection < 0 {
            connection = accept(listening.socket, nil, nil)
            if connection < 0 { try await Task.sleep(for: .milliseconds(10)) }
        }
        try #require(connection >= 0, "the request never connected")
        close(connection)

        send.cancel()
        #expect(await send.value == "The request was cancelled")
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
            repositoryName: "NAS",
            kind: .backup
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
/// stretch posts, a repeat stays quiet until a success or another cause
/// re-arms it — a backup skipped whole or stopped passes over it. The menu
/// bar, the caption and Activity still show every run; the channels'
/// per-run pings are not this rule's.
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
        if let limit { model.configuration.settings.maxRunHistory = limit }
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
        // A warning's other lines and hook complaints with their numbers
        // aside; its unreadable items exactly — two files are two problems.
        var timedOut = warned(60)
        timedOut.hookMessages = ["After-success hook exited with status 28: curl: (28) Operation timed out after 1010 milliseconds with 0 bytes received"]
        var timedOutBefore = warned(0)
        timedOutBefore.hookMessages = ["After-success hook exited with status 28: curl: (28) Operation timed out after 1007 milliseconds with 0 bytes received"]
        #expect(timedOut.isSameProblem(as: timedOutBefore))
        var gap = warned(60)
        gap.itemErrors.append("3 restic messages could not be decoded — a restic update may have changed its output; the run’s numbers may be incomplete.")
        var gapBefore = warned(0)
        gapBefore.itemErrors.append("5 restic messages could not be decoded — a restic update may have changed its output; the run’s numbers may be incomplete.")
        #expect(gap.isSameProblem(as: gapBefore))
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
        // Three warnings for the same file since a success, two before it.
        #expect(counts([warned(600), warned(540), warned(480), ended(420, .succeeded), warned(360), warned(300)])
            == [3, 2, 1, nil, 2, 1])
        // A backup skipped whole or stopped ran nothing: the stretch goes on.
        #expect(counts([warned(600), ended(540, .skipped), warned(480)]) == [2, nil, 1])
        #expect(counts([warned(600), ended(540, .cancelled), warned(480)]) == [2, nil, 1])
        // One that backed up the rest around an away drive heals, as a success does.
        var partial = ended(540, .skipped)
        partial.snapshotID = "0ef0dab0"
        #expect(counts([warned(600), partial, warned(480)]) == [1, nil, 1])
        // Another cause, or another outcome, is another problem.
        #expect(counts([warned(600, items: ["/b: open /b: permission denied"]), warned(540)]) == [1, 1])
        #expect(counts([failed(600), warned(540)]) == [1, 1])
        // Another plan's runs, and the plan's own retention run, neither end
        // it nor add to it.
        var forget = ended(550, .succeeded)
        forget.kind = .forget
        #expect(counts([warned(600), ended(570, .succeeded, plan: UUID()), forget, warned(560, items: ["/z"]).withPlan(UUID()), warned(540)])
            == [2, nil, nil, 1, 1])
        // A failure merged into a standing one counts the runs it stands for,
        // on top of an earlier failure for the same cause it did not merge
        // into (a hook's complaint on that one stops the merge).
        var merged = failed(600)
        merged.skipCount = 3
        var complained = failed(300)
        complained.hookMessages = ["After-failure hook exited with status 1"]
        #expect(counts([merged, complained, failed(200)]) == [5, 2, 1])
        // A stored stretch stands — the backups it counted may be trimmed
        // since — and the next one continues it.
        var kept = warned(300)
        kept.problemStretch = 7
        #expect(counts([warned(600), kept]) == [8, 7])
    }

    @MainActor
    @Test("a run's notification follows the setting, and a problem's only the first time in a stretch")
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
        #expect(!model.wantsNotification(for: success), "successes notify only when asked")
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

        model.configuration.settings.notifyOnFailure = false
        let silenced = failed(360, exit: 12, message: "Fatal: wrong password or no key found")
        model.append(record: silenced)
        #expect(!model.wantsNotification(for: silenced))
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

