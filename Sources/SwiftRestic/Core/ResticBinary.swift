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

    /// The extra PATH entries restic runs with, before the system folders —
    /// where a brew ssh lives, which an sftp location needs. rclone is not
    /// among them: the bundled copy leads restic's PATH
    /// (`ResticRunner.baseEnvironment`).
    static let helperDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
}

enum ResticState {
    case checking
    /// The restic in use, and `restic version`'s answer.
    case ready(ResticBinary, version: String)
    /// The bundled restic is gone or cannot answer `restic version`.
    case damaged
}
