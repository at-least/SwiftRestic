import Darwin
import Foundation

/// Whether macOS lets this process read what Full Disk Access guards. There
/// is no API that answers it, so the probe tries: it opens files only a
/// holder of the grant may open, the way restic will try to read the user's.
///
/// `open` and nothing weaker: `lstat`, `access(R_OK)` and
/// `FileManager.isReadableFile` all answer readable on protected paths
/// without the grant. The first TCC-checked `open` costs a round trip to
/// tccd, so callers run the probe off the main actor.
enum FullDiskAccess {
    /// Three files, so one of them changing its protection in some macOS
    /// release cannot flip the answer alone: any EPERM means not granted.
    static var probePaths: [String] {
        let home = NSHomeDirectory()
        return [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Safari",
        ]
    }

    /// `0` for a file that opened, else the errno. EPERM anywhere is macOS
    /// saying no; any file that opened is the grant; files that are simply
    /// missing prove nothing either way.
    static func status(fromOpenResults errnos: [Int32]) -> FullDiskAccessStatus {
        if errnos.contains(EPERM) { return .notGranted }
        if errnos.contains(0) { return .granted }
        return .unknown
    }

    static func probe(paths: [String] = probePaths) -> FullDiskAccessStatus {
        status(fromOpenResults: paths.map { path in
            // Non-blocking so a FIFO at a probe path could never hang it.
            let descriptor = open(path, O_RDONLY | O_NONBLOCK)
            guard descriptor >= 0 else { return errno }
            close(descriptor)
            return 0
        })
    }

    /// System Settings › Privacy & Security › Full Disk Access. The anchor
    /// is the pane's own key for the service (`Privacy_AllFiles` →
    /// `kTCCServiceSystemPolicyAllFiles` in its TCCServiceList.plist).
    /// Pinned by a test, like `AppLinks`.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
