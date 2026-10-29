import Foundation

/// Finds the `restic` executable.
///
/// A GUI app launched from Finder inherits a minimal `PATH` that contains neither
/// `/opt/homebrew/bin` nor `/usr/local/bin`, so looking restic up through the
/// environment is unreliable. We probe the well-known locations directly and let
/// the user override the result in Settings.
struct ResticBinary: Sendable {
    /// Searched in order; first hit wins.
    static let searchPaths: [String] = [
        "/opt/homebrew/bin/restic",
        "/usr/local/bin/restic",
        "/opt/local/bin/restic",
        "/usr/bin/restic",
        "/run/current-system/sw/bin/restic",
    ]

    var url: URL

    /// Whether the restic at `path` is Homebrew's: Homebrew links it from
    /// its Cellar, so the link's target says, wherever the link is.
    static func isHomebrews(_ path: String) -> Bool {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path.contains("/Cellar/restic/")
    }

    /// Resolves the binary, preferring an explicit user override.
    static func locate(userOverride: String?) throws -> ResticBinary {
        if let userOverride, !userOverride.trimmingCharacters(in: .whitespaces).isEmpty {
            let url = URL(fileURLWithPath: userOverride)
            // A missing file is a different sentence than a file the user
            // cannot execute: "not executable" sends someone hunting through
            // permissions for what is really a typo.
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ResticError.binaryNotFound(searched: [url.path])
            }
            guard Self.isExecutableFile(atPath: url.path) else {
                throw ResticError.binaryNotExecutable(path: url.path)
            }
            return ResticBinary(url: url)
        }

        if let candidate = searchPaths.first(where: { Self.isExecutableFile(atPath: $0) }) {
            return ResticBinary(url: URL(fileURLWithPath: candidate))
        }

        // Last resort: whatever PATH we did inherit.
        if let fromPath = Self.onInheritedPath("restic") {
            return ResticBinary(url: URL(fileURLWithPath: fromPath))
        }
        throw ResticError.binaryNotFound(searched: searchPaths)
    }

    /// An executable *file*. `FileManager.isExecutableFile` alone also accepts
    /// directories — 0755 has the execute bit — and spawning one fails later
    /// with an opaque launch error.
    static func isExecutableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// Where a helper restic shells out to is looked for, in order, before
    /// the inherited PATH; restic's PATH must hold each, or a helper found
    /// here is one restic cannot run (ResticCoreTests pins it).
    static let helperDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    /// Looks for a helper binary restic shells out to (currently only `rclone`).
    ///
    /// Without this the failure surfaces as an opaque "command not found" buried
    /// in restic's stderr.
    static func locateHelper(named name: String) -> URL? {
        for directory in helperDirectories {
            let candidate = "\(directory)/\(name)"
            if Self.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return onInheritedPath(name).map { URL(fileURLWithPath: $0) }
    }

    private static func onInheritedPath(_ name: String) -> String? {
        guard let pathValue = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path
            if Self.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// Where the app's search for restic stands.
enum ResticSearch {
    /// Before the first search has answered.
    case searching
    /// The restic in use, and `restic version`'s answer.
    case found(ResticBinary, version: String)
    /// Why no restic can run, and its words for Settings, worked out once:
    /// a too-old restic's advice looks on disk (`ResticBinary.isHomebrews`).
    case refused(any Error, problem: String)
}

/// The version parts of `restic version`'s first line, for the minimum the
/// app checks at launch rather than displays.
struct ResticVersion: Comparable, Sendable {
    var major: Int
    var minor: Int
    var patch: Int

    /// The oldest restic the app runs; `resolveBinary` refuses anything
    /// below it. CI's oldest-supported job runs this version
    /// (ResticVersionTests.ciRunsTheMinimum).
    static let minimumSupported = ResticVersion(major: 0, minor: 19, patch: 1)

    var isSupported: Bool { self >= Self.minimumSupported }

    /// "0.19.1".
    var dotted: String { "\(major).\(minor).\(patch)" }

    static func < (a: ResticVersion, b: ResticVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

// In an extension, so the struct keeps its memberwise init.
extension ResticVersion {
    /// Parses "restic 0.19.1 compiled with go1.26.5 darwin/arm64" — the
    /// whole first line is accepted so callers can hand over `version()`'s
    /// output as-is. `nil` when no dotted triple follows the name.
    ///
    /// A suffix rides on the patch: the patch is the digits before the
    /// first "-" or "+". restic names a build from source after release X
    /// "X-dev" (its VERSION file), so "0.19.1-dev" is 0.19.1 or later and
    /// reads as 0.19.1, and "0.19.0-dev", built before 0.19.1, reads as
    /// 0.19.0.
    init?(parsing output: String) {
        let firstLine = (output.split(separator: "\n").first.map(String.init) ?? output)
            .trimmingCharacters(in: .whitespaces)
        guard let range = firstLine.range(of: "restic ") else { return nil }
        let token = firstLine[range.upperBound...]
            .split(separator: " ").first.map(String.init) ?? ""
        let components = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 3,
              let major = Int(components[0]),
              let minor = Int(components[1])
        else { return nil }
        let patchDigits = components[2]
            .split(whereSeparator: { $0 == "-" || $0 == "+" })
            .first.map(String.init) ?? ""
        // No isNumber check beside Int: the split above removed every sign,
        // and Int accepts only ASCII digits, so Int alone rejects exactly
        // what the extra clause would.
        guard let patch = Int(patchDigits) else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }
}
