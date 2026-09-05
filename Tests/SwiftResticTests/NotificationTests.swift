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

    @Test("hook output never leaves the machine")
    func hookOutputIsNotBroadcast() throws {
        // A hook is an arbitrary user script; a verbose curl prints its own
        // Authorization header. That must not reach a webhook.
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
