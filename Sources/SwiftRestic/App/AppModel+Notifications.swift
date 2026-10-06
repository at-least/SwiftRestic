import Foundation
import UserNotifications

extension AppModel {
    // MARK: - Notifications

    /// The outcome of a Settings alert-channel test, reported inline where the
    /// user clicked rather than as a global banner on another window.
    enum TestNotificationOutcome: Equatable, Sendable {
        case unusable
        case delivered
        case failed(String)
    }

    /// Sends one channel a sample event so the user can confirm it is wired up.
    func sendTestNotification(_ channel: NotificationChannel) async -> TestNotificationOutcome {
        let event = NotificationEvent(
            stage: .succeeded,
            planName: "Test",
            repositoryName: "SwiftRestic",
            dataAdded: 1_234_567,
            duration: 12
        )
        guard let payload = NotificationPayload.request(for: channel, event: event) else {
            return .unusable
        }
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

    func notify(about record: RunRecord) {
        let settings = configuration.settings
        let wantsNotification = switch record.outcome {
        case .succeeded: settings.notifyOnSuccess
        case .completedWithErrors, .failed: settings.notifyOnFailure
        case .cancelled: false
        }
        guard wantsNotification, Self.supportsNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = Self.notificationTitle(
            for: record,
            plans: configuration.plans,
            repositories: configuration.repositories
        )
        content.body = Self.notificationBody(for: record)
        let request = UNNotificationRequest(
            identifier: record.id.uuidString,
            content: content,
            trigger: nil
        )
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
                let message: String
                if let problem = error as? NotificationProblem, problem == .permissionDenied {
                    message = "macOS notification permission is off — turn SwiftRestic on in System Settings › Notifications to see failure alerts again."
                } else {
                    message = error.localizedDescription
                }
                post(Banner(
                    title: "Could not send a notification",
                    message: message,
                    isError: true
                ))
            }
        }
    }

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
            return "Finished with \(Format.plural(record.itemErrorCount, "unreadable item")).\(hint)"
        case .completedWithErrors:
            let detail = RunRecordPresentation.detail(for: record)
            return "Finished with warnings: \(detail)\(detail.hasSuffix(".") ? "" : ".")"
        case .failed:
            return record.failureMessage.map(Format.firstSentence) ?? "The backup failed."
        case .cancelled:
            return "Cancelled."
        }
    }

    /// Why a local notification could not be delivered, for the banner text.
    private enum NotificationProblem: Error {
        case permissionDenied
    }
}
