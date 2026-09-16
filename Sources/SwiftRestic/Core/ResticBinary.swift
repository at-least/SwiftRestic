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
    var version: String?

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

        var searched: [String] = []
        for candidate in searchPaths {
            searched.append(candidate)
            if Self.isExecutableFile(atPath: candidate) {
                return ResticBinary(url: URL(fileURLWithPath: candidate))
            }
        }

        // Last resort: whatever PATH we did inherit.
        if let fromPath = Self.lookupOnPath() {
            return ResticBinary(url: URL(fileURLWithPath: fromPath))
        }
        throw ResticError.binaryNotFound(searched: searched)
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

    /// Looks for a helper binary restic shells out to (currently only `rclone`).
    ///
    /// Without this the failure surfaces as an opaque "command not found" buried
    /// in restic's stderr.
    static func locateHelper(named name: String) -> URL? {
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
        for directory in directories {
            let candidate = "\(directory)/\(name)"
            if Self.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        guard let pathValue = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if Self.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func lookupOnPath() -> String? {
        guard let pathValue = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("restic").path
            if Self.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// The version parts of `restic version`'s first line, for the features the
/// app gates on rather than displays.
struct ResticVersion: Equatable, Sendable {
    var major: Int
    var minor: Int
    var patch: Int

    /// Parses "restic 0.19.1 compiled with go1.26.5 darwin/arm64" — the
    /// whole first line is accepted so callers can hand over `version()`'s
    /// output as-is. `nil` when no dotted triple follows the name.
    ///
    /// Pre-release and build suffixes ride on the patch component
    /// ("0.18.0-rc.1", "0.19.1+123"): the patch is the digits before the
    /// first "-" or "+", and a suffix never promotes a version —
    /// 0.18.0-rc.1 is 0.18.0, not 0.18.1. Dropping unparseable components
    /// instead would turn "0.15.0-dev" into no-version-at-all, which the
    /// restore stall cap's default would read as modern restic.
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
        guard let patch = Int(patchDigits), patchDigits.allSatisfy(\.isNumber) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// `restore --json` began streaming progress lines in restic 0.16.
    /// Before that, a healthy long restore is silent — an idle stall cap
    /// would kill it as hung — so the cap only applies from this version on.
    var streamsRestoreProgress: Bool {
        (major, minor, patch) >= (0, 16, 0)
    }
}
