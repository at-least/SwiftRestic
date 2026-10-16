import Foundation
import Network
import os

/// One connection attempt to a network repository's server before restic is
/// asked. restic 0.19.1 retries a server that refuses, does not answer or
/// whose name does not resolve for about a quarter of an hour before it
/// fails — 891 s refused, 927 s unroutable, 841 s unresolvable (2026-10-17)
/// — so a backup held the repository, the menu bar's busy face and the
/// Mac's sleep that long, then failed red, at every slot. A server out of
/// reach is a drive that is away: the run is skipped within seconds, in
/// these words, and runs again when the network changes or at its next
/// slot. Injectable, so a test never dials anything.
struct ServerProbe: Sendable {
    struct Target: Equatable, Sendable {
        var host: String
        var port: UInt16
    }

    enum Outcome: Equatable, Sendable {
        case reachable
        /// Why, in words that follow "cannot be reached": "connection refused".
        case unreachable(String)
    }

    /// The repository's server answered or not; nil when there is nothing to
    /// ask first (`httpTarget`, `sshTarget`). `environment` is what restic
    /// runs with: the app's own, the repository's extra variables over it.
    var check: @Sendable (_ repository: Repository, _ environment: [String: String]) async -> Outcome?

    static let network = ServerProbe { repository, environment in
        let target: Target? = if repository.kind == .sftp {
            await sshConfig(of: repository).flatMap(sshTarget(fromConfig:))
        } else {
            httpTarget(of: repository, environment: environment)
        }
        guard let target else { return nil }
        return await connect(to: target, timeout: timeout)
    }

    /// Long enough for a slow network's name lookup and handshake, short
    /// enough that a server out of reach costs seconds, not restic's quarter
    /// of an hour.
    static let timeout: TimeInterval = 10

    /// The proxy variables restic (Go's net/http) honours: with one set, a
    /// direct connection proves nothing.
    static let proxyVariables = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]

    /// Where an HTTP-reached repository's server is — REST, S3, B2, Azure,
    /// GCS — or nil when there is nothing to ask first: a local folder, an
    /// SFTP host (`sshTarget`), an rclone remote (its server lives in
    /// rclone's config), a proxy in the environment restic runs with.
    static func httpTarget(of repository: Repository, environment: [String: String]) -> Target? {
        guard !proxyVariables.contains(where: { !(environment[$0] ?? "").isEmpty }) else { return nil }
        switch repository.kind {
        case .local, .sftp, .rclone:
            return nil
        case .rest:
            let url = repository.restURL.hasPrefix("rest:") ? String(repository.restURL.dropFirst(5)) : repository.restURL
            return urlTarget(url)
        case .s3:
            let endpoint = repository.s3Endpoint.isEmpty ? "s3.amazonaws.com" : repository.s3Endpoint
            return urlTarget(endpoint.contains("://") ? endpoint : "https://\(endpoint)")
        case .b2:
            return Target(host: "api.backblazeb2.com", port: 443)
        case .azure:
            guard !repository.azureAccountName.isEmpty else { return nil }
            let suffix = environment["AZURE_ENDPOINT_SUFFIX"].flatMap { $0.isEmpty ? nil : $0 } ?? "core.windows.net"
            return Target(host: "\(repository.azureAccountName).blob.\(suffix)", port: 443)
        case .gcs:
            return Target(host: "storage.googleapis.com", port: 443)
        }
    }

    private static func urlTarget(_ string: String) -> Target? {
        guard let components = URLComponents(string: string), let host = components.host, !host.isEmpty else { return nil }
        let port = components.port ?? (components.scheme?.lowercased() == "http" ? 80 : 443)
        return UInt16(exactly: port).map { Target(host: host, port: $0) }
    }

    /// An SFTP repository's server as ssh will dial it, from `ssh -G`'s
    /// answer: an alias's HostName and Port from ~/.ssh/config. Nil when ssh
    /// goes through a jump host or a command, where a direct connection
    /// proves nothing.
    static func sshTarget(fromConfig output: String) -> Target? {
        var host: String?
        var port: UInt16?
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "hostname": host = parts[1]
            case "port": port = UInt16(parts[1])
            case "proxyjump", "proxycommand": if parts[1] != "none" { return nil }
            default: break
            }
        }
        guard let host, !host.isEmpty, let port else { return nil }
        return Target(host: host, port: port)
    }

    /// `ssh -G`: the configuration ssh would use for the repository's host,
    /// resolved without connecting. Nil if ssh says nothing usable.
    private static func sshConfig(of repository: Repository) async -> String? {
        var arguments = ["-G"]
        if !repository.sftpPort.isEmpty { arguments += ["-p", repository.sftpPort] }
        if !repository.sftpUser.isEmpty { arguments += ["-l", repository.sftpUser] }
        arguments.append(repository.sftpHost)
        let result = try? await ResticRunner().run(
            binary: URL(fileURLWithPath: "/usr/bin/ssh"),
            invocation: ResticInvocation(arguments: arguments, timeout: 5, retainFullOutput: true)
        )
        return result?.stdout
    }

    /// What a connection's state says: reachable once ready; out of reach,
    /// and why, once it waits or fails; nil while it is still trying —
    /// a name that never resolves or a server that drops the attempt stays
    /// there, which only the timeout ends (`timeoutWords`).
    static func verdict(for state: NWConnection.State) -> Outcome? {
        switch state {
        case .ready:
            return .reachable
        case let .waiting(error), let .failed(error):
            return .unreachable(words(for: error))
        default:
            return nil
        }
    }

    private static func words(for error: NWError) -> String {
        switch error {
        case let .posix(code):
            switch code {
            case .ECONNREFUSED: "connection refused"
            case .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN: "no route to the server"
            case .ENETDOWN: "this Mac has no network connection"
            case .ETIMEDOUT: "it did not answer"
            default: String(cString: strerror(code.rawValue)).lowercased()
            }
        case .dns:
            "its name could not be found"
        default:
            "\(error)"
        }
    }

    static func timeoutWords(seconds: Int) -> String {
        "it did not answer within \(Format.plural(seconds, "second"))"
    }

    /// One TCP connection attempt, ended by its first verdict or `timeout`.
    static func connect(to target: Target, timeout: TimeInterval) async -> Outcome {
        guard let port = NWEndpoint.Port(rawValue: target.port) else { return .unreachable("no such port") }
        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "com.newlix.SwiftRestic.server-probe")
        return await withCheckedContinuation { continuation in
            // The state handler and the timer race to answer; the first wins.
            let answered = OSAllocatedUnfairLock(initialState: false)
            let answer: @Sendable (Outcome) -> Void = { outcome in
                let first = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                guard first else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: outcome)
            }
            connection.stateUpdateHandler = { state in
                if let outcome = verdict(for: state) { answer(outcome) }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                answer(.unreachable(timeoutWords(seconds: Int(timeout))))
            }
        }
    }
}
