import Foundation
import NetFS

/// Mounts a network share, the way Finder's Connect to Server does but with
/// no dialog: the password goes in as given, and a refusal is an answer,
/// not a prompt. Injectable so a test never mounts anything.
struct ShareMounter: Sendable {
    enum Result: Equatable, Sendable {
        /// Where macOS mounted it.
        case mounted([String])
        /// NetFS's status: an errno when positive, an OSStatus when negative.
        case failed(Int32)
    }

    var mount: @Sendable (_ url: URL, _ password: String?) async -> Result

    /// `NetFSMountURLSync` with `UIOption` = `NoUI` — the CFSTR macros of
    /// NetFS.h (`kNAUIOptionKey`, `kNAUIOptionNoUI`), which Swift does not
    /// import. The user name is the URL's. It blocks for seconds, so it runs
    /// off the caller's actor. Against Samba 4.23.8: given
    /// the user and password, mounted in 3.5 s; without a password, status 80
    /// and no dialog.
    static let netFS = ShareMounter { url, password in
        await Task.detached(priority: .userInitiated) {
            let open = NSMutableDictionary(dictionary: ["UIOption": "NoUI"])
            var mountpoints: Unmanaged<CFArray>?
            let status = NetFSMountURLSync(url as CFURL, nil, nil, password as CFString?, open, nil, &mountpoints)
            let mounted = (mountpoints?.takeRetainedValue() as? [String]) ?? []
            return status == 0 ? .mounted(mounted) : .failed(status)
        }.value
    }

    /// A failed mount's status as a reconnect's outcome: `describe(status:)`'s
    /// words, refused for what only the user clears.
    static func failure(status: Int32) -> ShareReconnect.Outcome {
        switch status {
        case EAUTH, ENOENT, EACCES, EPERM: .refused(describe(status: status))
        default: .unreachable(describe(status: status))
        }
    }

    /// NetFS's status as the clause after "Reconnecting “NAS” failed: ".
    static func describe(status: Int32) -> String {
        switch status {
        case EAUTH: "the share did not accept the user name and password"
        case ENOENT: "the server has no share by that name"
        case ETIMEDOUT, ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH, ENETUNREACH, ENETDOWN:
            "the server could not be reached"
        case EACCES, EPERM: "the server refused access"
        case ..<0: "macOS answered with error \(status)"
        default: String(cString: strerror(status)).lowercased()
        }
    }
}
