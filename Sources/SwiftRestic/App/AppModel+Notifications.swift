import Foundation
import UserNotifications

extension AppModel {
    // MARK: - Notifications

    /// The outcome of a Settings › Webhooks test, reported inline where the
    /// user clicked rather than as a global banner on another window.
    enum TestNotificationOutcome: Equatable, Sendable {
        case delivered
        case failed(String)
    }

    /// Sends one channel a sample event so the user can confirm it is wired
    /// up — switched on or not: the switch decides what runs send, and the
    /// test is how the user learns it works before turning it on.
    func sendTestNotification(_ channel: NotificationChannel) async -> TestNotificationOutcome {
        precondition(channel.hasUsableURL, "Send Test Notification is disabled for an unusable URL")
        var channel = channel
        channel.isEnabled = true
        let event = NotificationEvent(
            stage: .succeeded,
            planName: "Test",
            repositoryName: "SwiftRestic",
            kind: .backup,
            dataAdded: 1_234_567,
            duration: 12
        )
        // On, with a URL the precondition checked: `request` declines nothing else.
        let payload = NotificationPayload.request(for: channel, event: event)!
        if let failure = await NotificationPoster.send(payload) {
            return .failed(failure)
        }
        return .delivered
    }

    /// `UNUserNotificationCenter.current()` traps when the running binary is not
    /// an application bundle, which is exactly the case under a test runner.
    static var supportsNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    func requestNotificationPermission() async {
        guard Self.supportsNotifications else { return }
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// The quiet-plan alert's tick (`StaleAlert`): names each plan that
    /// has gone quiet past its window, once per stretch — the mark is saved
    /// on the plan, so a relaunch does not name it again. Marked even when
    /// local notifications are off or not allowed: the alert is the
    /// notification, and a later permission must not bring back old news.
    @discardableResult
    func alertQuietPlans(now: Date) -> [StalePlanAlert] {
        var latest: [UUID: Date] = [:]
        for plan in configuration.plans {
            latest[plan.id] = snapshots(for: plan.repositoryID, planID: plan.id).first?.time
        }
        let alerts = StaleAlert.due(
            plans: configuration.plans,
            latestSnapshotTimes: latest,
            thresholdDays: configuration.settings.staleAlertDays,
            running: runningPlanIDs,
            now: now
        )
        for alert in alerts {
            guard let index = configuration.plans.firstIndex(where: { $0.id == alert.planID }) else { continue }
            configuration.plans[index].staleAlertedFor = alert.lastBackupAt
            guard Self.supportsNotifications else { continue }
            let text = StaleAlert.notification(
                planTitle: RunRecordPresentation.planWithRepository(
                    configuration.plans[index], plans: configuration.plans, repositories: configuration.repositories
                ),
                alert: alert
            )
            let content = UNMutableNotificationContent()
            content.title = text.title
            content.body = text.body
            deliver(UNNotificationRequest(
                identifier: Self.quietPlanNotificationPrefix + alert.planID.uuidString,
                content: content,
                trigger: nil
            ))
        }
        return alerts
    }

    /// A quiet-plan notification's identifier: this prefix and the plan's
    /// ID, which a click opens; a run notification's is the run's ID.
    nonisolated static let quietPlanNotificationPrefix = "quiet-plan:"

    /// Whether a finished backup gets a local notification: its outcome's
    /// setting, and for a problem, only the first of its stretch
    /// (`RunRecord.problemStretch`).
    func wantsNotification(for record: RunRecord) -> Bool {
        let settings = configuration.settings
        switch record.outcome {
        case .succeeded: return settings.notifyOnSuccess
        case .completedWithErrors, .failed:
            guard settings.notifyOnFailure else { return false }
            // As stored: `append(record:)` counted it before the history cap
            // trimmed the backups before it, and a run merged into a standing
            // failure counts the runs it stands for.
            guard let stretch = configuration.runs.first(where: { $0.id == record.id })?.problemStretch else {
                preconditionFailure("backup \(record.id) is not in the history with a problem stretch")
            }
            return stretch == 1
        // A drive not plugged in is no failure; the quiet-plan alert speaks
        // if it stays away.
        case .cancelled, .skipped: return false
        }
    }

    func notify(about record: RunRecord) {
        guard wantsNotification(for: record), Self.supportsNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = Self.notificationTitle(
            for: record,
            plans: configuration.plans,
            repositories: configuration.repositories
        )
        content.body = Self.notificationBody(for: record)
        deliver(UNNotificationRequest(
            identifier: record.id.uuidString,
            content: content,
            trigger: nil
        ))
    }

    /// Hands a notification to macOS, or says once why it cannot.
    private func deliver(_ request: UNNotificationRequest) {
        Task {
            // A notification that silently never arrives is the failure mode
            // a backup app most cannot afford: external channels banner their
            // delivery errors, and the local one must too. Denied permission
            // is the common way this happens — say it once per stretch, the
            // same transition-signal rule the stats banner follows.
            let center = UNUserNotificationCenter.current()
            let authorization = await center.notificationSettings().authorizationStatus
            do {
                switch authorization {
                case .authorized, .provisional, .ephemeral:
                    try await center.add(request)
                    notificationsProblemNoted = false
                default:
                    throw NotificationProblem.permissionDenied
                }
            } catch {
                guard !notificationsProblemNoted else { return }
                notificationsProblemNoted = true
                // A warning, not an error: the run itself is unharmed. The
                // permission's fix is a place, so the banner opens it rather
                // than describing where it is (the HIG's Writing).
                if let problem = error as? NotificationProblem, problem == .permissionDenied {
                    post(Banner(
                        title: "Could not send a notification",
                        message: "macOS notification permission is off for SwiftRestic, so its notifications don't appear.",
                        level: .warning,
                        link: Banner.Link(title: "Open Notification Settings", url: Self.notificationSettingsURL)
                    ))
                } else {
                    post(Banner(title: "Could not send a notification", message: error.localizedDescription, level: .warning))
                }
            }
        }
    }

    /// System Settings › Notifications, on this app's own entry.
    static let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier!)"
    )!

    /// The local notification's title: the run's display name — the plan
    /// with its repository, the one rule every run surface names by — or
    /// the app's name when the record names nothing.
    static func notificationTitle(
        for record: RunRecord,
        plans: [BackupPlan],
        repositories: [Repository]
    ) -> String {
        let name = RunRecordPresentation.displayName(for: record, plans: plans, repositories: repositories)
        return name.isEmpty ? "SwiftRestic" : name
    }

    /// The local notification's text. A warning counts restic's unreadable
    /// items and names the fix when the app knows one; a warning with none —
    /// a skipped retention step, a failing hook, an unnamed exit 3 — says
    /// what Activity's Detail column says, never "0 unreadable items", and
    /// never counts the retention line as one.
    static func notificationBody(for record: RunRecord) -> String {
        switch record.outcome {
        case .succeeded:
            return "Backed up \(Format.bytes(record.dataAdded)) of new data in \(Format.duration(record.duration))."
        case .completedWithErrors where record.itemErrorCount > 0:
            let hint = ItemErrorDiagnosis.headline(for: record).map { " " + $0 } ?? ""
            return "Completed with \(Format.plural(record.itemErrorCount, "unreadable item")).\(hint)"
        case .completedWithErrors:
            let detail = RunRecordPresentation.detail(for: record)
            return "Completed with warnings: \(detail)\(detail.hasSuffix(".") ? "" : ".")"
        case .failed:
            return record.failureMessage.map(Format.firstSentence) ?? "The backup failed."
        case .cancelled:
            return "Cancelled."
        case .skipped:
            return record.detailText ?? "Skipped."
        }
    }

    /// Why a local notification could not be delivered, for the banner text.
    private enum NotificationProblem: Error {
        case permissionDenied
    }
}
