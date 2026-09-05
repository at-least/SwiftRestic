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
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw ResticError.binaryNotExecutable(path: url.path)
            }
            return ResticBinary(url: url)
        }

        var searched: [String] = []
        for candidate in searchPaths {
            searched.append(candidate)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return ResticBinary(url: URL(fileURLWithPath: candidate))
            }
        }

        // Last resort: whatever PATH we did inherit.
        if let fromPath = Self.lookupOnPath(), FileManager.default.isExecutableFile(atPath: fromPath) {
            return ResticBinary(url: URL(fileURLWithPath: fromPath))
        }
        throw ResticError.binaryNotFound(searched: searched)
    }

    /// Looks for a helper binary restic shells out to (currently only `rclone`).
    ///
    /// Without this the failure surfaces as an opaque "command not found" buried
    /// in restic's stderr.
    static func locateHelper(named name: String) -> URL? {
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
        for directory in directories {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        guard let pathValue = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func lookupOnPath() -> String? {
        guard let pathValue = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("restic").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
