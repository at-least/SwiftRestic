import Foundation

/// A single NDJSON line emitted by `restic --json`.
///
/// restic's JSON stream is a union discriminated only by `message_type`, and the
/// same discriminator is reused across commands with different payloads (a
/// `status` line from `backup` carries `files_done`, one from `restore` carries
/// `files_restored`). We therefore decode into permissive union structs that try
/// both spellings, instead of demanding a per-command decoder.
enum ResticMessage: Sendable, Equatable {
    case status(ResticStatus)
    case summary(ResticSummary)
    case verboseStatus(ResticVerboseStatus)
    case error(ResticErrorMessage)
    case exitError(ResticExitError)
    case initialized(ResticInitialized)
    case snapshot(Snapshot)
    case node(SnapshotNode)
    case change(ResticDiffChange)
    case statistics(ResticDiffStatistics)
    /// A line we could recognise as JSON but not map to a known `message_type`.
    case unknown(type: String)
}

// MARK: - Payloads

/// Periodic progress line (`backup` and `restore` both emit `message_type: status`).
struct ResticStatus: Sendable, Equatable {
    var percentDone: Double
    var totalFiles: Int?
    var filesDone: Int?
    var totalBytes: Int64?
    var bytesDone: Int64?
    var secondsElapsed: Int?
    var secondsRemaining: Int?
    var errorCount: Int?
    var currentFiles: [String]
    // restore only
    var filesSkipped: Int?
    var filesDeleted: Int?
    var bytesSkipped: Int64?

    var fractionComplete: Double { min(max(percentDone, 0), 1) }
}

extension ResticStatus: Decodable {
    private enum CodingKeys: String, CodingKey {
        case percentDone = "percent_done"
        case totalFiles = "total_files"
        case filesDone = "files_done"
        case filesRestored = "files_restored"
        case totalBytes = "total_bytes"
        case bytesDone = "bytes_done"
        case bytesRestored = "bytes_restored"
        case secondsElapsed = "seconds_elapsed"
        case secondsRemaining = "seconds_remaining"
        case errorCount = "error_count"
        case currentFiles = "current_files"
        case filesSkipped = "files_skipped"
        case filesDeleted = "files_deleted"
        case bytesSkipped = "bytes_skipped"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        percentDone = try c.decodeIfPresent(Double.self, forKey: .percentDone) ?? 0
        totalFiles = try c.decodeIfPresent(Int.self, forKey: .totalFiles)
        filesDone = try c.decodeIfPresent(Int.self, forKey: .filesDone)
            ?? c.decodeIfPresent(Int.self, forKey: .filesRestored)
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes)
        bytesDone = try c.decodeIfPresent(Int64.self, forKey: .bytesDone)
            ?? c.decodeIfPresent(Int64.self, forKey: .bytesRestored)
        secondsElapsed = try c.decodeIfPresent(Int.self, forKey: .secondsElapsed)
        secondsRemaining = try c.decodeIfPresent(Int.self, forKey: .secondsRemaining)
        errorCount = try c.decodeIfPresent(Int.self, forKey: .errorCount)
        currentFiles = try c.decodeIfPresent([String].self, forKey: .currentFiles) ?? []
        filesSkipped = try c.decodeIfPresent(Int.self, forKey: .filesSkipped)
        filesDeleted = try c.decodeIfPresent(Int.self, forKey: .filesDeleted)
        bytesSkipped = try c.decodeIfPresent(Int64.self, forKey: .bytesSkipped)
    }
}

/// Terminal line of a command. `backup`, `restore` and `check` all use
/// `message_type: summary` with disjoint field sets, so every field is optional.
struct ResticSummary: Sendable, Equatable, Decodable {
    // backup
    var filesNew: Int?
    var filesChanged: Int?
    var filesUnmodified: Int?
    var dirsNew: Int?
    var dirsChanged: Int?
    var dirsUnmodified: Int?
    var dataAdded: Int64?
    var dataAddedPacked: Int64?
    var totalFilesProcessed: Int?
    var totalBytesProcessed: Int64?
    var totalDuration: Double?
    var snapshotID: String?
    var dryRun: Bool?
    var dataBlobs: Int?
    var treeBlobs: Int?
    var backupStart: Date?
    var backupEnd: Date?
    // restore
    var totalFiles: Int?
    var filesRestored: Int?
    var totalBytes: Int64?
    var bytesRestored: Int64?
    var filesSkipped: Int?
    var filesDeleted: Int?
    var bytesSkipped: Int64?
    var secondsElapsed: Int?
    // check
    var numErrors: Int?
    var suggestRepairIndex: Bool?
    var suggestPrune: Bool?

    private enum CodingKeys: String, CodingKey {
        case filesNew = "files_new"
        case filesChanged = "files_changed"
        case filesUnmodified = "files_unmodified"
        case dirsNew = "dirs_new"
        case dirsChanged = "dirs_changed"
        case dirsUnmodified = "dirs_unmodified"
        case dataAdded = "data_added"
        case dataAddedPacked = "data_added_packed"
        case totalFilesProcessed = "total_files_processed"
        case totalBytesProcessed = "total_bytes_processed"
        case totalDuration = "total_duration"
        case snapshotID = "snapshot_id"
        case dryRun = "dry_run"
        case dataBlobs = "data_blobs"
        case treeBlobs = "tree_blobs"
        case backupStart = "backup_start"
        case backupEnd = "backup_end"
        case totalFiles = "total_files"
        case filesRestored = "files_restored"
        case totalBytes = "total_bytes"
        case bytesRestored = "bytes_restored"
        case filesSkipped = "files_skipped"
        case filesDeleted = "files_deleted"
        case bytesSkipped = "bytes_skipped"
        case secondsElapsed = "seconds_elapsed"
        case numErrors = "num_errors"
        case suggestRepairIndex = "suggest_repair_index"
        case suggestPrune = "suggest_prune"
    }
}

/// Per-item line emitted by `backup --verbose --json`.
struct ResticVerboseStatus: Sendable, Equatable, Decodable {
    var action: String
    var item: String
    var duration: Double?
    var dataSize: Int64?
    var metadataSize: Int64?
    /// `restore --verbose=2` uses `size` where `backup` uses `data_size`.
    var size: Int64?

    private enum CodingKeys: String, CodingKey {
        case action, item, duration, size
        case dataSize = "data_size"
        case metadataSize = "metadata_size"
    }
}

/// A non-fatal error line.
///
/// `backup` and `restore` nest the text under `error.message` with `during` and
/// `item` alongside it; `check` emits a flat `message` instead. Accept both, or
/// every `check` error would be silently dropped as an unknown message type.
struct ResticErrorMessage: Sendable, Equatable, Decodable {
    private struct Payload: Sendable, Equatable, Decodable { var message: String }

    var message: String
    var during: String?
    var item: String?

    private enum CodingKeys: String, CodingKey { case error, message, during, item }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try c.decodeIfPresent(Payload.self, forKey: .error) {
            message = nested.message
        } else {
            message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        }
        during = try c.decodeIfPresent(String.self, forKey: .during)
        item = try c.decodeIfPresent(String.self, forKey: .item)
    }
}

/// Fatal error line: `{"message_type":"exit_error","code":12,"message":"..."}`.
struct ResticExitError: Sendable, Equatable, Decodable {
    var code: Int32
    var message: String
}

/// Emitted by `restic init --json`.
struct ResticInitialized: Sendable, Equatable, Decodable {
    var id: String
    var repository: String
}

/// One `message_type: change` line from `restic diff --json`.
///
/// The modifier is a string of flags, not a single letter: `+` added, `-`
/// removed, `M` content changed, `T` type changed, `U` metadata changed (only
/// with `--metadata`) and `?` bitrot. restic concatenates them when more than
/// one applies — a file that became a symlink and lost its mode bits arrives as
/// `"TU"` — so the raw string is kept and the categories are derived from it.
struct ResticDiffChange: Sendable, Equatable, Hashable, Identifiable, Decodable {
    enum Category: String, Sendable, CaseIterable, Identifiable {
        case added, removed, modified, metadataOnly

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .added: "Added"
            case .removed: "Removed"
            case .modified: "Modified"
            case .metadataOnly: "Metadata"
            }
        }
    }

    var path: String
    var modifier: String

    var id: String { path }

    /// restic marks directories with a trailing slash.
    var isDirectory: Bool { path.hasSuffix("/") }

    var name: String {
        let trimmed = isDirectory ? String(path.dropLast()) : path
        let last = (trimmed as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    var category: Category {
        if modifier.contains("+") { return .added }
        if modifier.contains("-") { return .removed }
        if modifier.contains("M") || modifier.contains("T") || modifier.contains("?") { return .modified }
        return .metadataOnly
    }

    /// A short phrase for the row's tooltip.
    var explanation: String {
        var parts: [String] = []
        if modifier.contains("+") { parts.append("added") }
        if modifier.contains("-") { parts.append("removed") }
        if modifier.contains("M") { parts.append("content changed") }
        if modifier.contains("T") { parts.append("type changed") }
        if modifier.contains("U") { parts.append("metadata changed") }
        if modifier.contains("?") { parts.append("bitrot detected") }
        return parts.isEmpty ? modifier : parts.joined(separator: ", ")
    }
}

/// The closing `message_type: statistics` line of `restic diff --json`.
struct ResticDiffStatistics: Sendable, Equatable, Decodable {
    struct Counts: Sendable, Equatable, Decodable {
        var files: Int = 0
        var dirs: Int = 0
        var others: Int = 0
        var dataBlobs: Int = 0
        var treeBlobs: Int = 0
        var bytes: Int64 = 0

        private enum CodingKeys: String, CodingKey {
            case files, dirs, others, bytes
            case dataBlobs = "data_blobs"
            case treeBlobs = "tree_blobs"
        }

        init() {}

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            files = try c.decodeIfPresent(Int.self, forKey: .files) ?? 0
            dirs = try c.decodeIfPresent(Int.self, forKey: .dirs) ?? 0
            others = try c.decodeIfPresent(Int.self, forKey: .others) ?? 0
            dataBlobs = try c.decodeIfPresent(Int.self, forKey: .dataBlobs) ?? 0
            treeBlobs = try c.decodeIfPresent(Int.self, forKey: .treeBlobs) ?? 0
            bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        }
    }

    /// Whatever ID was passed on the command line — a short ID stays short — so
    /// never match on these; use the IDs you asked for.
    var sourceSnapshot: String
    var targetSnapshot: String
    var changedFiles: Int
    var added: Counts
    var removed: Counts

    private enum CodingKeys: String, CodingKey {
        case added, removed
        case sourceSnapshot = "source_snapshot"
        case targetSnapshot = "target_snapshot"
        case changedFiles = "changed_files"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceSnapshot = try c.decodeIfPresent(String.self, forKey: .sourceSnapshot) ?? ""
        targetSnapshot = try c.decodeIfPresent(String.self, forKey: .targetSnapshot) ?? ""
        changedFiles = try c.decodeIfPresent(Int.self, forKey: .changedFiles) ?? 0
        added = try c.decodeIfPresent(Counts.self, forKey: .added) ?? Counts()
        removed = try c.decodeIfPresent(Counts.self, forKey: .removed) ?? Counts()
    }
}

// MARK: - Line decoding

enum ResticMessageDecoder {
    /// Decoder configured for restic's RFC3339-with-fractional-seconds timestamps.
    static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = ResticDateFormat.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Unrecognised restic timestamp: \(raw)"
                )
            }
            return date
        }
        return d
    }()

    /// Decodes one NDJSON line. Returns `nil` for blank lines or lines that are
    /// not JSON objects at all (restic occasionally writes plain text to stdout).
    static func decode(line: String) -> ResticMessage? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        guard let probe = try? jsonDecoder.decode(MessageTypeProbe.self, from: data) else { return nil }

        do {
            switch probe.messageType {
            case "status":
                return .status(try jsonDecoder.decode(ResticStatus.self, from: data))
            case "summary":
                return .summary(try jsonDecoder.decode(ResticSummary.self, from: data))
            case "verbose_status":
                return .verboseStatus(try jsonDecoder.decode(ResticVerboseStatus.self, from: data))
            case "error":
                return .error(try jsonDecoder.decode(ResticErrorMessage.self, from: data))
            case "exit_error":
                return .exitError(try jsonDecoder.decode(ResticExitError.self, from: data))
            case "initialized":
                return .initialized(try jsonDecoder.decode(ResticInitialized.self, from: data))
            case "snapshot":
                return .snapshot(try jsonDecoder.decode(Snapshot.self, from: data))
            case "node":
                return .node(try jsonDecoder.decode(SnapshotNode.self, from: data))
            case "change":
                return .change(try jsonDecoder.decode(ResticDiffChange.self, from: data))
            case "statistics":
                return .statistics(try jsonDecoder.decode(ResticDiffStatistics.self, from: data))
            default:
                return .unknown(type: probe.messageType)
            }
        } catch {
            return .unknown(type: probe.messageType)
        }
    }

    private struct MessageTypeProbe: Decodable {
        var messageType: String
        private enum CodingKeys: String, CodingKey { case messageType = "message_type" }
    }
}

/// restic emits RFC3339 timestamps whose fractional part varies in length, which
/// `ISO8601DateFormatter` handles inconsistently. Parse both shapes explicitly.
enum ResticDateFormat {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let lock = NSLock()

    static func parse(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return withFraction.date(from: string) ?? plain.date(from: string)
    }
}
