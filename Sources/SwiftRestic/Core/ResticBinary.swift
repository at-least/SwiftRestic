import Foundation

struct ResticBinary: Sendable {
    var url: URL

    /// The only restic the app runs; `Tools/fetch-restic.sh` pins it and
    /// `Tools/embed-helpers.sh` puts it here. Not looked for on the Mac: a
    /// restic the tests never ran could change what a backup means.
    static var bundled: ResticBinary {
        ResticBinary(url: Bundle.main.helpersURL.appendingPathComponent("restic"))
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
}

extension Bundle {
    /// Where `Tools/embed-helpers.sh` puts the pinned restic and rclone.
    var helpersURL: URL { bundleURL.appendingPathComponent("Contents/Helpers") }
}

enum ResticState {
    case checking
    /// The restic in use, and `restic version`'s answer.
    case ready(ResticBinary, version: String)
    /// The bundled restic is gone or cannot answer `restic version`.
    case damaged
}
