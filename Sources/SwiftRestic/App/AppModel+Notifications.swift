import Foundation
import UserNotifications

extension AppModel {
    /// Shown inline beside Send Test, not as a banner on another window.
    enum TestNotificationOutcome: Equatable, Sendable {
        case delivered
        case failed(String)
    }

    func sendTestNotification(_ channel: NotificationChannel) async -> TestNotificationOutcome {
        precondition(channel.hasUsableURL, "Send Test is disabled for an unusable URL")
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

    /// Asked once there is a plan to notify about (launch, `followPlans`);
    /// macOS prompts only while the answer is undetermined. Not awaited:
    /// `requestAuthorization` suspends until the user answers.
    func requestNotificationPermission() {
        guard Self.supportsNotifications else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Once per quiet stretch: the mark is saved on the plan, so a relaunch
    /// does not repeat it. Marked even when notifications are not allowed,
    /// so a later permission does not bring back old news.
    @discardableResult
    func alertQuietPlans(now: Date) -> [StalePlanAlert] {
        var latest: [UUID: Date] = [:]
        for plan in configuration.plans {
            latest[plan.id] = latestSnapshot(in: plan.repositoryID, planID: plan.id)?.time
        }
        // A due plan whose repository has work running starts once that work
        // ends (duePlans starts one plan per repository a tick), so it is
        // treated as running. Not repositoriesMissingPassword or a drive
        // away: those hold it with no end in sight.
        let busy = busyRepositoryIDs
        let waitingTheirTurn = configuration.plans.filter { plan in
            guard let repositoryID = plan.repositoryID else { return false }
            return busy.contains(repositoryID) && plan.dueSlot(at: now) != nil
        }
        // Its listing may hold a newer backup than the history knows.
        let unread = configuration.plans.filter { plan in
            plan.repositoryID.map(repositoriesAwaitingLaunchListing.contains) == true
        }
        let alerts = StaleAlert.due(
            plans: configuration.plans,
            latestSnapshotTimes: latest,
            running: runningPlanIDs.union(waitingTheirTurn.map(\.id)).union(unread.map(\.id)),
            now: now
        )
        for alert in alerts {
            guard let plan = plan(id: alert.planID) else { continue }
            updatePlan(plan.id) { $0.staleAlertedFor = alert.lastBackupAt }
            guard Self.supportsNotifications else { continue }
            let text = StaleAlert.notification(
                planTitle: RunRecordPresentation.planWithRepository(
                    plan, plans: configuration.plans, repositories: configuration.repositories
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

    /// Read back by `NotificationRoute`.
    nonisolated static let quietPlanNotificationPrefix = "quiet-plan:"

    private func announcesFirstBackup(_ record: RunRecord) -> Bool {
        record.kind == .backup && record.outcome == .succeeded && plan(id: record.planID)?.announcesFirstBackup == true
    }

    func wantsNotification(for record: RunRecord) -> Bool {
        let settings = configuration.settings
        switch record.outcome {
        case .succeeded: return settings.notifyOnSuccess || announcesFirstBackup(record)
        case .completedWithErrors, .failed:
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

    /// Awaited rather than detached so that quitting straight after a failed
    /// backup still gets the alert out; a failure to deliver is shown to the user
    /// but never written into the run record, which describes the backup itself.
    func broadcast(record: RunRecord, plan: BackupPlan?) async {
        let channels = configuration.settings.notificationChannels
        let notifyOnSuccess = configuration.settings.notifyOnSuccess
        guard channels.contains(where: \.hasUsableURL) else { return }

        if let planID = plan?.id { setActivityPhase(.notifying, for: planID) }

        let event = Self.notificationEvent(for: record, repositoryName: repository(id: record.repositoryID).map { label(of: $0) } ?? "")

        // Detached: a stopped run delivers from its own cancelled task, and
        // an inherited cancel fails every send at once — a monitor that
        // heard /start would never hear /fail. Awaiting a detached task
        // does not pass the cancel on; quit still waits for it.
        let failures = await Task.detached {
            await NotificationPoster.broadcast(event, to: channels, notifyOnSuccess: notifyOnSuccess)
        }.value
        if !failures.isEmpty {
            // The banner queue is global: the title names the run.
            let subject = RunRecordPresentation.displayName(
                for: record,
                plans: configuration.plans,
                repositories: configuration.repositories
            )
            post(Banner(
                title: "Couldn’t send \(Format.plural(failures.count, "notification"))"
                    + (subject.isEmpty ? "" : " for \(subject)"),
                message: failures.joined(separator: "\n"),
                level: .warning
            ))
        }
    }

    static func notificationEvent(for record: RunRecord, repositoryName: String) -> NotificationEvent {
        let stage: NotificationEvent.Stage
        switch record.outcome {
        case .succeeded: stage = .succeeded
        case .completedWithErrors: stage = .warned
        case .failed: stage = .failed
        case .cancelled: stage = .cancelled
        case .skipped: stage = .skipped
        }
        return NotificationEvent(
            stage: stage,
            planName: record.planName,
            repositoryName: repositoryName,
            kind: record.kind,
            snapshotID: record.snapshotID,
            // A skipped run's reason is its detail, not a failure.
            errorMessage: record.failureMessage ?? (record.outcome == .skipped ? record.detailText : nil),
            // restic's own warnings only: excerpts for the body, the full
            // count for the summary.
            warnings: Array((record.unreadableItems + record.trailingItemErrorsOnScreen).prefix(5)),
            warningCount: record.itemErrorCount > 0 ? record.itemErrorCount : nil,
            hint: ItemErrorDiagnosis.headline(for: record),
            filesNew: record.filesNew,
            bytesProcessed: record.bytesProcessed,
            dataAdded: record.dataAdded,
            duration: record.duration
        )
    }

    func addStartPing(_ event: NotificationEvent) {
        let channels = configuration.settings.notificationChannels
        let notifyOnSuccess = configuration.settings.notifyOnSuccess
        tasks.addBackground(Task.detached {
            _ = await NotificationPoster.broadcast(event, to: channels, notifyOnSuccess: notifyOnSuccess)
        })
    }

    func notify(about record: RunRecord, now: Date = .now) {
        guard wantsNotification(for: record) else { return }
        var firstBackup: (title: String, body: String)?
        var announcedPlanID: UUID?
        if announcesFirstBackup(record), let planID = record.planID, let plan = plan(id: planID) {
            firstBackup = Self.firstBackupNotification(plan: plan, among: configuration.plans, now: now)
            announcedPlanID = planID
        }

        let content = UNMutableNotificationContent()
        content.title = firstBackup?.title ?? Self.notificationTitle(
            for: record,
            plans: configuration.plans,
            repositories: configuration.repositories
        )
        content.body = firstBackup?.body ?? Self.notificationBody(for: record)
        // Disarmed only once accepted: with notifications not allowed, the
        // first success after they are allowed says it instead.
        deliver(UNNotificationRequest(
            identifier: record.id.uuidString,
            content: content,
            trigger: nil
        ), onAccepted: { [weak self] in
            guard let self, let announcedPlanID else { return }
            self.updatePlan(announcedPlanID) { $0.announcesFirstBackup = false }
        })
    }

    private func deliver(_ request: UNNotificationRequest, onAccepted: @escaping @MainActor () -> Void = {}) {
        Task {
            // A notification that silently never arrives is the failure a
            // backup app most cannot afford, so it banners, once per stretch
            // of failures. Denied permission is the common cause.
            do {
                try await notificationPoster(request)
                notificationsProblemNoted = false
                onAccepted()
            } catch {
                guard !notificationsProblemNoted else { return }
                notificationsProblemNoted = true
                // A warning: the run itself is unharmed. The banner links to
                // the setting rather than describing where it is.
                if let problem = error as? NotificationProblem, problem == .permissionDenied {
                    post(Banner(
                        title: "Couldn’t send a notification",
                        message: "Notifications are turned off for SwiftRestic.",
                        level: .warning,
                        link: Banner.Link(title: "Open Notification Settings", url: Self.notificationSettingsURL)
                    ))
                } else {
                    post(Banner(title: "Couldn’t send a notification", message: error.localizedDescription, level: .warning))
                }
            }
        }
    }

    /// A host without a notification center has nothing to refuse the request.
    static func addToNotificationCenter(_ request: UNNotificationRequest) async throws {
        guard supportsNotifications else { return }
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            try await center.add(request)
        default:
            throw NotificationProblem.permissionDenied
        }
    }

    private static let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier!)"
    )!

    static func firstBackupNotification(plan: BackupPlan, among plans: [BackupPlan], now: Date) -> (title: String, body: String) {
        let next = plan.schedule.nextRunDate(after: plan.lastRunAt, now: now)
        return (
            title: "“\(plan.label(among: plans))” is backed up",
            body: next.map { "Next backup: \(Format.tileTimestamp($0))" } ?? "It backs up again when you click Back Up Now."
        )
    }

    static func notificationTitle(
        for record: RunRecord,
        plans: [BackupPlan],
        repositories: [Repository]
    ) -> String {
        let name = RunRecordPresentation.displayName(for: record, plans: plans, repositories: repositories)
        return name.isEmpty ? "SwiftRestic" : name
    }

    /// A warning with no unreadable items (a skipped retention step, an
    /// unnamed exit 3) says what Activity's Detail column says, never
    /// "0 unreadable items".
    static func notificationBody(for record: RunRecord) -> String {
        switch record.outcome {
        case .succeeded:
            return "Backed up \(Format.bytes(record.dataAdded)) of new data in \(Format.duration(record.duration))."
        case .completedWithErrors where record.itemErrorCount > 0:
            let hint = ItemErrorDiagnosis.headline(for: record).map { " " + $0 } ?? ""
            return "Completed with \(Format.plural(record.itemErrorCount, "unreadable item")).\(hint)"
        case .completedWithErrors:
            let detail = RunRecordPresentation.detail(for: record)
            return "Completed with warnings: \(Format.fullSentence(detail))"
        case .failed:
            return record.failureMessage.map { "Failed: \(Format.firstSentence($0))" } ?? "Failed."
        case .cancelled:
            return "Stopped."
        case .skipped:
            return record.detailText ?? "Skipped."
        }
    }

    enum NotificationProblem: Error {
        case permissionDenied
    }
}

/// Identifiers: a quiet-plan alert is `quietPlanNotificationPrefix` plus
/// the plan's ID, a run notification the run's ID alone. Kept beside the
/// two writers above (`alertQuietPlans`, `notify`): nothing else ties them.
enum NotificationRoute: Equatable {
    case plan(UUID)
    case run(UUID)

    static func route(forIdentifier identifier: String) -> NotificationRoute? {
        let prefix = AppModel.quietPlanNotificationPrefix
        if identifier.hasPrefix(prefix), let planID = UUID(uuidString: String(identifier.dropFirst(prefix.count))) {
            return .plan(planID)
        }
        return UUID(uuidString: identifier).map { .run($0) }
    }
}
