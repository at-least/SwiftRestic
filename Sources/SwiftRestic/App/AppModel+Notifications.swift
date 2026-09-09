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
    private static var supportsNotifications: Bool {
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
        content.title = record.planName.isEmpty ? "SwiftRestic" : record.planName
        content.body = switch record.outcome {
        case .succeeded:
            "Backed up \(Format.bytes(record.dataAdded)) of new data in \(Format.duration(record.duration))."
        case .completedWithErrors:
            "Finished with \(max(record.itemErrorCount, record.itemErrors.count)) unreadable item(s)."
        case .failed:
            record.failureMessage ?? "The backup failed."
        case .cancelled:
            "Cancelled."
        }
        let request = UNNotificationRequest(
            identifier: record.id.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
