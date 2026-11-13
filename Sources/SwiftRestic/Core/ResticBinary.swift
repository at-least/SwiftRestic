import Foundation

struct ResticBinary: Sendable {
    var url: URL

    /// The only restic the app runs; `Tools/fetch-restic.sh` pins it and
    /// `Tools/embed-helpers.sh` puts it here. Not looked for on the Mac: a
    /// restic the tests never ran could change what a backup means.
    static var bundled: ResticBinary {
        ResticBinary(url: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").appendingPathComponent("restic"))
    }
}

enum ResticState {
    case checking
    /// The restic in use, and `restic version`'s answer.
    case ready(ResticBinary, version: String)
    /// The bundled restic is gone or cannot answer `restic version`.
    case damaged
}
