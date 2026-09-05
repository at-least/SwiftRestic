import Foundation

/// Turns an event into the HTTP request a channel expects.
///
/// Kept separate from the sending so it can be tested without a network: the
/// shape of each provider's payload is the part that is easy to get wrong.
enum NotificationPayload {
    struct Request: Sendable, Equatable {
        var url: URL
        var method: String = "POST"
        var body: Data?
        var contentType: String?

        var bodyString: String? { body.flatMap { String(data: $0, encoding: .utf8) } }
    }

    static func request(for channel: NotificationChannel, event: NotificationEvent) -> Request? {
        let trimmed = channel.url.trimmingCharacters(in: .whitespaces)
        guard channel.isUsable, var url = URL(string: trimmed) else { return nil }

        switch channel.kind {
        case .healthchecks:
            // The ping URL itself means "still alive"; the suffixes mean "starting"
            // and "this run failed". Anything else and the dead-man's switch
            // stops meaning anything.
            switch event.stage {
            case .started: url.append(path: "start")
            case .failed, .cancelled: url.append(path: "fail")
            case .succeeded, .warned: break
            }
            // Healthchecks stores a POST body as the run's log.
            return Request(
                url: url,
                body: Data(event.summary.utf8),
                contentType: "text/plain; charset=utf-8"
            )

        case .slack:
            return json(url: url, object: ["text": event.summary])

        case .discord:
            return json(url: url, object: ["content": event.summary])

        case .webhook:
            var object: [String: Any] = [
                "stage": event.stage.rawValue,
                "operation": event.operation,
                "plan": event.planName,
                "repository": event.repositoryName,
                "summary": event.summary,
                "files_new": event.filesNew,
                "bytes_processed": event.bytesProcessed,
                "data_added": event.dataAdded,
                "duration_seconds": event.duration,
            ]
            if let snapshotID = event.snapshotID { object["snapshot_id"] = snapshotID }
            if let errorMessage = event.errorMessage { object["error"] = errorMessage }
            if !event.warnings.isEmpty { object["warnings"] = event.warnings }
            return json(url: url, object: object)
        }
    }

    private static func json(url: URL, object: [String: Any]) -> Request? {
        guard let body = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else { return nil }
        return Request(url: url, body: body, contentType: "application/json")
    }
}

/// Sends the requests. Deliberately best-effort: a notification that does not
/// arrive must never change what the run record says happened.
enum NotificationPoster {
    static let timeout: TimeInterval = 15

    /// - Returns: a short description of what went wrong, or `nil` on success.
    @discardableResult
    static func send(_ payload: NotificationPayload.Request) async -> String? {
        var request = URLRequest(url: payload.url, timeoutInterval: timeout)
        request.httpMethod = payload.method
        request.httpBody = payload.body
        if let contentType = payload.contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard (200 ..< 300).contains(http.statusCode) else {
                return "HTTP \(http.statusCode)"
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Fans an event out to every channel that asked for it.
    static func broadcast(
        _ event: NotificationEvent,
        to channels: [NotificationChannel]
    ) async -> [String] {
        var failures: [String] = []
        await withTaskGroup(of: (String, String?).self) { group in
            for channel in channels where channel.isUsable && channel.wants(event.stage) {
                guard let payload = NotificationPayload.request(for: channel, event: event) else {
                    continue
                }
                group.addTask { (channel.displayName, await send(payload)) }
            }
            for await (name, failure) in group {
                if let failure { failures.append("\(name): \(failure)") }
            }
        }
        return failures
    }
}
