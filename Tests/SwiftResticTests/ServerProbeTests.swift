import Foundation
import Network
import Testing
@testable import SwiftRestic

@Suite("server probe")
struct ServerProbeTests {
    private typealias Target = ServerProbe.Target

    private func repository(_ kind: Repository.Kind, _ edit: (inout Repository) -> Void = { _ in }) -> Repository {
        var repository = Repository()
        repository.name = "Home Server"
        repository.kind = kind
        edit(&repository)
        return repository
    }

    @Test("an HTTP-reached repository's server is read from its location; a local folder, rclone and a proxy are not probed")
    func httpTargets() {
        func target(_ repository: Repository, _ environment: [String: String] = [:]) -> Target? {
            ServerProbe.httpTarget(of: repository, environment: environment)
        }
        #expect(target(repository(.rest) { $0.restURL = "http://nas.local:8000/backups" }) == Target(host: "nas.local", port: 8000))
        #expect(target(repository(.rest) { $0.restURL = "rest:https://backup.example.com/me/" }) == Target(host: "backup.example.com", port: 443))
        #expect(target(repository(.rest) { $0.restURL = "http://10.0.0.5/" }) == Target(host: "10.0.0.5", port: 80))
        #expect(target(repository(.s3)) == Target(host: "s3.amazonaws.com", port: 443))
        #expect(target(repository(.s3) { $0.s3Endpoint = "https://minio.lan:9000" }) == Target(host: "minio.lan", port: 9000))
        #expect(target(repository(.s3) { $0.s3Endpoint = "http://minio.lan" }) == Target(host: "minio.lan", port: 80))
        #expect(target(repository(.s3) { $0.s3Endpoint = "s3.us-west-002.backblazeb2.com" }) == Target(host: "s3.us-west-002.backblazeb2.com", port: 443))
        #expect(target(repository(.b2)) == Target(host: "api.backblazeb2.com", port: 443))
        #expect(target(repository(.azure) { $0.azureAccountName = "acme" }) == Target(host: "acme.blob.core.windows.net", port: 443))
        #expect(target(repository(.azure) { $0.azureAccountName = "acme" }, ["AZURE_ENDPOINT_SUFFIX": "core.chinacloudapi.cn"])
            == Target(host: "acme.blob.core.chinacloudapi.cn", port: 443))
        #expect(target(repository(.gcs)) == Target(host: "storage.googleapis.com", port: 443))
        // Nothing to ask first: the folder is the volume's to answer for, ssh
        // resolves an SFTP host itself, rclone's server is in rclone's config.
        #expect(target(repository(.local) { $0.localPath = "/Volumes/Archive" }) == nil)
        #expect(target(repository(.sftp) { $0.sftpHost = "nas" }) == nil)
        #expect(target(repository(.rclone) { $0.rcloneRemote = "nas:" }) == nil)
        // restic goes through a proxy, so a direct connection proves nothing.
        let rest = repository(.rest) { $0.restURL = "http://nas.local:8000/backups" }
        #expect(target(rest, ["HTTPS_PROXY": "http://proxy:3128"]) == nil)
        #expect(target(rest, ["http_proxy": "http://proxy:3128"]) == nil)
        #expect(target(rest, ["HTTPS_PROXY": ""]) == Target(host: "nas.local", port: 8000))
    }

    @Test("an SFTP host is probed where ssh would dial it — an alias's HostName and Port — and not through a jump host or a command")
    func sshTargets() {
        #expect(ServerProbe.sshTarget(fromConfig: "user tester\nhostname 192.168.1.10\nport 2222\n") == Target(host: "192.168.1.10", port: 2222))
        #expect(ServerProbe.sshTarget(fromConfig: "hostname nas\nport 22\nproxyjump none\n") == Target(host: "nas", port: 22))
        #expect(ServerProbe.sshTarget(fromConfig: "hostname nas\nport 22\nproxyjump bastion\n") == nil)
        #expect(ServerProbe.sshTarget(fromConfig: "hostname nas\nport 22\nproxycommand ssh -W %h:%p bastion\n") == nil)
        #expect(ServerProbe.sshTarget(fromConfig: "") == nil)
    }

    @Test("a connection's state says why a server cannot be reached; silence is the timeout's to name")
    func verdicts() {
        #expect(ServerProbe.verdict(for: .ready) == .reachable)
        #expect(ServerProbe.verdict(for: .preparing) == nil)
        #expect(ServerProbe.verdict(for: .setup) == nil)
        #expect(ServerProbe.verdict(for: .waiting(.posix(.ECONNREFUSED))) == .unreachable("connection refused"))
        #expect(ServerProbe.verdict(for: .failed(.posix(.EHOSTUNREACH))) == .unreachable("no route to the server"))
        #expect(ServerProbe.verdict(for: .waiting(.posix(.ENETUNREACH))) == .unreachable("no route to the server"))
        #expect(ServerProbe.verdict(for: .waiting(.posix(.ENETDOWN))) == .unreachable("this Mac has no network connection"))
        #expect(ServerProbe.verdict(for: .waiting(.dns(-65554))) == .unreachable("its name could not be found"))
        #expect(ServerProbe.timeoutWords(seconds: 10) == "it did not answer within 10 seconds")
    }

    @Test("a real connection attempt: a listening port answers; a closed one and a name that does not exist say why")
    func connect() async throws {
        let listening = try LocalPort.listening()
        defer { close(listening.socket) }
        #expect(await ServerProbe.connect(to: Target(host: "127.0.0.1", port: listening.port), timeout: 5) == .reachable)

        let closed = try LocalPort.listening()
        close(closed.socket)
        #expect(await ServerProbe.connect(to: Target(host: "127.0.0.1", port: closed.port), timeout: 5)
            == .unreachable("connection refused"))

        // .invalid never resolves (RFC 2606): NXDOMAIN, at once.
        #expect(await ServerProbe.connect(to: Target(host: "swiftrestic-absent.invalid", port: 443), timeout: 5)
            == .unreachable("its name could not be found"))
    }
}

/// A TCP socket listening on a free loopback port. The kernel completes a
/// connection's handshake into the accept queue, so it answers without an
/// accept loop.
private enum LocalPort {
    struct Error: Swift.Error { var call: String }

    static func listening() throws -> (socket: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error(call: "socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); throw Error(call: "bind/listen") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { close(fd); throw Error(call: "getsockname") }
        return (fd, UInt16(bigEndian: address.sin_port))
    }
}
