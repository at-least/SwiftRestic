import Foundation

/// Whether SwiftRestic holds Full Disk Access — and so the restic it runs:
/// macOS attributes the child process to the app that spawned it, so restic
/// inherits the app's grant or its lack. `unknown` is the probe finding
/// none of its files, and the state before it has run.
enum FullDiskAccessStatus: String, Codable, Sendable, Hashable {
    case granted, notGranted, unknown

    var displayName: String {
        switch self {
        case .granted: "Granted"
        case .notGranted: "Not granted"
        case .unknown: "Unknown"
        }
    }
}

/// Why restic could not read an item, from the words it used — and so what
/// the user can do about it. The stored line is `"<item>: <message>"`
/// (`ResticService.unreadableItems`), and restic ends the message with Go's
/// text for the errno, so the suffix is the diagnosis:
///
/// - EPERM, "operation not permitted": macOS's privacy protection said no
///   (a TCC denial reaches restic exactly so). Full Disk Access fixes it,
///   unless the item is protected by macOS itself.
/// - EACCES, "permission denied": the file's own permissions keep the
///   user's account out (a `chmod 000` file). Full Disk Access changes
///   nothing.
///
/// No list of protected paths: Full Disk Access covers every TCC file
/// category, Documents, Desktop and Downloads included, so a list would miss
/// real denials. The status at run time decides which advice is given.
enum ItemErrorDiagnosis {
    enum Kind: Equatable, Sendable {
        case blockedByMacOS, deniedByFilePermissions, other
    }

    /// Trailing whitespace is not part of the verdict: restic ends its
    /// extended-attribute errors with a newline, and the verdict holds
    /// whether or not `RunRecord.storedItemError` still carries it.
    static func kind(of line: String) -> Kind {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasSuffix(": operation not permitted") { return .blockedByMacOS }
        if line.hasSuffix(": permission denied") { return .deniedByFilePermissions }
        return .other
    }

    /// A run's unreadable items by cause. Stored on the record because the
    /// record keeps only `RunRecord.storedItemErrorLimit` lines, and a
    /// home-folder backup without the grant easily blocks more than that.
    struct Tally: Codable, Sendable, Hashable {
        var blockedByMacOS = 0
        var deniedByFilePermissions = 0

        init(blockedByMacOS: Int = 0, deniedByFilePermissions: Int = 0) {
            self.blockedByMacOS = blockedByMacOS
            self.deniedByFilePermissions = deniedByFilePermissions
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            blockedByMacOS = c.value(.blockedByMacOS, default: 0)
            deniedByFilePermissions = c.value(.deniedByFilePermissions, default: 0)
        }
    }

    static func tally(_ lines: some Sequence<String>) -> Tally {
        var tally = Tally()
        for line in lines {
            switch kind(of: line) {
            case .blockedByMacOS: tally.blockedByMacOS += 1
            case .deniedByFilePermissions: tally.deniedByFilePermissions += 1
            case .other: break
            }
        }
        return tally
    }

    /// What to tell the user, each with its item count.
    enum Hint: Equatable, Sendable {
        /// Blocked, and the grant is still missing.
        case grantFullDiskAccess(Int)
        /// Blocked while the grant was missing; it is there now.
        case retryNowGranted(Int)
        /// Blocked although the grant was there — a path macOS protects
        /// from everyone (SIP), or one restic reads beyond the file itself.
        case protectedEvenWithAccess(Int)
        case filePermissions(Int)
    }

    /// macOS's block first — the one with a fix to press — then the file
    /// permissions. The access state at the run decides between "grant it"
    /// and "macOS protects these anyway": without it, a run that hit EPERM
    /// with the grant already on would be told to back up again for nothing.
    /// An unstamped record reads as missing — a wrong "back up again"
    /// corrects itself on the next, stamped run, while a wrong "protected
    /// anyway" would drop what that run could read — and `unknown` too: the
    /// probe found nothing to say the grant is there.
    static func hints(tally: Tally, accessAtRun: FullDiskAccessStatus?, accessNow: FullDiskAccessStatus) -> [Hint] {
        var hints: [Hint] = []
        let blocked = tally.blockedByMacOS
        if blocked > 0 {
            if accessAtRun == .granted {
                hints.append(.protectedEvenWithAccess(blocked))
            } else if accessNow == .granted {
                hints.append(.retryNowGranted(blocked))
            } else {
                hints.append(.grantFullDiskAccess(blocked))
            }
        }
        if tally.deniedByFilePermissions > 0 {
            hints.append(.filePermissions(tally.deniedByFilePermissions))
        }
        return hints
    }

    /// A record without a stored tally is diagnosed from its unreadable
    /// items — never from the decoding and retention lines stored after
    /// them, which say nothing about the user's files.
    static func hints(for record: RunRecord, accessNow: FullDiskAccessStatus) -> [Hint] {
        hints(
            tally: record.itemErrorTally ?? tally(record.unreadableItems),
            accessAtRun: record.fullDiskAccessAtRun,
            accessNow: accessNow
        )
    }

    /// The sentence a finished run's announcements carry — the banner, the
    /// notification, the channels — or nil when there is nothing to advise.
    /// They go out as the run ends, so the state stamped on it is the state
    /// now.
    static func headline(for record: RunRecord) -> String? {
        hints(for: record, accessNow: record.fullDiskAccessAtRun ?? .unknown).first.map(headline)
    }

    /// The drawer's sentence.
    static func detail(_ hint: Hint) -> String {
        switch hint {
        case .grantFullDiskAccess(let count):
            "macOS blocked \(Format.plural(count, "item")) because SwiftRestic doesn't have Full Disk Access."
        case .retryNowGranted(let count):
            "macOS blocked \(Format.plural(count, "item")) because SwiftRestic didn't have Full Disk Access at the time. It has it now — back up again to include them."
        case .protectedEvenWithAccess(let count):
            "macOS blocked \(Format.plural(count, "item")) even though SwiftRestic had Full Disk Access — they are likely protected by macOS itself. Exclude them if this keeps happening."
        case .filePermissions(let count):
            "\(Format.plural(count, "item")) can't be read with your account's file permissions. Full Disk Access doesn't change that — fix them with Finder › Get Info, or exclude them."
        }
    }

    /// The banner's, the notification's and the channels' sentence.
    static func headline(_ hint: Hint) -> String {
        switch hint {
        case .grantFullDiskAccess(let count):
            "macOS blocked \(Format.plural(count, "item")): SwiftRestic needs Full Disk Access."
        case .retryNowGranted(let count):
            "macOS blocked \(Format.plural(count, "item")) while SwiftRestic lacked Full Disk Access."
        case .protectedEvenWithAccess(let count):
            "macOS blocked \(Format.plural(count, "item")) even with Full Disk Access on."
        case .filePermissions(let count):
            "\(Format.plural(count, "item")) can't be read with your account's file permissions."
        }
    }
}

/// Where a plan's sources reach data macOS keeps behind Full Disk Access,
/// for the plan editor's warning before a backup finds out the hard way.
///
/// The list is not Apple's and not exhaustive: the Photos library, Group
/// Containers and other apps' containers are left out because their
/// categories can put a permission prompt on screen. A source only under
/// those gets no warning here; the run's own hint still names the fix
/// afterwards.
enum ProtectedLocations {
    private static let homeSubtrees = [
        "Library/Mail",
        "Library/Messages",
        "Library/Safari",
        "Library/Cookies",
        "Library/HomeKit",
        "Library/Application Support/AddressBook",
        "Library/Application Support/CallHistoryDB",
        "Library/Application Support/com.apple.TCC",
        "Library/Suggestions",
        "Library/Metadata/CoreSpotlight",
        "Library/Containers/com.apple.stocks",
    ]
    private static let systemSubtrees = ["/Library/Application Support/com.apple.TCC"]

    /// True when the source lies inside a protected subtree, or holds one —
    /// `/`, `/Users`, the home folder, `~/Library`. Compared by path
    /// component and without case, as the default APFS volume does:
    /// `~/LibraryX` is not `~/Library`.
    static func needsFullDiskAccess(_ source: String, home: String) -> Bool {
        let path = components(source, home: home)
        let protected = homeSubtrees.map { components(home + "/" + $0, home: home) }
            + systemSubtrees.map { components($0, home: home) }
        return protected.contains { subtree in
            subtree.starts(with: path) || path.starts(with: subtree)
        }
    }

    static func firstProtectedSource(_ sources: [String], home: String) -> String? {
        sources.first { needsFullDiskAccess($0, home: home) }
    }

    /// `~` expanded against `home`, `.` and `..` resolved, lowercased. No
    /// symlinks are followed: a source is compared as the user wrote it.
    private static func components(_ path: String, home: String) -> [String] {
        let expanded = path == "~" || path.hasPrefix("~/") ? home + path.dropFirst() : path
        var parts: [String] = []
        for part in expanded.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part.lowercased())
            }
        }
        return parts
    }
}
