import Foundation

struct ResticBinary: Sendable {
    var url: URL

    /// The only restic the app runs; `Tools/fetch-restic.sh` pins it and
    /// `Tools/embed-restic.sh` puts it here. Not looked for on the Mac: a
    /// restic the tests never ran could change what a backup means.
    static var bundled: ResticBinary {
        ResticBinary(url: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/restic"))
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

enum ResticState {
    case checking
    /// The restic in use, and `restic version`'s answer.
    case ready(ResticBinary, version: String)
    /// The bundled restic is gone or cannot answer `restic version`.
    case damaged
}
