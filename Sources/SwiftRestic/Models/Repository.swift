import Foundation

/// Only non-secret configuration lives here — this struct is what gets written to
/// `config.json`. The repository password and any provider secret key are held in
/// the login Keychain and fetched at spawn time; see `KeychainStore`.
struct Repository: Identifiable, Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case local, sftp, s3
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .local: "Local folder or disk"
            case .sftp: "SFTP"
            case .s3: "S3-compatible"
            }
        }

        var symbolName: String {
            switch self {
            case .local: "externaldrive"
            case .sftp: "terminal"
            case .s3: "cloud"
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind = .local
    var createdAt: Date = .now

    var localPath: String = ""

    /// The Server field as typed: `nas.local`, `backup@nas.local` or
    /// `backup@nas.local:2222` (`sftpHostParts`).
    var sftpHost: String = ""
    var sftpPath: String = ""

    var s3Endpoint: String = "s3.amazonaws.com"
    /// The Bucket field as typed: `my-bucket`, or `my-bucket/mac` for a
    /// folder in it.
    var s3Bucket: String = ""
    var s3AccessKeyID: String = ""

    /// Extra `KEY=value` pairs handed to the restic child process verbatim.
    /// Not in `config.json` (`CodingKeys`): only tests set it, to steer the
    /// stub restic (`AppModel.init`'s `repositoryEnvironment`).
    var extraEnvironment: [String: String] = [:]

    var maintenance = MaintenancePolicy()

    /// restic's own ID for what is at this location (`restic cat config`),
    /// recorded at the first listing that reads it: how Locate knows a moved
    /// folder is this repository and not another. Nil until then.
    var resticID: String?

    private enum CodingKeys: String, CodingKey {
        case id, kind, createdAt, localPath, sftpHost, sftpPath
        case s3Endpoint, s3Bucket, s3AccessKeyID, maintenance, resticID
    }

    /// Written by hand so a field that does not read falls back with a note;
    /// see `KeyedDecodingContainer.value(_:default:)`.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        kind = c.value(.kind, default: .local)
        createdAt = c.value(.createdAt, default: .now)
        localPath = c.value(.localPath, default: "")
        sftpHost = c.value(.sftpHost, default: "")
        sftpPath = c.value(.sftpPath, default: "")
        s3Endpoint = c.value(.s3Endpoint, default: "s3.amazonaws.com")
        s3Bucket = c.value(.s3Bucket, default: "")
        s3AccessKeyID = c.value(.s3AccessKeyID, default: "")
        maintenance = c.value(.maintenance, default: MaintenancePolicy())
        resticID = c.optional(.resticID)
    }

    init() {}

    /// ssh's `user@host`, or the host alone without a user.
    private var sftpUserHost: String {
        sftpUser.isEmpty ? sftpHostName : "\(sftpUser)@\(sftpHostName)"
    }

    /// The value of `RESTIC_REPOSITORY` for this repository.
    var resticRepositoryString: String {
        switch kind {
        case .local:
            // restic is spawned without a shell, so a literal `~` would
            // resolve against `/`; the shell's expansion happens here, as
            // for plan sources and exclude patterns.
            return resolvedLocalPath
        case .sftp:
            guard let port = sftpCustomPort else {
                return "sftp:\(sftpUserHost):\(sftpPath)"
            }
            // Only restic's URL form carries a port. Its first slash ends the
            // connection settings, so an absolute path keeps its own slash
            // after it. restic 0.19.1 reads this form as a URL: the path is
            // percent-encoded, or a `#` in it would cut it short.
            let user = sftpUser.isEmpty ? "" : "\(Self.percentEncoded(sftpUser, .urlUserAllowed))@"
            return "sftp://\(user)\(sftpHostName):\(port)/\(Self.percentEncoded(sftpPath, .urlPathAllowed))"
        case .s3:
            let endpoint = s3Endpoint.isEmpty ? "s3.amazonaws.com" : s3Endpoint
            return "s3:\(endpoint)/\(Self.trimSlashes(s3Bucket))"
        }
    }

    private static func trimSlashes(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Fails only on malformed UTF-16, which a Swift `String` never holds.
    private static func percentEncoded(_ value: String, _ allowed: CharacterSet) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed)!
    }

    /// The Server field split into ssh's user, host and port: the user ends
    /// at the last `@`, the host at the next colon. restic's `sftp:` form
    /// cuts the host at a colon too, so a port left in the host would start
    /// the path and ssh would dial 22.
    private var sftpHostParts: (user: String, name: String, port: String) {
        var user = ""
        var rest = sftpHost
        if let at = sftpHost.lastIndex(of: "@") {
            user = String(sftpHost[..<at])
            rest = String(sftpHost[sftpHost.index(after: at)...])
        }
        let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 ? (user, String(parts[0]), String(parts[1])) : (user, rest, "")
    }

    /// ssh's user, empty for ssh's own choice (~/.ssh/config, else the
    /// Mac's user name).
    var sftpUser: String { sftpHostParts.user }

    var sftpHostName: String { sftpHostParts.name }

    /// The port typed after the host; empty for none. The editor refuses
    /// one that is not a port.
    var sftpPortText: String { sftpHostParts.port }

    /// The SFTP port when it is not ssh's own: nil for none and for 22, so
    /// a repository without one keeps the `sftp:` form, which reads
    /// ~/.ssh/config's Port.
    private var sftpCustomPort: Int? {
        guard let port = Int(sftpPortText), port != 22 else { return nil }
        return port
    }

    var driveVolumeName: String? {
        kind == .local ? VolumePresence.volumeName(of: resolvedLocalPath) : nil
    }

    /// Every kind but a local folder, and a local folder on a saved network
    /// share.
    func usesNetwork(shares: [NetworkShare]) -> Bool {
        guard kind == .local else { return true }
        return driveVolumeName.map { volume in shares.contains { $0.volumeName == volume } } ?? false
    }

    /// The local path with `~` expanded — the form every file-system
    /// consumer (restic, the volume read) needs; `localPath` keeps the form
    /// the user typed.
    var resolvedLocalPath: String {
        ResticService.expandTilde(localPath)
    }

    var isConfigurationComplete: Bool {
        switch kind {
        case .local: return !localPath.isEmpty
        case .sftp: return !sftpHostName.isEmpty && !sftpPath.isEmpty
        case .s3: return !s3Bucket.isEmpty && !s3AccessKeyID.isEmpty
        }
    }

    /// What every surface calls the repository — it has no name of its
    /// own: where it is, said short. A local folder on a drive is the
    /// drive's name (`VolumePresence.volumeName`, the name the drive-away
    /// and drive-full words use). When another of
    /// `repositories` would read the same, each reads as its location
    /// (`displayLocation`).
    func label(among repositories: [Repository]) -> String {
        let short = shortLabel
        guard !short.isEmpty else { return "Untitled Location" }
        let twin = repositories.contains { $0.id != id && $0.shortLabel == short }
        return twin ? displayLocation : short
    }

    /// The location in the reader's words, not restic's repository string:
    /// the repository page's Location, and a twin's label, which every
    /// notification and webhook says.
    var displayLocation: String {
        switch kind {
        case .local:
            return (resolvedLocalPath as NSString).abbreviatingWithTildeInPath
        case .sftp:
            return "\(sftpUserHost):\(sftpPath)"
        case .s3:
            let endpoint = s3Endpoint.isEmpty ? "s3.amazonaws.com" : s3Endpoint
            return "\(Self.trimSlashes(s3Bucket)) on \(endpoint)"
        }
    }

    private var shortLabel: String {
        switch kind {
        case .local:
            let path = resolvedLocalPath
            guard !path.isEmpty else { return "" }
            return VolumePresence.volumeName(of: path) ?? (path as NSString).lastPathComponent
        case .sftp: return sftpHostName
        case .s3: return String(Self.trimSlashes(s3Bucket).prefix { $0 != "/" })
        }
    }

    /// The stored repository wins over an editor's draft for what the model
    /// writes after each check and cleanup — the stamps and the check's next
    /// slice — the same rule as `BackupPlan.merging(draft:)`: the editor
    /// holds its older copy, and a check that finished mid-edit must not
    /// look like it never happened, or the scheduler repeats it.
    func merging(draft: Repository) -> Repository {
        var merged = draft
        merged.maintenance.lastCheckAt = maintenance.lastCheckAt
        merged.maintenance.lastPruneAt = maintenance.lastPruneAt
        merged.maintenance.nextCheckDataSlice = maintenance.nextCheckDataSlice
        merged.resticID = resticID
        return merged
    }

    var secretFieldLabel: String? {
        switch kind {
        case .local, .sftp: nil
        case .s3: "Secret access key"
        }
    }

    func credentialEnvironment(secret: String?) -> [String: String] {
        var env: [String: String] = [:]
        switch kind {
        case .s3:
            env["AWS_ACCESS_KEY_ID"] = s3AccessKeyID
            if let secret { env["AWS_SECRET_ACCESS_KEY"] = secret }
        case .local, .sftp:
            break
        }
        return env
    }
}
