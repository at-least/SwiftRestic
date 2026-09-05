import Foundation

/// A restic repository the app knows about.
///
/// Only non-secret configuration lives here — this struct is what gets written to
/// `config.json`. The repository password and any provider secret key are held in
/// the login Keychain and fetched at spawn time; see `KeychainStore`.
struct Repository: Identifiable, Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case local, sftp, s3, b2, azure, gcs, rest, rclone
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .local: "Local folder or disk"
            case .sftp: "SFTP"
            case .s3: "S3-compatible"
            case .b2: "Backblaze B2"
            case .azure: "Azure Blob Storage"
            case .gcs: "Google Cloud Storage"
            case .rest: "REST server"
            case .rclone: "rclone remote"
            }
        }

        var symbolName: String {
            switch self {
            case .local: "externaldrive"
            case .sftp: "terminal"
            case .s3: "cloud"
            case .b2: "flame"
            case .azure: "cube"
            case .gcs: "cloud.fill"
            case .rest: "network"
            case .rclone: "shippingbox"
            }
        }
    }

    var id: UUID = UUID()
    var name: String = ""
    var kind: Kind = .local
    var createdAt: Date = .now

    // local
    var localPath: String = ""

    // sftp
    var sftpUser: String = ""
    var sftpHost: String = ""
    var sftpPath: String = ""

    // s3 / minio / wasabi
    var s3Endpoint: String = "s3.amazonaws.com"
    var s3Bucket: String = ""
    var s3Prefix: String = ""
    var s3AccessKeyID: String = ""

    // b2
    var b2Bucket: String = ""
    var b2Prefix: String = ""
    var b2AccountID: String = ""

    // azure
    var azureContainer: String = ""
    var azurePrefix: String = ""
    var azureAccountName: String = ""

    // gcs
    var gcsBucket: String = ""
    var gcsPrefix: String = ""
    var gcsProjectID: String = ""
    /// Path to the service-account JSON file. A path, not a secret, so it is
    /// stored here rather than in the Keychain.
    var gcsCredentialsPath: String = ""

    // rest
    var restURL: String = ""

    // rclone
    var rcloneRemote: String = ""
    var rclonePath: String = ""

    /// Extra `KEY=value` pairs handed to the restic child process verbatim.
    var extraEnvironment: [String: String] = [:]

    /// Periodic `check` and `prune` for this repository.
    var maintenance = MaintenancePolicy()
    /// Shell commands run around this repository's check and prune.
    var hooks: [BackupHook] = []

    // MARK: - Decoding

    /// Written by hand so a configuration saved by an older build still loads;
    /// see `KeyedDecodingContainer.value(_:default:)`.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        name = c.value(.name, default: "")
        kind = c.value(.kind, default: .local)
        createdAt = c.value(.createdAt, default: .now)
        localPath = c.value(.localPath, default: "")
        sftpUser = c.value(.sftpUser, default: "")
        sftpHost = c.value(.sftpHost, default: "")
        sftpPath = c.value(.sftpPath, default: "")
        s3Endpoint = c.value(.s3Endpoint, default: "s3.amazonaws.com")
        s3Bucket = c.value(.s3Bucket, default: "")
        s3Prefix = c.value(.s3Prefix, default: "")
        s3AccessKeyID = c.value(.s3AccessKeyID, default: "")
        b2Bucket = c.value(.b2Bucket, default: "")
        b2Prefix = c.value(.b2Prefix, default: "")
        b2AccountID = c.value(.b2AccountID, default: "")
        azureContainer = c.value(.azureContainer, default: "")
        azurePrefix = c.value(.azurePrefix, default: "")
        azureAccountName = c.value(.azureAccountName, default: "")
        gcsBucket = c.value(.gcsBucket, default: "")
        gcsPrefix = c.value(.gcsPrefix, default: "")
        gcsProjectID = c.value(.gcsProjectID, default: "")
        gcsCredentialsPath = c.value(.gcsCredentialsPath, default: "")
        restURL = c.value(.restURL, default: "")
        rcloneRemote = c.value(.rcloneRemote, default: "")
        rclonePath = c.value(.rclonePath, default: "")
        extraEnvironment = c.value(.extraEnvironment, default: [:])
        maintenance = c.value(.maintenance, default: MaintenancePolicy())
        hooks = c.value(.hooks, default: [])
    }

    init() {}

    /// The value of `RESTIC_REPOSITORY` for this repository.
    var resticRepositoryString: String {
        switch kind {
        case .local:
            return localPath
        case .sftp:
            let user = sftpUser.isEmpty ? "" : "\(sftpUser)@"
            return "sftp:\(user)\(sftpHost):\(sftpPath)"
        case .s3:
            let endpoint = s3Endpoint.isEmpty ? "s3.amazonaws.com" : s3Endpoint
            let suffix = s3Prefix.isEmpty ? "" : "/\(s3Prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
            return "s3:\(endpoint)/\(s3Bucket)\(suffix)"
        case .b2:
            let suffix = b2Prefix.isEmpty ? "" : ":\(b2Prefix)"
            return "b2:\(b2Bucket)\(suffix)"
        case .azure:
            let suffix = azurePrefix.isEmpty ? "" : ":/\(Self.trimSlashes(azurePrefix))"
            return "azure:\(azureContainer)\(suffix)"
        case .gcs:
            let suffix = gcsPrefix.isEmpty ? "" : ":/\(Self.trimSlashes(gcsPrefix))"
            return "gs:\(gcsBucket)\(suffix)"
        case .rest:
            return restURL.hasPrefix("rest:") ? restURL : "rest:\(restURL)"
        case .rclone:
            let remote = rcloneRemote.hasSuffix(":") ? String(rcloneRemote.dropLast()) : rcloneRemote
            return "rclone:\(remote):\(Self.trimSlashes(rclonePath))"
        }
    }

    private static func trimSlashes(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Human-readable location shown in the sidebar and detail header.
    var displayLocation: String {
        kind == .local ? (localPath as NSString).abbreviatingWithTildeInPath : resticRepositoryString
    }

    /// Whether the required non-secret fields are filled in.
    var isConfigurationComplete: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .local: return !localPath.isEmpty
        case .sftp: return !sftpHost.isEmpty && !sftpPath.isEmpty
        case .s3: return !s3Bucket.isEmpty && !s3AccessKeyID.isEmpty
        case .b2: return !b2Bucket.isEmpty && !b2AccountID.isEmpty
        case .azure: return !azureContainer.isEmpty && !azureAccountName.isEmpty
        case .gcs: return !gcsBucket.isEmpty && !gcsCredentialsPath.isEmpty
        case .rest: return !restURL.isEmpty
        case .rclone: return !rcloneRemote.isEmpty
        }
    }

    /// The label the provider secret is shown under in the UI (`nil` when the
    /// backend needs no second credential).
    var secretFieldLabel: String? {
        switch kind {
        case .local, .rest, .gcs, .rclone: nil
        case .sftp: "SSH is authenticated with your keys — see the note below"
        case .s3: "Secret access key"
        case .b2: "Application key"
        case .azure: "Account key"
        }
    }

    /// Environment variables carrying the provider secret, if any.
    func credentialEnvironment(secret: String?) -> [String: String] {
        var env: [String: String] = [:]
        switch kind {
        case .s3:
            env["AWS_ACCESS_KEY_ID"] = s3AccessKeyID
            if let secret { env["AWS_SECRET_ACCESS_KEY"] = secret }
        case .b2:
            env["B2_ACCOUNT_ID"] = b2AccountID
            if let secret { env["B2_ACCOUNT_KEY"] = secret }
        case .azure:
            env["AZURE_ACCOUNT_NAME"] = azureAccountName
            if let secret { env["AZURE_ACCOUNT_KEY"] = secret }
        case .gcs:
            if !gcsProjectID.isEmpty { env["GOOGLE_PROJECT_ID"] = gcsProjectID }
            // restic reads the service-account JSON from this path itself.
            env["GOOGLE_APPLICATION_CREDENTIALS"] = ResticService.expandTilde(gcsCredentialsPath)
        case .local, .sftp, .rest, .rclone:
            break
        }
        return env
    }

    /// restic shells out to `rclone` for this backend, so the helper has to be
    /// findable in the child's PATH.
    var requiresRcloneBinary: Bool { kind == .rclone }
}
